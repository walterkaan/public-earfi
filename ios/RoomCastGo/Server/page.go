package roomcast

import (
	_ "embed"
	"encoding/base64"
	"encoding/json"
	"html"
	"strings"
)

//go:embed assets/reader.js
var readerJS []byte

//go:embed assets/favicon.png
var faviconPNG []byte

// listenerHTML is the Mac app's listener page (ListenerPage.swift at
// commit 780ddc8) served from this phone. reader.js is MediaMTX v1.21.2,
// unchanged. After the first connection the page keeps retrying WHEP, so a
// restart on the same address reconnects. A new IP still needs the new URL.
func listenerHTML(title string) string {
	safeTitle := html.EscapeString(title)
	scriptTitle := scriptJSON(title)
	icon := faviconDataURI()
	iconLink := ""
	if icon != "" {
		iconLink = `<link rel="icon" type="image/png" href="` + icon + `">`
	}
	waiting := html.EscapeString("Waiting for the host to start…")
	return `<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width">
<title>` + safeTitle + `</title>
` + iconLink + `
<style>
html,body{margin:0;padding:0;height:100%;background:#161a42;font-family:Arial,sans-serif;color:#fff}
#video{position:absolute;top:0;left:0;width:100%;height:calc(100% - 44px);background:#161a42}
#message{position:absolute;left:0;top:0;right:0;bottom:44px;display:flex;align-items:center;text-align:center;justify-content:center;font-size:16px;font-weight:bold;color:#fff;pointer-events:none;padding:20px;box-sizing:border-box;text-shadow:0 0 5px #000}
#credit{position:absolute;left:0;right:0;bottom:0;height:44px;display:flex;align-items:center;justify-content:center;gap:8px;background:#161a42;border-top:1px solid rgba(47,208,189,0.35);z-index:2;font-size:13px}
#credit img{width:28px;height:28px;border-radius:7px;display:block}
#credit a{color:rgba(255,255,255,0.58);text-decoration:none}
.noscript{position:absolute;left:0;right:0;top:40%;text-align:center;font-size:16px;font-weight:bold;padding:20px}
</style>
<script defer src="/reader.js"></script>
</head>
<body>
<video id="video" title="` + safeTitle + `"></video>
<noscript><p class="noscript">This page needs JavaScript turned on.</p></noscript>
<div id="message">` + waiting + `</div>
<script>
const video=document.getElementById("video");
const message=document.getElementById("message");
let defaultControls=false;
let reader=null;
const setMessage=(str)=>{video.controls=str!==""?false:defaultControls;message.innerText=str;};
const parseBoolString=(str,defaultVal)=>{
str=(str||"").toLowerCase();
if(["1","yes","true"].includes(str))return true;
if(["0","no","false"].includes(str))return false;
return defaultVal;
};
const applyTitle=(title)=>{
if(!title)return;
document.title=title;
video.title=title;
video.setAttribute("title",title);
if(navigator.mediaSession&&typeof MediaMetadata==="function"){
navigator.mediaSession.metadata=new MediaMetadata({title:title});
try{navigator.mediaSession.playbackState="playing";}catch(err){}
}
};
const earfiSpec=` + scriptTitle + `;
applyTitle(earfiSpec.title);
const refreshTitle=()=>{
fetch("/earfi.json").then((res)=>res.json()).then((data)=>applyTitle(data.title)).catch(()=>{});
};
refreshTitle();
document.addEventListener("visibilitychange",()=>{
if(document.visibilityState==="visible")refreshTitle();
});
const loadAttributesFromQuery=()=>{
const params=new URLSearchParams(window.location.search);
video.controls=parseBoolString(params.get("controls"),true);
video.muted=parseBoolString(params.get("muted"),true);
video.autoplay=parseBoolString(params.get("autoplay"),true);
video.playsInline=parseBoolString(params.get("playsinline"),true);
video.disablepictureinpicture=parseBoolString(params.get("disablepictureinpicture"),false);
defaultControls=video.controls;
};
const waitingText="` + jsString("Waiting for the host to start…") + `";
let retryTimer=null;
let connected=false;
let generation=0;
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
setMessage(waitingText);
if(retryTimer!==null)clearTimeout(retryTimer);
retryTimer=setTimeout(connect,1500);
},
onTrack:(evt)=>{
if(ticket!==generation)return;
connected=true;
if(retryTimer!==null){clearTimeout(retryTimer);retryTimer=null;}
setMessage("");
video.srcObject=evt.streams[0];
const stream=evt.streams[0];
(stream?stream.getTracks():[]).forEach((track)=>{
track.addEventListener("ended",()=>{
if(ticket!==generation||!connected)return;
connected=false;
setMessage(waitingText);
connect();
});
});
applyTitle(document.title);
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
setMessage(waitingText);
connect();
}
},2000);
window.addEventListener("load",()=>{
if(typeof MediaMTXWebRTCReader!=="function"){
setMessage("` + jsString("The listener page could not load.") + `");
return;
}
loadAttributesFromQuery();
setMessage(waitingText);
connect();
});
video.addEventListener("play",()=>applyTitle(document.title));
window.addEventListener("beforeunload",()=>{if(reader!==null)reader.close();});
</script>
` + creditMarkup(icon) + `
</body>
</html>
`
}

func creditMarkup(iconHref string) string {
	logo := ""
	if iconHref != "" {
		logo = `<img alt="" width="28" height="28" src="` + iconHref + `">`
	}
	return `<footer id="credit">` + logo + `<a href="https://roomcast.channel" target="_blank" rel="noopener">Powered by RoomCast</a></footer>`
}

func faviconDataURI() string {
	if len(faviconPNG) == 0 {
		return ""
	}
	return "data:image/png;base64," + base64.StdEncoding.EncodeToString(faviconPNG)
}

func scriptJSON(title string) string {
	payload, err := json.Marshal(map[string]string{"title": title})
	if err != nil {
		return `{"title":"RoomCast Broadcast"}`
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
	const maximum = 80
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
	title := strings.TrimSpace(b.String())
	if title == "" {
		return "RoomCast Broadcast"
	}
	return title
}
