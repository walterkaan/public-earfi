package roomcast

import (
	"bytes"
	"io"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/pion/ice/v4"
	"github.com/pion/webrtc/v4"
)

func TestPageAndWHEPContract(t *testing.T) {
	s := testServer(t)
	base := s.url()
	client := &http.Client{Timeout: 5 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error {
		return http.ErrUseLastResponse
	}}

	page := getOK(t, client, base)
	if !strings.Contains(page, "Powered by RoomCast") || !strings.Contains(page, "/reader.js") {
		t.Fatalf("served page is not the listener page")
	}
	script := getOK(t, client, base+"reader.js")
	if script != string(readerJS) {
		t.Fatal("served reader.js does not match the vendored MediaMTX file")
	}
	title := getOK(t, client, base+"earfi.json")
	if !strings.Contains(title, "RoomCast Broadcast") {
		t.Fatalf("title json: %s", title)
	}
	res, err := client.Get(base + "live")
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != http.StatusFound || res.Header.Get("Location") != "/" {
		t.Fatalf("live redirect: %d %s", res.StatusCode, res.Header.Get("Location"))
	}
	opt, err := client.Do(mustRequest(t, http.MethodOptions, base+"whep", "", ""))
	if err != nil {
		t.Fatal(err)
	}
	opt.Body.Close()
	if opt.StatusCode != http.StatusNoContent {
		t.Fatalf("OPTIONS /whep: %d", opt.StatusCode)
	}
	bad, err := client.Do(mustRequest(t, http.MethodPost, base+"whep", "text/plain", "nope"))
	if err != nil {
		t.Fatal(err)
	}
	badBody, _ := io.ReadAll(bad.Body)
	bad.Body.Close()
	if bad.StatusCode != http.StatusBadRequest || !strings.Contains(string(badBody), "error") {
		t.Fatalf("bad offer: %d %s", bad.StatusCode, badBody)
	}
}

