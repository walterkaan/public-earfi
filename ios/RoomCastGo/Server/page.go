package roomcast

import (
	_ "embed"
	"encoding/base64"
	"encoding/json"
	"html"
	"strconv"
	"strings"
)

//go:embed assets/reader.js
var readerJS []byte

//go:embed assets/favicon.png
var faviconPNG []byte

//go:embed assets/mark.png
var markPNG []byte

// listenerHTML is the page other phones open. The session name is the title.
// host is the broadcasting device, shown as "from <name>". started is unix
// milliseconds for the LIVE timer. reader.js is MediaMTX, unchanged. After
// the first connection the page keeps retrying WHEP, so a restart on the
// same address reconnects. A new IP still needs the new URL.
//
// Unmuted autoplay is attempted as soon as the page opens and again when
// audio arrives. iOS Safari rejects play() without a user gesture, and the
// big button is then the single tap that starts sound.
func listenerHTML(title, host string, started int64) string {
	safeTitle := html.EscapeString(title)
	safeHost := html.EscapeString(host)
	spec := scriptJSON(title, host, started)
	icon := markDataURI()
	fav := faviconDataURI()
	iconLink := ""
	if fav != "" {
		iconLink = `<link rel="icon" type="image/png" href="` + fav + `">`
	}
	hero := ""
	if icon != "" {
		hero = `<img class="hero" alt="" width="64" height="64" src="` + icon + `">`
	}
	return `<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>` + safeTitle + `</title>
` + iconLink + `
<style>
html,body{margin:0;height:100%}
body{
  min-height:100dvh;
  display:flex;
  flex-direction:column;
  align-items:center;
  text-align:center;
  color:#f6f3ff;
  font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif;
  background:
    radial-gradient(ellipse 85% 46% at 50% 38%, rgba(132,86,232,0.42), transparent 64%),
    linear-gradient(180deg, #2e1c72 0%, #1d124c 34%, #140c32 68%, #0c081c 100%);
  padding:28px 22px 8px;
  box-sizing:border-box;
}
.hero{width:64px;height:64px;border-radius:16px;margin-top:10px;display:block}
.live{
  margin-top:18px;
  display:inline-flex;
  align-items:center;
  gap:8px;
  padding:7px 14px 7px 12px;
  border-radius:999px;
  background:rgba(8,10,28,0.55);
  color:#5eead4;
  font-size:14px;
  font-weight:800;
  letter-spacing:0.06em;
}
.live .dot{width:8px;height:8px;border-radius:50%;background:#3ee0c8;box-shadow:0 0 8px #3ee0c8}
h1{margin:18px 0 0;font-size:30px;line-height:1.15;font-weight:800;letter-spacing:-0.02em}
.sub{margin:8px 0 0;color:rgba(232,228,246,0.72);font-size:18px;font-weight:500}
.stage{position:relative;width:240px;height:240px;margin-top:34px;display:grid;place-items:center}
.ring{position:absolute;border-radius:50%;border:3px solid rgba(176,150,255,0.55);box-sizing:border-box}
.ring.outer{width:236px;height:236px;border-color:rgba(176,150,255,0.32)}
.ring.inner{width:196px;height:196px}
button.play{
  width:150px;height:150px;border:0;border-radius:50%;padding:0;cursor:pointer;
  background:radial-gradient(circle at 36% 30%, #c9b6ff 0%, #8d6bff 32%, #6d4df0 72%, #5b3de0 100%);
  box-shadow:0 14px 36px rgba(78,40,180,0.38);
  position:relative;z-index:1;
}
button.play svg{width:62px;height:62px;display:block;margin:0 auto}
button.play .pause{display:none}
button.play.playing .pause{display:block}
button.play.playing .playmark{display:none}
#status{min-height:22px;margin:8px 0 0;color:rgba(232,228,246,0.78);font-size:16px;font-weight:650}
.wave{margin-top:18px;height:42px;display:flex;align-items:center;justify-content:center;gap:4px}
.wave i{
  display:block;width:4px;border-radius:4px;background:#3ddec8;
  transform-origin:center;animation:pulse 0.9s ease-in-out infinite;
}
.wave.idle i{animation:none;opacity:0.45}
@keyframes pulse{0%,100%{transform:scaleY(0.4)}50%{transform:scaleY(1)}}
@media (prefers-reduced-motion:reduce){.wave i{animation:none}}
.spacer{flex:1;min-height:28px}
footer{padding:8px 12px 26px}
footer p{margin:0;color:rgba(220,216,240,0.66);font-size:15px}
footer a{display:inline-block;margin-top:6px;color:rgba(200,196,230,0.48);font-size:13px;text-decoration:none}
video#video{position:fixed;left:0;top:0;width:2px;height:2px;opacity:0;pointer-events:none}
.noscript{margin-top:24px;font-size:16px;font-weight:700;padding:0 12px}
</style>
<script defer src="/reader.js"></script>
</head>
<body>
<video id="video" playsinline webkit-playsinline title="` + safeTitle + `"></video>
<noscript><p class="noscript">This page needs JavaScript turned on.</p></noscript>
` + hero + `
<div class="live"><span class="dot"></span><span id="elapsed">LIVE</span></div>
<h1 id="heading">` + safeTitle + `</h1>
<p class="sub" id="host">from ` + safeHost + `</p>
<div class="stage">
  <div class="ring outer"></div>
  <div class="ring inner"></div>
  <button id="play" class="play" type="button" aria-label="Play">
    <svg class="pause" viewBox="0 0 64 64" aria-hidden="true"><rect x="16" y="12" width="10" height="40" rx="5" fill="#fff"/><rect x="38" y="12" width="10" height="40" rx="5" fill="#fff"/></svg>
    <svg class="playmark" viewBox="0 0 64 64" aria-hidden="true"><path d="M26 14 L52 32 L26 50 Z" fill="#fff"/></svg>
  </button>
</div>
<p id="status">` + html.EscapeString("Waiting for the host to start…") + `</p>
` + waveformBars() + `
<div class="spacer"></div>
<footer>
  <p>Keep this screen open. Earbuds work best.</p>
  <a href="https://roomcast.channel" target="_blank" rel="noopener">Powered by RoomCast</a>
</footer>
<script>
const video=document.getElementById("video");
const statusEl=document.getElementById("status");
const playBtn=document.getElementById("play");
const wave=document.getElementById("wave");
const heading=document.getElementById("heading");
const hostEl=document.getElementById("host");
const elapsedEl=document.getElementById("elapsed");
let reader=null;
let userPaused=false;
let connected=false;
let generation=0;
let started=0;
const waitingText="` + jsString("Waiting for the host to start…") + `";
const setPlaying=(on)=>{
  const playing=!!on && !video.paused;
  playBtn.classList.toggle("playing", playing);
  wave.classList.toggle("idle", !playing);
  playBtn.setAttribute("aria-label", playing?"Pause":"Play");
  if(playing){statusEl.textContent="";}
  else if(connected){statusEl.textContent="Tap to listen";}
};
const attemptUnmuted=()=>{
  if(userPaused)return;
  video.muted=false;
  let pending;
  try{pending=video.play();}catch(err){setPlaying(false);return;}
  if(pending&&typeof pending.then==="function"){
    pending.then(()=>{setPlaying(true);}).catch(()=>{setPlaying(false);});
  }
};
playBtn.addEventListener("click",()=>{
  if(playBtn.classList.contains("playing")){
    userPaused=true;
    video.pause();
    setPlaying(false);
    return;
  }
  userPaused=false;
  video.muted=false;
  let pending;
  try{pending=video.play();}catch(err){setPlaying(false);return;}
  if(pending&&typeof pending.then==="function"){
    pending.then(()=>{setPlaying(true);}).catch(()=>{setPlaying(false);});
  }
});
video.addEventListener("playing",()=>{setPlaying(true);});
video.addEventListener("pause",()=>{setPlaying(false);});
const formatElapsed=(ms)=>{
  const secs=Math.max(0,Math.floor(ms/1000));
  const h=Math.floor(secs/3600);
  const m=Math.floor((secs%3600)/60);
  const s=secs%60;
  const pad=(n)=>String(n).padStart(2,"0");
  if(h>0)return h+":"+pad(m)+":"+pad(s);
  return m+":"+pad(s);
};
const tick=()=>{
  if(!started){elapsedEl.textContent="LIVE";return;}
  elapsedEl.textContent="LIVE · "+formatElapsed(Date.now()-started);
};
const applyTitle=(title)=>{
  if(!title)return;
  document.title=title;
  if(heading)heading.textContent=title;
  video.title=title;
  video.setAttribute("title",title);
  if(navigator.mediaSession&&typeof MediaMetadata==="function"){
    navigator.mediaSession.metadata=new MediaMetadata({title:title});
    try{navigator.mediaSession.playbackState="playing";}catch(err){}
  }
};
const applyMeta=(data)=>{
  if(!data)return;
  if(data.title)applyTitle(data.title);
  if(data.host&&hostEl)hostEl.textContent="from "+data.host;
  if(typeof data.started==="number"&&data.started>0)started=data.started;
  tick();
};
const spec=` + spec + `;
applyMeta(spec);
setInterval(tick,1000);
const refreshMeta=()=>{
  fetch("/earfi.json").then((res)=>res.json()).then(applyMeta).catch(()=>{});
};
refreshMeta();
setInterval(refreshMeta,4000);
document.addEventListener("visibilitychange",()=>{
  if(document.visibilityState==="visible")refreshMeta();
});
const parseBoolString=(str,defaultVal)=>{
  str=(str||"").toLowerCase();
  if(["1","yes","true"].includes(str))return true;
  if(["0","no","false"].includes(str))return false;
  return defaultVal;
};
const loadAttributesFromQuery=()=>{
  const params=new URLSearchParams(window.location.search);
  video.muted=parseBoolString(params.get("muted"),false);
  video.autoplay=parseBoolString(params.get("autoplay"),true);
  video.playsInline=true;
  video.setAttribute("playsinline","");
};
let retryTimer=null;
const connect=()=>{
  if(retryTimer!==null){clearTimeout(retryTimer);retryTimer=null;}
  const ticket=++generation;
  connected=false;
  if(reader!==null){try{reader.close();}catch(err){}reader=null;}
  reader=new MediaMTXWebRTCReader({
    url:new URL("/whep",window.location.href).toString(),
    onError:()=>{
      if(ticket!==generation)return;
      connected=false;
      setPlaying(false);
      statusEl.textContent=waitingText;
      if(retryTimer!==null)clearTimeout(retryTimer);
      retryTimer=setTimeout(connect,1500);
    },
    onTrack:(evt)=>{
      if(ticket!==generation)return;
      connected=true;
      if(retryTimer!==null){clearTimeout(retryTimer);retryTimer=null;}
      video.srcObject=evt.streams[0];
      const stream=evt.streams[0];
      (stream?stream.getTracks():[]).forEach((track)=>{
        track.addEventListener("ended",()=>{
          if(ticket!==generation||!connected)return;
          connected=false;
          setPlaying(false);
          statusEl.textContent=waitingText;
          connect();
        });
      });
      applyTitle(document.title);
      attemptUnmuted();
    },
    onDataChannel:(evt)=>{
      evt.channel.binaryType="arraybuffer";
      evt.channel.onmessage=(evt)=>{console.log("data channel message",evt.data);};
    },
  });
};
setInterval(()=>{
  if(!connected)return;
  const stream=video.srcObject;
  const tracks=stream&&stream.getTracks?stream.getTracks():[];
  if(tracks.length>0&&tracks.every((track)=>track.readyState==="ended")){
    connected=false;
    setPlaying(false);
    statusEl.textContent=waitingText;
    connect();
  }
},2000);
window.addEventListener("load",()=>{
  if(typeof MediaMTXWebRTCReader!=="function"){
    statusEl.textContent="` + jsString("The listener page could not load.") + `";
    return;
  }
  loadAttributesFromQuery();
  statusEl.textContent=waitingText;
  attemptUnmuted();
  connect();
});
video.addEventListener("play",()=>applyTitle(document.title));
window.addEventListener("beforeunload",()=>{if(reader!==null)reader.close();});
</script>
</body>
</html>
`
}

