package roomcast

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/pion/ice/v4"
	"github.com/pion/webrtc/v4"
	"github.com/pion/webrtc/v4/pkg/media"
)

const opusFrame = 20 * time.Millisecond

var (
	errStopped   = errors.New("the broadcast has stopped")
	errNoSession = errors.New("that listener is gone")
)

type session struct {
	pc        *webrtc.PeerConnection
	connected bool
}

type server struct {
	mu       sync.Mutex
	track    *webrtc.TrackLocalStaticSample
	api      *webrtc.API
	sessions map[string]*session
	title    string
	closed   bool
	cancel   context.CancelFunc
	ctx      context.Context

	httpServer  *http.Server
	listener    net.Listener
	udpConn     *net.UDPConn
	tcpListener *net.TCPListener
}

func newServer(httpPort, icePort int, ip, iface, title string) (*server, error) {
	parsed := net.ParseIP(ip).To4()
	if parsed == nil {
		return nil, errors.New("the broadcast address is not an IPv4 address")
	}
	if !parsed.IsLoopback() && !privateIPv4(parsed.String()) {
		return nil, errors.New("RoomCast Go only broadcasts on Wi-Fi or Personal Hotspot")
	}
	title = sanitizeTitle(title)
	iface = safeIfaceName(iface)

	track, err := webrtc.NewTrackLocalStaticSample(webrtc.RTPCodecCapability{
		MimeType:  webrtc.MimeTypeOpus,
		ClockRate: 48000,
		Channels:  2,
		// stereo=1 lets a USB music broadcast send stereo Opus on this same
		// track. Voice stays mono packets. Listeners do not renegotiate.
		SDPFmtpLine: "minptime=10;useinbandfec=1;stereo=1;sprop-stereo=1",
	}, "audio", "roomcast")
	if err != nil {
		return nil, fmt.Errorf("could not create the audio track: %w", err)
	}

	udpConn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: parsed, Port: icePort})
	if err != nil {
		return nil, fmt.Errorf("could not listen for listener audio on UDP %d: %w", icePort, err)
	}
	udpMux := ice.NewUDPMuxDefault(ice.UDPMuxParams{UDPConn: udpConn})

	var tcpListener *net.TCPListener
	var tcpMux ice.TCPMux
	tcpListener, tcpErr := net.ListenTCP("tcp4", &net.TCPAddr{IP: parsed, Port: icePort})
	if tcpErr != nil {
		log.Printf("TCP fallback for listeners is off: %v", tcpErr)
	} else {
		tcpMux = webrtc.NewICETCPMux(nil, tcpListener, 8)
	}

	setting := webrtc.SettingEngine{}
	setting.SetICEMulticastDNSMode(ice.MulticastDNSModeDisabled)
	setting.SetICEUDPMux(udpMux)
	if tcpMux != nil {
		setting.SetICETCPMux(tcpMux)
		setting.SetNetworkTypes([]webrtc.NetworkType{webrtc.NetworkTypeUDP4, webrtc.NetworkTypeTCP4})
	} else {
		setting.SetNetworkTypes([]webrtc.NetworkType{webrtc.NetworkTypeUDP4})
	}
	if parsed.IsLoopback() {
		setting.SetIncludeLoopbackCandidate(true)
	}
	if iface != "" {
		want := iface
		setting.SetInterfaceFilter(func(name string) bool { return name == want })
	}
	setting.SetIPFilter(func(candidate net.IP) bool {
		v4 := candidate.To4()
		return v4 != nil && v4.Equal(parsed)
	})

	ctx, cancel := context.WithCancel(context.Background())
	s := &server{
		track:       track,
		api:         webrtc.NewAPI(webrtc.WithSettingEngine(setting)),
		sessions:    map[string]*session{},
		title:       title,
		cancel:      cancel,
		ctx:         ctx,
		udpConn:     udpConn,
		tcpListener: tcpListener,
	}

	ln, err := net.Listen("tcp4", net.JoinHostPort(parsed.String(), fmt.Sprintf("%d", httpPort)))
	if err != nil {
		s.closeSockets()
		cancel()
		if isAddrInUse(err) {
			return nil, fmt.Errorf("port %d is already in use on this iPhone", httpPort)
		}
		return nil, fmt.Errorf("could not open the listener page: %w", err)
	}
	s.listener = ln
	s.httpServer = &http.Server{
		Handler:           s,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      15 * time.Second,
	}
	go func() {
		err := s.httpServer.Serve(ln)
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Printf("listener page stopped: %v", err)
		}
	}()
	log.Printf("broadcasting %s on %s (ice %s)", s.url(), iface, udpConn.LocalAddr())
	return s, nil
}

// Pion copies the offer's Opus fmtp into the answer, so a voice-only offer
// would not advertise stereo. USB music sends stereo on this same track.
func advertiseStereo(sdp string) string {
	lines := strings.Split(sdp, "\r\n")
	payload := ""
	for _, line := range lines {
		if strings.HasPrefix(line, "a=rtpmap:") && strings.Contains(strings.ToLower(line), "opus/") {
			rest := strings.TrimPrefix(line, "a=rtpmap:")
			payload, _, _ = strings.Cut(rest, " ")
			break
		}
	}
	if payload == "" {
		return sdp
	}
	prefix := "a=fmtp:" + payload + " "
	for i, line := range lines {
		if !strings.HasPrefix(line, prefix) {
			continue
		}
		if !strings.Contains(line, "stereo=") {
			lines[i] += ";stereo=1"
		}
		if !strings.Contains(line, "sprop-stereo=") {
			lines[i] += ";sprop-stereo=1"
		}
	}
	return strings.Join(lines, "\r\n")
}

