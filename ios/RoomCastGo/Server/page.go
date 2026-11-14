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

// listenerHTML is the phone's listener page. reader.js is MediaMTX v1.21.2,
// unchanged. After the first connection the page keeps retrying WHEP, so a
// restart on the same address reconnects. A new IP still needs the new URL.
//
// The page calls video.play() unmuted as soon as audio arrives. iOS Safari
// rejects that call when there has been no user gesture. The rejection is
// caught and the same large play button becomes the one tap that starts
// sound. There is no second unmute control.
func listenerHTML(title, host string, started int64) string {
	safeTitle := html.EscapeString(title)
	scriptSpec := scriptJSON(title, host, started)
	icon := faviconDataURI()
	hero := markDataURI()
	if hero == "" {
		hero = icon
	}
	iconLink := ""
	if icon != "" {
		iconLink = `<link rel="icon" type="image/png" href="` + icon + `">`
	}
	heroTag := ""
	if hero != "" {
		heroTag = `<img id="mark" alt="" width="84" height="84" src="` + hero + `">`
	}
	waiting := html.EscapeString("Waiting for the host to start…")
	return `<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#100c28">
<title>` + safeTitle + `</title>
` + iconLink + `
<style>
html,body{margin:0;padding:0;min-height:100%;background:#100c28;color:#fff}
body{min-height:100vh;min-height:100dvh;display:flex;align-items:safe center;justify-content:center;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:radial-gradient(120% 70% at 50% 8%, #2c245f 0%, #16143a 42%, #100c28 100%)}
#video{position:absolute;width:1px;height:1px;opacity:0;pointer-events:none}
.frame{width:min(480px,100%);max-height:760px;display:flex;flex-direction:column;justify-content:center;box-sizing:border-box}
main{display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center;padding:28px 24px 8px;width:100%;margin:0 auto;box-sizing:border-box}
#mark{width:84px;height:84px;border-radius:20px;display:block;margin:0 auto 18px;box-shadow:0 10px 28px rgba(0,0,0,.35)}
.pill{display:inline-flex;align-items:center;gap:8px;margin:0 auto 16px;padding:6px 14px;border-radius:999px;background:rgba(8,6,24,.45);color:#2ec5b5;font-size:15px;font-weight:700;letter-spacing:.04em}
.dot{width:8px;height:8px;border-radius:50%;background:#2ec5b5;box-shadow:0 0 0 4px rgba(46,197,181,.18)}
h1{margin:0;font-size:30px;line-height:1.15;font-weight:800;letter-spacing:-.02em}
#status{min-height:1.3em;margin:10px 0 0;font-size:16px;font-weight:700;color:rgba(255,255,255,.88)}
.stage{position:relative;width:250px;height:250px;margin:18px auto 0;display:flex;align-items:center;justify-content:center}
.stage::before,.stage::after{content:"";position:absolute;border-radius:50%;border:2px solid rgba(139,92,246,.42)}
.stage::before{width:246px;height:246px;animation:ring 18s linear infinite}
.stage.live::before{animation-duration:6s}
.stage::after{width:204px;height:204px}
#toggle{position:relative;z-index:1;width:156px;height:156px;border:0;border-radius:50%;background:radial-gradient(circle at 38% 32%, #a78bfa 0%, #8b5cf6 46%, #6d46e6 100%);color:#fff;box-shadow:0 14px 40px rgba(109,70,230,.45);display:flex;align-items:center;justify-content:center;cursor:pointer}
#toggle:active{transform:scale(.98)}
#toggle svg{width:62px;height:62px;display:none}
#toggle svg.show{display:block}
#wave{display:flex;align-items:center;justify-content:center;gap:5px;height:42px;margin:8px 0 12px}
#wave span{width:5px;border-radius:4px;background:#9a93b0;height:var(--h);transform-origin:center;transform:scaleY(.45);opacity:.55}
#wave.playing span{background:#2ec5b5;opacity:1;animation:wave 1.05s ease-in-out infinite;animation-delay:var(--d)}
@keyframes wave{0%,100%{transform:scaleY(.4)}50%{transform:scaleY(1.15)}}
@keyframes ring{to{transform:rotate(360deg)}}
footer{padding:8px 22px 22px;text-align:center}
.hint{margin:0 0 6px;font-size:16px;font-weight:400;color:rgba(255,255,255,.72)}
#credit{margin:0;font-size:14px}
#credit a{color:rgba(255,255,255,.5);text-decoration:none}
.noscript{margin:24px;text-align:center;font-size:16px;font-weight:700}
</style>
<script defer src="/reader.js"></script>
</head>
<body>
<video id="video" playsinline webkit-playsinline title="` + safeTitle + `"></video>
<div class="frame">
<main>
` + heroTag + `
<div class="pill"><span class="dot"></span><span id="live-text">LIVE</span></div>
<h1 id="session">` + safeTitle + `</h1>
<p id="status">` + waiting + `</p>
<div class="stage" id="stage">
<button id="toggle" type="button" aria-label="Play">
<svg id="icon-play" class="show" viewBox="0 0 24 24" aria-hidden="true"><path fill="#fff" d="M8.2 5.4v13.2L19 12z"/></svg>
<svg id="icon-pause" viewBox="0 0 24 24" aria-hidden="true"><path fill="#fff" d="M6 5h4.2v14H6zm7.8 0H18v14h-4.2z"/></svg>
</button>
</div>
<div id="wave" aria-hidden="true">` + waveformBars() + `</div>
</main>
<noscript><p class="noscript">This page needs JavaScript turned on.</p></noscript>
<footer>
<p class="hint">Keep this screen open. Earbuds work best.</p>
<p id="credit"><a href="https://roomcast.channel" target="_blank" rel="noopener">Powered by RoomCast</a></p>
</footer>
</div>
<script>
const video=document.getElementById("video");
const statusEl=document.getElementById("status");
const toggle=document.getElementById("toggle");
const stage=document.getElementById("stage");
const iconPlay=document.getElementById("icon-play");
const iconPause=document.getElementById("icon-pause");
const wave=document.getElementById("wave");
const liveText=document.getElementById("live-text");
let reader=null;
let retryTimer=null;
let connected=false;
let generation=0;
let playing=false;
let userPaused=false;
let autoplayBlocked=false;
let startedAt=` + startedLiteral(started) + `;
const waitingText="` + jsString("Waiting for the host to start…") + `";
const tapText="` + jsString("Tap to listen") + `";
const setMessage=(str)=>{statusEl.textContent=str||"";};
const parseBoolString=(str,defaultVal)=>{
str=(str||"").toLowerCase();
if(["1","yes","true"].includes(str))return true;
if(["0","no","false"].includes(str))return false;
return defaultVal;
};
const fmt=(secs)=>{
secs=Math.max(0,secs|0);
const h=(secs/3600)|0;
const m=((secs%3600)/60)|0;
const s=secs%60;
const p=(n)=>n<10?"0"+n:""+n;
if(h>0)return h+":"+p(m)+":"+p(s);
return m+":"+p(s);
};
const tick=()=>{
if(!startedAt){liveText.textContent="LIVE";return;}
const secs=Math.floor(Date.now()/1000-startedAt);
liveText.textContent="LIVE · "+fmt(secs);
};
setInterval(tick,1000);
tick();
const setPlaying=(on)=>{
playing=on;
iconPlay.classList.toggle("show",!on);
iconPause.classList.toggle("show",on);
wave.classList.toggle("playing",on);
if(stage)stage.classList.toggle("live",on);
toggle.setAttribute("aria-label",on?"Pause":(autoplayBlocked?"Tap to listen":"Play"));
};
video.addEventListener("play",()=>setPlaying(true));
video.addEventListener("playing",()=>setPlaying(true));
video.addEventListener("pause",()=>setPlaying(false));
const showHint=()=>{
if(!connected){setMessage(waitingText);return;}
if(autoplayBlocked&&!playing){setMessage(tapText);return;}
setMessage("");
};
const applySpec=(data)=>{
if(!data)return;
if(data.title){
document.title=data.title;
const h=document.getElementById("session");
if(h)h.textContent=data.title;
video.title=data.title;
if(navigator.mediaSession&&typeof MediaMetadata==="function"){
try{navigator.mediaSession.metadata=new MediaMetadata({title:data.title});}catch(err){}
try{navigator.mediaSession.playbackState=playing?"playing":"paused";}catch(err){}
}
}
if(typeof data.started==="number"&&data.started>0){startedAt=data.started;tick();}
};
const earfiSpec=` + scriptSpec + `;
applySpec(earfiSpec);
const refreshSpec=()=>{
fetch("/earfi.json").then((res)=>res.json()).then(applySpec).catch(()=>{});
};
refreshSpec();
setInterval(refreshSpec,15000);
document.addEventListener("visibilitychange",()=>{
if(document.visibilityState==="visible")refreshSpec();
});
const params=new URLSearchParams(window.location.search);
const wantMuted=parseBoolString(params.get("muted"),false);
video.muted=wantMuted;
video.autoplay=true;
video.playsInline=true;
video.setAttribute("playsinline","");
video.controls=false;
const tryPlay=()=>{
video.muted=wantMuted;
const attempt=video.play();
if(!attempt||!attempt.then){autoplayBlocked=false;setPlaying(true);showHint();return;}
attempt.then(()=>{autoplayBlocked=false;setPlaying(true);showHint();}).catch(()=>{
autoplayBlocked=true;
setPlaying(false);
showHint();
});
};
toggle.addEventListener("click",()=>{
if(!connected)return;
if(playing){userPaused=true;video.pause();setPlaying(false);showHint();return;}
userPaused=false;
tryPlay();
});
video.addEventListener("pause",()=>{
if(userPaused){setPlaying(false);showHint();}
});
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
showHint();
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
showHint();
connect();
});
});
applySpec(earfiSpec);
if(!userPaused)tryPlay();
else showHint();
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
showHint();
connect();
}
},2000);
window.addEventListener("load",()=>{
if(typeof MediaMTXWebRTCReader!=="function"){
setMessage("` + jsString("The listener page could not load.") + `");
return;
}
setMessage(waitingText);
connect();
});
window.addEventListener("beforeunload",()=>{if(reader!==null)reader.close();});
</script>
</body>
</html>
`
}

func waveformBars() string {
	heights := []int{10, 18, 28, 14, 34, 22, 12, 30, 18, 36, 16, 26, 12, 32, 20, 14, 24}
	var b strings.Builder
	for i, height := range heights {
		b.WriteString(`<span style="--h:`)
		b.WriteString(strconv.Itoa(height))
		b.WriteString(`px;--d:`)
		b.WriteString(strconv.Itoa(i * 70))
		b.WriteString(`ms"></span>`)
	}
	return b.String()
}

func startedLiteral(started int64) string {
	if started <= 0 {
		return "0"
	}
	return strconv.FormatInt(started, 10)
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
	title := collapseText(raw, 80)
	if title == "" {
		return "RoomCast Broadcast"
	}
	return title
}

func sanitizeHost(raw string) string {
	host := collapseText(raw, 80)
	if host == "" {
		return "this iPhone"
	}
	return host
}

func collapseText(raw string, maximum int) string {
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
	return strings.TrimSpace(b.String())
}