func waveformBars() string {
	heights := []int{6, 10, 16, 11, 22, 14, 28, 18, 34, 20, 36, 20, 34, 18, 28, 14, 22, 11, 16, 10, 6}
	var b strings.Builder
	b.WriteString(`<div class="wave idle" id="wave" aria-hidden="true">`)
	for i, h := range heights {
		b.WriteString(`<i style="height:`)
		b.WriteString(strconv.Itoa(h))
		b.WriteString(`px;animation-delay:`)
		b.WriteString(strconv.Itoa((i % 7) * 80))
		b.WriteString(`ms"></i>`)
	}
	b.WriteString(`</div>`)
	return b.String()
}

func markDataURI() string {
	if len(markPNG) == 0 {
		return ""
	}
	return "data:image/png;base64," + base64.StdEncoding.EncodeToString(markPNG)
}

func faviconDataURI() string {
	if len(faviconPNG) == 0 {
		return ""
	}
	return "data:image/png;base64," + base64.StdEncoding.EncodeToString(faviconPNG)
}

func scriptJSON(title, host string, started int64) string {
	payload, err := json.Marshal(map[string]any{
		"title":   title,
		"host":    host,
		"started": started,
	})
	if err != nil {
		return `{"title":"RoomCast Broadcast","host":"this iPhone","started":0}`
	}
	return strings.NewReplacer(
		"<", `\u003c`,
		">", `\u003e`,
		"&", `\u0026`,
		"\u2028", `\u2028`,
		"\u2029", `\u2029`,
	).Replace(string(payload))
}

func jsString(text string) string {
	replacer := strings.NewReplacer(
		`\`, `\\`,
		`"`, `\"`,
		"\n", `\n`,
		"<", `\u003c`,
		">", `\u003e`,
		"&", `\u0026`,
	)
	return replacer.Replace(text)
}

func sanitizeTitle(raw string) string {
	return sanitizeLabel(raw, "RoomCast Broadcast", 80)
}

func sanitizeHost(raw string) string {
	return sanitizeLabel(raw, "this iPhone", 60)
}

func sanitizeLabel(raw, fallback string, maximum int) string {
	var b strings.Builder
	pendingSpace := false
	for _, character := range raw {
		if character < 32 || character == 127 || character == '\n' || character == '\r' || character == '\t' || character == ' ' {
			pendingSpace = b.Len() > 0
			continue
		}
		if pendingSpace {
			b.WriteByte(' ')
			pendingSpace = false
		}
		b.WriteRune(character)
		if b.Len() >= maximum {
			break
		}
	}
	label := strings.TrimSpace(b.String())
	if label == "" {
		return fallback
	}
	return label
}