func (s *server) url() string {
	if s.listener == nil {
		return ""
	}
	return "http://" + s.listener.Addr().String() + "/"
}

func (s *server) publish(packet []byte) {
	if len(packet) == 0 || len(packet) > 1500 {
		return
	}
	s.mu.Lock()
	closed := s.closed
	s.mu.Unlock()
	if closed {
		return
	}
	buf := make([]byte, len(packet))
	copy(buf, packet)
	// Packetized once. Each bound peer then encrypts its own SRTP copy.
	_ = s.track.WriteSample(media.Sample{Data: buf, Duration: opusFrame})
}

func (s *server) listenerCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	n := 0
	for _, sess := range s.sessions {
		if sess.connected {
			n++
		}
	}
	return n
}

func (s *server) stop() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	sessions := s.sessions
	s.sessions = map[string]*session{}
	s.mu.Unlock()
	s.cancel()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if s.httpServer != nil {
		_ = s.httpServer.Shutdown(ctx)
	}
	for _, sess := range sessions {
		_ = sess.pc.Close()
	}
	s.closeSockets()
	log.Printf("broadcast stopped")
}

func (s *server) closeSockets() {
	if s.udpConn != nil {
		_ = s.udpConn.Close()
	}
	if s.tcpListener != nil {
		_ = s.tcpListener.Close()
	}
}

func (s *server) acceptOffer(offerSDP string) (string, string, error) {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return "", "", errStopped
	}
	s.mu.Unlock()

	pc, err := s.api.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		return "", "", err
	}
	pc.OnDataChannel(func(*webrtc.DataChannel) {})
	sender, err := pc.AddTrack(s.track)
	if err != nil {
		_ = pc.Close()
		return "", "", err
	}
	go drainRTCP(sender)

	id := newID()
	sess := &session{pc: pc}
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		_ = pc.Close()
		return "", "", errStopped
	}
	s.sessions[id] = sess
	s.mu.Unlock()

	pc.OnConnectionStateChange(func(state webrtc.PeerConnectionState) {
		s.onState(id, state)
	})

	fail := func(err error) (string, string, error) {
		s.drop(id)
		return "", "", err
	}
	if err = pc.SetRemoteDescription(webrtc.SessionDescription{
		Type: webrtc.SDPTypeOffer,
		SDP:  offerSDP,
	}); err != nil {
		return fail(err)
	}
	gatherDone := webrtc.GatheringCompletePromise(pc)
	answer, err := pc.CreateAnswer(nil)
	if err != nil {
		return fail(err)
	}
	if err = pc.SetLocalDescription(answer); err != nil {
		return fail(err)
	}
	select {
	case <-gatherDone:
	case <-time.After(2 * time.Second):
	case <-s.ctx.Done():
		return fail(errStopped)
	}
	local := pc.LocalDescription()
	if local == nil {
		return fail(errors.New("no answer"))
	}
	log.Printf("listener offered, answer candidates: %d", countCandidates(local.SDP))
	// Pion rejects a rewritten local description. The browser only needs the
	// stereo parameters on the answer it receives.
	return id, advertiseStereo(local.SDP), nil
}

func (s *server) addCandidates(id, fragment string) error {
	s.mu.Lock()
	sess := s.sessions[id]
	s.mu.Unlock()
	if sess == nil {
		return errNoSession
	}
	return applyICEFragment(sess.pc, fragment)
}

func (s *server) drop(id string) {
	s.mu.Lock()
	sess := s.sessions[id]
	delete(s.sessions, id)
	s.mu.Unlock()
	if sess != nil {
		_ = sess.pc.Close()
	}
}

func (s *server) onState(id string, state webrtc.PeerConnectionState) {
	s.mu.Lock()
	sess := s.sessions[id]
	if sess == nil {
		s.mu.Unlock()
		return
	}
	switch state {
	case webrtc.PeerConnectionStateConnected:
		sess.connected = true
		log.Printf("listener connected, %d listening", s.connectedLocked())
	case webrtc.PeerConnectionStateDisconnected:
		sess.connected = false
	case webrtc.PeerConnectionStateFailed, webrtc.PeerConnectionStateClosed:
		sess.connected = false
		delete(s.sessions, id)
		log.Printf("listener left (%s)", state)
	default:
	}
	s.mu.Unlock()
}

func (s *server) connectedLocked() int {
	n := 0
	for _, sess := range s.sessions {
		if sess.connected {
			n++
		}
	}
	return n
}

func drainRTCP(sender *webrtc.RTPSender) {
	buf := make([]byte, 1500)
	for {
		if _, _, err := sender.Read(buf); err != nil {
			return
		}
	}
}

func newID() string {
	var buf [16]byte
	_, _ = rand.Read(buf[:])
	return hex.EncodeToString(buf[:])
}

func countCandidates(sdp string) int {
	n := 0
	for _, line := range splitLines(sdp) {
		if len(line) >= 12 && line[:12] == "a=candidate:" {
			n++
		}
	}
	return n
}