func TestTwoListenersHearTheSameVoice(t *testing.T) {
	s := testServer(t)
	var mu sync.Mutex
	leftGot := map[string]int{}
	rightGot := map[string]int{}
	left := dialListener(t, s.url(), func(track *webrtc.TrackRemote, receiver *webrtc.RTPReceiver) {
		readAudio(track, receiver, leftGot, &mu)
	})
	right := dialListener(t, s.url(), func(track *webrtc.TrackRemote, receiver *webrtc.RTPReceiver) {
		readAudio(track, receiver, rightGot, &mu)
	})

	waitConnected(t, left.pc)
	waitConnected(t, right.pc)
	if got := s.listenerCount(); got != 2 {
		t.Fatalf("listener count = %d, want 2", got)
	}

	sent := make([][]byte, 0, 25)
	for i := 0; i < 25; i++ {
		// Distinct payloads. The server forwards Opus bytes; it does not decode them.
		packet := []byte{0xf8, 0x00, byte(i), 0x11, 0x22, 0x33, 0x44, 0x55}
		sent = append(sent, packet)
		s.publish(packet)
		time.Sleep(20 * time.Millisecond)
	}
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		mu.Lock()
		shared := sharedPayloads(leftGot, rightGot, sent)
		mu.Unlock()
		if shared >= 8 {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	mu.Lock()
	defer mu.Unlock()
	t.Fatalf("listeners did not both receive the voice (left %d, right %d)", len(leftGot), len(rightGot))
}

func TestDeleteDropsTheListener(t *testing.T) {
	s := testServer(t)
	listener := dialListener(t, s.url(), nil)
	waitConnected(t, listener.pc)
	req, err := http.NewRequest(http.MethodDelete, listener.session, nil)
	if err != nil {
		t.Fatal(err)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("DELETE: %d", res.StatusCode)
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if s.listenerCount() == 0 {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("listener count stayed %d", s.listenerCount())
}

func TestSingletonStartStop(t *testing.T) {
	if err := Start(0, 0, "127.0.0.1", "lo", "RoomCast Broadcast"); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(Stop)
	if err := Start(0, 0, "127.0.0.1", "lo", "RoomCast Broadcast"); err == nil {
		t.Fatal("second Start succeeded")
	}
	if ListenerCount() != 0 {
		t.Fatalf("count = %d", ListenerCount())
	}
	PublishOpus([]byte{0x00})
	Stop()
	if ListenerCount() != 0 {
		t.Fatal("count after stop")
	}
	Stop()
}

type listenerClient struct {
	pc      *webrtc.PeerConnection
	session string
}

func testServer(t *testing.T) *server {
	t.Helper()
	s, err := newServer(0, 0, "127.0.0.1", "lo", "RoomCast Broadcast")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.stop)
	return s
}

func dialListener(t *testing.T, base string, onTrack func(*webrtc.TrackRemote, *webrtc.RTPReceiver)) listenerClient {
	t.Helper()
	setting := webrtc.SettingEngine{}
	setting.SetICEMulticastDNSMode(ice.MulticastDNSModeDisabled)
	setting.SetIncludeLoopbackCandidate(true)
	setting.SetNetworkTypes([]webrtc.NetworkType{webrtc.NetworkTypeUDP4})
	api := webrtc.NewAPI(webrtc.WithSettingEngine(setting))
	pc, err := api.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = pc.Close() })

	if _, err := pc.AddTransceiverFromKind(webrtc.RTPCodecTypeVideo, webrtc.RTPTransceiverInit{
		Direction: webrtc.RTPTransceiverDirectionRecvonly,
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := pc.AddTransceiverFromKind(webrtc.RTPCodecTypeAudio, webrtc.RTPTransceiverInit{
		Direction: webrtc.RTPTransceiverDirectionRecvonly,
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := pc.CreateDataChannel("", nil); err != nil {
		t.Fatal(err)
	}
	if onTrack != nil {
		pc.OnTrack(func(track *webrtc.TrackRemote, receiver *webrtc.RTPReceiver) {
			go onTrack(track, receiver)
		})
	}

	var mu sync.Mutex
	var gathered []webrtc.ICECandidate
	gatherDone := make(chan struct{})
	pc.OnICECandidate(func(c *webrtc.ICECandidate) {
		if c == nil {
			select {
			case <-gatherDone:
			default:
				close(gatherDone)
			}
			return
		}
		mu.Lock()
		gathered = append(gathered, *c)
		mu.Unlock()
	})

	offer, err := pc.CreateOffer(nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := pc.SetLocalDescription(offer); err != nil {
		t.Fatal(err)
	}
	// reader.js posts the original offer, then trickles candidates.
	res, err := http.Post(base+"whep", "application/sdp", strings.NewReader(offer.SDP))
	if err != nil {
		t.Fatal(err)
	}
	answer, _ := io.ReadAll(res.Body)
	res.Body.Close()
	if res.StatusCode != http.StatusCreated {
		t.Fatalf("POST /whep: %d %s", res.StatusCode, answer)
	}
	location := res.Header.Get("Location")
	if location == "" {
		t.Fatal("missing Location")
	}
	if err := pc.SetRemoteDescription(webrtc.SessionDescription{
		Type: webrtc.SDPTypeAnswer,
		SDP:  string(answer),
	}); err != nil {
		t.Fatalf("set answer: %v\n%s", err, answer)
	}
	if !strings.Contains(string(answer), "opus") {
		t.Fatalf("answer has no opus:\n%s", answer)
	}
	if countCandidates(string(answer)) == 0 {
		t.Fatalf("answer has no ICE candidates:\n%s", answer)
	}

	select {
	case <-gatherDone:
	case <-time.After(3 * time.Second):
		t.Fatal("client gathering did not finish")
	}
	mu.Lock()
	candidates := append([]webrtc.ICECandidate(nil), gathered...)
	mu.Unlock()
	var frag strings.Builder
	frag.WriteString("a=ice-ufrag:test\r\na=ice-pwd:testpasswordtestpassword\r\n")
	for _, cand := range candidates {
		init := cand.ToJSON()
		mid := 0
		if init.SDPMLineIndex != nil {
			mid = int(*init.SDPMLineIndex)
		}
		media := "video 9 UDP/TLS/RTP/SAVPF 96"
		if mid == 1 {
			media = "audio 9 UDP/TLS/RTP/SAVPF 111"
		}
		frag.WriteString("m=" + media + "\r\n")
		frag.WriteString("a=mid:" + itoa(mid) + "\r\n")
		frag.WriteString("a=" + init.Candidate + "\r\n")
	}
	patch, err := http.NewRequest(http.MethodPatch, strings.TrimRight(base, "/")+location, bytes.NewBufferString(frag.String()))
	if err != nil {
		t.Fatal(err)
	}
	patch.Header.Set("Content-Type", "application/trickle-ice-sdpfrag")
	patch.Header.Set("If-Match", "*")
	patched, err := http.DefaultClient.Do(patch)
	if err != nil {
		t.Fatal(err)
	}
	patchBody, _ := io.ReadAll(patched.Body)
	patched.Body.Close()
	if patched.StatusCode != http.StatusNoContent {
		t.Fatalf("PATCH: %d %s", patched.StatusCode, patchBody)
	}
	return listenerClient{pc: pc, session: strings.TrimRight(base, "/") + location}
}

func readAudio(track *webrtc.TrackRemote, receiver *webrtc.RTPReceiver, got map[string]int, mu *sync.Mutex) {
	go func() {
		buf := make([]byte, 1500)
		for {
			if _, _, err := receiver.Read(buf); err != nil {
				return
			}
		}
	}()
	for {
		pkt, _, err := track.ReadRTP()
		if err != nil {
			return
		}
		mu.Lock()
		got[string(pkt.Payload)]++
		mu.Unlock()
	}
}

func waitConnected(t *testing.T, pc *webrtc.PeerConnection) {
	t.Helper()
	deadline := time.Now().Add(8 * time.Second)
	for time.Now().Before(deadline) {
		if pc.ConnectionState() == webrtc.PeerConnectionStateConnected {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("peer did not connect (state %s, ice %s)", pc.ConnectionState(), pc.ICEConnectionState())
}

func sharedPayloads(left, right map[string]int, sent [][]byte) int {
	n := 0
	for _, packet := range sent {
		key := string(packet)
		if left[key] > 0 && right[key] > 0 {
			n++
		}
	}
	return n
}

func getOK(t *testing.T, client *http.Client, url string) string {
	t.Helper()
	var last error
	for i := 0; i < 20; i++ {
		res, err := client.Get(url)
		if err != nil {
			last = err
			time.Sleep(20 * time.Millisecond)
			continue
		}
		body, _ := io.ReadAll(res.Body)
		res.Body.Close()
		if res.StatusCode != http.StatusOK {
			t.Fatalf("%s: %d %s", url, res.StatusCode, body)
		}
		return string(body)
	}
	t.Fatal(last)
	return ""
}

func mustRequest(t *testing.T, method, url, contentType, body string) *http.Request {
	t.Helper()
	req, err := http.NewRequest(method, url, strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	return req
}
