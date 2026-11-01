import Foundation

public enum ListenerAction: Equatable {
  /// The listening page.
  case page
  /// `{"title":"..."}` for the page to read.
  case titleJSON
  /// Lock-screen / Media Session artwork PNG (96 / 192 / 256 / 512).
  case artwork(size: Int)
  /// An older `/live` (or the current stream name) link. Send the phone to `/`.
  case redirectRoot
  /// Forward this request to MediaMTX. `path` includes the query when there is one.
  case proxy(path: String)
  case notFound
}

/// The page phones open at `http://<ip>:<port>/`. MediaMTX only has a page at
/// `/<stream>/`, so the app serves this one and forwards WHEP to the stream.
public enum ListenerPage {
  public static let titlePath = "/earfi.json"
  public static let readerPath = "/reader.js"
  public static let whepPath = "/whep"
  public static let artworkSizes = [96, 192, 256, 512]

  public static func artworkPath(size: Int) -> String { "/artwork-\(size).png" }

  public static func action(method: String, requestTarget: String, streamName: String)
    -> ListenerAction
  {
    let (path, query) = split(requestTarget)
    guard path.hasPrefix("/"), !path.contains(".."), !path.contains("\\") else { return .notFound }
    let verb = method.uppercased()
    if path == "/" && (verb == "GET" || verb == "HEAD") { return .page }
    if path == titlePath && (verb == "GET" || verb == "HEAD") { return .titleJSON }
    if verb == "GET" || verb == "HEAD", isReader(path, streamName: streamName) {
      return .proxy(path: path)
    }
    if let upstream = canonicalWHEP(path, streamName: streamName) {
      if query.isEmpty { return .proxy(path: upstream) }
      return .proxy(path: upstream + "?" + query)
    }
    if (verb == "GET" || verb == "HEAD") && isPageAlias(path, streamName: streamName) {
      return .redirectRoot
    }
    if (verb == "GET" || verb == "HEAD"), let size = artworkSize(for: path) {
      return .artwork(size: size)
    }
    return .notFound
  }

  public static func json(title: String, host: String = "") -> String {
    var object: [String: String] = ["title": title]
    if !host.isEmpty { object["host"] = host }
    guard
      let data = try? JSONSerialization.data(withJSONObject: object),
      let text = String(data: data, encoding: .utf8)
    else { return "{\"title\":\"\"}" }
    return text
  }

  /// JSON object safe to drop into a `<script>` block.
  public static func jsonForScript(title: String, host: String = "") -> String {
    json(title: title, host: host)
      .replacingOccurrences(of: "&", with: "\\u0026")
      .replacingOccurrences(of: "<", with: "\\u003c")
      .replacingOccurrences(of: ">", with: "\\u003e")
      .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
      .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
  }

  /// English copy for the phone page. `ListenerPage.en.json` is the file
  /// translators edit. The running app reads that file from its Resources,
  /// then from the copied SwiftPM bundle. A missing file keeps the fallback.
  static func pageCopy(_ key: String) -> String {
    jsEscape(CoreResources.pageStrings()[key] ?? key)
  }

  private static func jsEscape(_ text: String) -> String {
    text
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
      .replacingOccurrences(of: "<", with: "\\u003c")
      .replacingOccurrences(of: ">", with: "\\u003e")
  }

  /// Tab icon for the listener page. Empty when the PNG is not in the app,
  /// so the page still loads. This does not call `Bundle.module`.
  static let faviconHref: String = CoreResources.faviconDataURI()

  public static func html(title: String, host: String = "") -> String {
    let safeTitle = htmlEscape(title)
    let safeHost = htmlEscape(host)
    let scriptSpec = jsonForScript(title: title, host: host)
    let waiting = htmlEscape(
      CoreResources.pageStrings()["waiting"] ?? "Waiting for the host to start…")
    let tip = htmlEscape(
      CoreResources.pageStrings()["keepOpen"] ?? "Keep this screen open. Earbuds work best.")
    let playLabel = Self.pageCopy("play")
    let pauseLabel = Self.pageCopy("pause")
    let tapLabel = Self.pageCopy("tapToListen")
    let icon =
      faviconHref.isEmpty
      ? ""
      : "<link rel=\"icon\" type=\"image/png\" href=\"\(faviconHref)\">"
    let iconImg =
      faviconHref.isEmpty
      ? ""
      : "<img class=\"icon\" width=\"56\" height=\"56\" alt=\"\" src=\"\(faviconHref)\">"
    let hostLine =
      safeHost.isEmpty
      ? "<div class=\"sub\" id=\"host\" hidden></div>"
      : "<div class=\"sub\" id=\"host\">from \(safeHost)</div>"
    let credit = creditMarkup(iconHref: "")
    return """
      <!doctype html>
      <html lang="en">
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
      <meta name="apple-mobile-web-app-capable" content="yes">
      <title>\(safeTitle)</title>
      \(icon)
      <style>
      :root{
        --navy:#1b1840;--violet:#8b5cf6;--teal:#5fe0c8;--muted:#b9b4e0;--dim:#6f6a9c;
        --icon:clamp(40px,8vh,56px);
        --btn:clamp(96px,18vh,120px);
        --stage:clamp(150px,28.5vh,190px);
      }
      *{box-sizing:border-box;margin:0}
      html,body{
        height:100%;height:100svh;height:100dvh;
        max-height:100svh;max-height:100dvh;
        overflow:hidden;
      }
      body{
        font:-apple-system-body;
        font-family:-apple-system,"Helvetica Neue",Arial,sans-serif;
        color:#fff;
        background:radial-gradient(circle at 50% 35%,#2e2670 0,#1b1840 45%,#0d0b24 100%);
        display:flex;flex-direction:column;align-items:center;
        padding:max(12px,env(safe-area-inset-top)) 20px max(10px,env(safe-area-inset-bottom));
        text-align:center;-webkit-tap-highlight-color:transparent;
        overflow:hidden;
      }
      .icon{
        width:var(--icon);height:var(--icon);border-radius:calc(var(--icon)*0.23);
        display:block;flex-shrink:0;
      }
      .live{
        margin-top:clamp(6px,1.4vh,12px);display:none;gap:7px;align-items:center;
        background:rgba(95,224,200,.14);color:var(--teal);font-weight:700;
        font-size:12px;letter-spacing:.12em;padding:5px 12px;border-radius:99px;flex-shrink:0;
      }
      .live.on{display:inline-flex}
      .dot{width:7px;height:7px;border-radius:50%;background:var(--teal);box-shadow:0 0 0 3px rgba(95,224,200,.25)}
      h1{
        font:-apple-system-title2;font-size:clamp(18px,5.5vw,26px);font-weight:700;
        margin-top:clamp(6px,1.2vh,10px);line-height:1.15;padding:0 8px;flex-shrink:0;
      }
      .sub{color:var(--muted);margin-top:4px;font-size:clamp(13px,3.8vw,15px);flex-shrink:0}
      #message{
        margin-top:clamp(4px,1vh,8px);min-height:1.2em;color:#fff;font-weight:600;font-size:14px;
        text-shadow:0 0 5px #000;padding:0 12px;flex-shrink:0;
      }
      #message:empty{display:none;min-height:0;margin:0;padding:0}
      .stage{
        position:relative;margin:clamp(8px,2vh,16px) 0 clamp(6px,1.4vh,12px);
        width:var(--stage);height:var(--stage);
        display:flex;align-items:center;justify-content:center;flex-shrink:0;
      }
      .ring{position:absolute;border-radius:50%;border:2px solid rgba(139,92,246,.35);pointer-events:none}
      .r1{inset:0}
      .r2{inset:clamp(10px,2.6vmin,16px);border-color:rgba(139,92,246,.55)}
      #playBtn{
        width:var(--btn);height:var(--btn);border-radius:50%;border:0;padding:0;cursor:pointer;
        background:var(--violet);box-shadow:0 10px 32px rgba(139,92,246,.55);
        display:flex;align-items:center;justify-content:center;color:#fff;
        -webkit-appearance:none;appearance:none;
      }
      #playBtn:disabled{opacity:.55;cursor:default}
      #playBtn .pause{display:none;gap:calc(var(--btn)*0.09);align-items:center}
      #playBtn .pause i{
        display:block;width:calc(var(--btn)*0.1);height:calc(var(--btn)*0.37);
        background:#fff;border-radius:5px;
      }
      #playBtn .play{
        display:block;width:0;height:0;border-style:solid;
        border-width:calc(var(--btn)*0.185) 0 calc(var(--btn)*0.185) calc(var(--btn)*0.3);
        border-color:transparent transparent transparent #fff;margin-left:calc(var(--btn)*0.05);
      }
      #playBtn.playing .pause{display:flex}
      #playBtn.playing .play{display:none}
      #meter{
        display:flex;gap:4px;align-items:center;justify-content:center;
        height:clamp(28px,5vh,40px);opacity:0;transition:opacity .2s;margin-bottom:4px;flex-shrink:0;
      }
      #meter.on{opacity:1}
      #meter i{width:5px;border-radius:3px;background:var(--teal);height:6px;opacity:.5;display:block}
      .tip{margin-top:auto;color:var(--muted);font-size:clamp(12px,3.4vw,14px);padding-top:clamp(6px,1.2vh,12px);flex-shrink:0}
      #credit{margin-top:clamp(6px,1vh,10px);color:var(--dim);font-size:11px;flex-shrink:0}
      #credit a{color:var(--dim);text-decoration:none}
      audio{position:absolute;width:1px;height:1px;opacity:0;pointer-events:none}
      </style>
      <script defer src="\(readerPath)"></script>
      </head>
      <body>
      \(iconImg)
      <div class="live" id="live"><span class="dot"></span><span id="liveLabel">LIVE · 0:00</span></div>
      <h1 id="title">\(safeTitle)</h1>
      \(hostLine)
      <div id="message">\(waiting)</div>
      <div class="stage">
        <div class="ring r1"></div>
        <div class="ring r2"></div>
        <button type="button" id="playBtn" disabled aria-label="\(tapLabel)">
          <span class="play" aria-hidden="true"></span>
          <span class="pause" aria-hidden="true"><i></i><i></i></span>
        </button>
      </div>
      <div id="meter" aria-hidden="true"></div>
      <audio id="player" playsinline webkit-playsinline></audio>
      <div class="tip">\(tip)</div>
      \(credit)
      <script>
      const player=document.getElementById("player");
      const message=document.getElementById("message");
      const playBtn=document.getElementById("playBtn");
      const liveEl=document.getElementById("live");
      const liveLabel=document.getElementById("liveLabel");
      const titleEl=document.getElementById("title");
      const hostEl=document.getElementById("host");
      const meterEl=document.getElementById("meter");
      const playLabel="\(playLabel)";
      const pauseLabel="\(pauseLabel)";
      const tapLabel="\(tapLabel)";
      const waitingText="\(Self.pageCopy("waiting"))";
      let reader=null;
      let audioCtx=null;
      let analyser=null;
      let meterRAF=0;
      let audible=false;
      let userPaused=false;
      let trackStream=null;
      let connected=false;
      let liveSince=0;
      let timerID=0;
      let retryTimer=null;
      let generation=0;
      const barCount=14;
      const bars=[];
      for(let i=0;i<barCount;i++){
        const el=document.createElement("i");
        meterEl.appendChild(el);
        bars.push(el);
      }
      const setMessage=(str)=>{message.textContent=str||"";};
      const setPlayingUI=(playing)=>{
        playBtn.classList.toggle("playing",playing);
        playBtn.setAttribute("aria-label",playing?pauseLabel:playLabel);
      };
      const formatElapsed=(ms)=>{
        const sec=Math.max(0,Math.floor(ms/1000));
        const m=Math.floor(sec/60);
        const s=sec%60;
        return m+":"+String(s).padStart(2,"0");
      };
      const paintLive=()=>{
        if(!liveSince){liveLabel.textContent="LIVE · 0:00";return;}
        liveLabel.textContent="LIVE · "+formatElapsed(Date.now()-liveSince);
      };
      const startTimer=()=>{
        if(!liveSince)liveSince=Date.now();
        liveEl.classList.add("on");
        paintLive();
        if(timerID)clearInterval(timerID);
        timerID=setInterval(paintLive,1000);
      };
      const stopTimer=()=>{
        if(timerID){clearInterval(timerID);timerID=0;}
      };
      let sessionTitle="";
      let sessionHost="";
      const artworkList=[96,192,256,512].map((size)=>({
        src:new URL("/artwork-"+size+".png",window.location.href).href,
        sizes:size+"x"+size,
        type:"image/png"
      }));
      const setSessionPlayback=(state)=>{
        try{if(navigator.mediaSession)navigator.mediaSession.playbackState=state;}catch(err){}
      };
      const refreshMediaSession=()=>{
        if(!navigator.mediaSession||typeof MediaMetadata!=="function")return;
        const artist=sessionHost?("from "+sessionHost):"RoomCast";
        navigator.mediaSession.metadata=new MediaMetadata({
          title:sessionTitle||"RoomCast",
          artist:artist,
          album:"RoomCast Live",
          artwork:artworkList
        });
        // Live stream: do not publish position (avoids a scrubber when possible).
        setSessionPlayback((audible&&!player.paused)?"playing":"paused");
      };
      const clearSeekActions=()=>{
        if(!navigator.mediaSession||typeof navigator.mediaSession.setActionHandler!=="function")return;
        ["seekbackward","seekforward","seekto","previoustrack","nexttrack"].forEach((action)=>{
          try{navigator.mediaSession.setActionHandler(action,null);}catch(err){}
        });
      };
      const bindMediaSessionActions=()=>{
        if(!navigator.mediaSession||typeof navigator.mediaSession.setActionHandler!=="function")return;
        const set=(action,handler)=>{try{navigator.mediaSession.setActionHandler(action,handler);}catch(err){}};
        set("play",()=>{unlockFromGesture();});
        set("pause",()=>{
          // iOS may pause <audio> before this runs; still freeze meter + flag.
          pausePlayback();
        });
        set("stop",()=>{
          pausePlayback();
          setSessionPlayback("none");
        });
        clearSeekActions();
      };
      const applyTitle=(title)=>{
        if(!title)return;
        sessionTitle=title;
        document.title=title;
        titleEl.textContent=title;
        player.setAttribute("title",title);
        refreshMediaSession();
      };
      const applyHost=(host)=>{
        sessionHost=host||"";
        if(!hostEl){refreshMediaSession();return;}
        if(!host){hostEl.hidden=true;hostEl.textContent="";refreshMediaSession();return;}
        hostEl.hidden=false;
        hostEl.textContent="from "+host;
        refreshMediaSession();
      };
      const earfiSpec=\(scriptSpec);
      applyTitle(earfiSpec.title);
      applyHost(earfiSpec.host||"");
      bindMediaSessionActions();
      const refreshTitle=()=>{
        fetch("\(titlePath)").then((res)=>res.json()).then((data)=>{
          applyTitle(data.title);
          if(typeof data.host==="string")applyHost(data.host);
        }).catch(()=>{});
      };
      refreshTitle();
      document.addEventListener("visibilitychange",()=>{
        if(document.visibilityState==="visible"){
          refreshTitle();
          if(audible&&!userPaused&&!player.paused)startMeter();
        }else{
          stopMeter();
        }
      });
      const parseBoolString=(str,defaultVal)=>{
        str=(str||"").toLowerCase();
        if(["1","yes","true"].includes(str))return true;
        if(["0","no","false"].includes(str))return false;
        return defaultVal;
      };
      const loadAttributesFromQuery=()=>{
        const params=new URLSearchParams(window.location.search);
        player.muted=parseBoolString(params.get("muted"),false);
        player.autoplay=parseBoolString(params.get("autoplay"),true);
      };
      const ensureAudioGraph=()=>{
        const AC=window.AudioContext||window.webkitAudioContext;
        if(!AC||!trackStream)return;
        if(!audioCtx)audioCtx=new AC();
        if(!analyser){
          try{
            // Tap the WebRTC MediaStream (not the <audio> element) so iOS Safari
            // can analyse levels. Do not connect to destination — playback stays
            // on the <audio> element / Media Session.
            const src=audioCtx.createMediaStreamSource(trackStream);
            analyser=audioCtx.createAnalyser();
            analyser.fftSize=256;
            analyser.smoothingTimeConstant=0.75;
            src.connect(analyser);
          }catch(err){analyser=null;}
        }
      };
      const resumeAudioGraph=()=>{
        ensureAudioGraph();
        if(!audioCtx)return Promise.resolve();
        if(audioCtx.state==="suspended")return audioCtx.resume().catch(()=>{});
        return Promise.resolve();
      };
      const flattenMeter=()=>{
        for(let i=0;i<bars.length;i++){
          bars[i].style.height="6px";
          bars[i].style.opacity="0.5";
        }
      };
      const stopMeter=()=>{
        if(meterRAF){cancelAnimationFrame(meterRAF);meterRAF=0;}
        meterEl.classList.remove("on");
        flattenMeter();
      };
      const startMeter=()=>{
        // MediaStream analyser keeps receiving live audio even when <audio> is
        // paused — never paint while playback is paused from any control.
        if(!analyser||document.hidden||userPaused||player.paused){
          stopMeter();
          return;
        }
        stopMeter();
        meterEl.classList.add("on");
        const bins=new Uint8Array(analyser.frequencyBinCount);
        const paint=()=>{
          meterRAF=requestAnimationFrame(paint);
          if(document.hidden||!analyser||userPaused||player.paused){
            if(meterRAF){cancelAnimationFrame(meterRAF);meterRAF=0;}
            meterEl.classList.remove("on");
            flattenMeter();
            return;
          }
          analyser.getByteFrequencyData(bins);
          const half=barCount/2;
          for(let i=0;i<half;i++){
            const idx=Math.min(bins.length-1,Math.floor((i/(half-1||1))*(bins.length*0.45)));
            const level=bins[idx]/255;
            const h=Math.max(6,6+level*30);
            const op=(0.5+level*0.45).toFixed(2);
            const left=bars[half-1-i];
            const right=bars[half+i];
            left.style.height=h+"px";
            left.style.opacity=op;
            right.style.height=h+"px";
            right.style.opacity=op;
          }
        };
        paint();
      };
      const markAudible=()=>{
        audible=true;
        userPaused=false;
        playBtn.disabled=false;
        setPlayingUI(true);
        setMessage("");
        startTimer();
        clearSeekActions();
        setSessionPlayback("playing");
        resumeAudioGraph().then(()=>{
          if(userPaused||player.paused){stopMeter();return;}
          if(!analyser)ensureAudioGraph();
          startMeter();
        });
      };
      const pausePlayback=()=>{
        // Intentional pause: keep the WebRTC track; do not reconnect or auto-play.
        userPaused=true;
        try{player.pause();}catch(err){}
        stopMeter();
        setPlayingUI(false);
        setSessionPlayback("paused");
        clearSeekActions();
      };
      const tryAudiblePlay=()=>{
        if(userPaused){
          playBtn.disabled=false;
          setPlayingUI(false);
          setSessionPlayback("paused");
          stopMeter();
          return Promise.resolve(false);
        }
        player.muted=false;
        const p=player.play();
        if(p&&typeof p.then==="function"){
          return p.then(()=>{
            if(userPaused){player.pause();setPlayingUI(false);setSessionPlayback("paused");return false;}
            if(player.muted){setPlayingUI(false);playBtn.setAttribute("aria-label",tapLabel);return false;}
            markAudible();
            return true;
          }).catch(()=>{setPlayingUI(false);playBtn.setAttribute("aria-label",tapLabel);return false;});
        }
        if(player.paused||player.muted){setPlayingUI(false);playBtn.setAttribute("aria-label",tapLabel);return Promise.resolve(false);}
        markAudible();
        return Promise.resolve(true);
      };
      // Safari iOS: create/resume AudioContext inside the Play gesture.
      const unlockFromGesture=()=>{
        if(!trackStream){
          // Stream not ready — ensure we are connecting, then play on onTrack.
          userPaused=false;
          if(!connected)connect();
          return;
        }
        userPaused=false;
        // Re-attach if the element lost its srcObject while paused.
        if(player.srcObject!==trackStream)player.srcObject=trackStream;
        resumeAudioGraph().then(()=>{
          if(userPaused)return;
          if(!analyser)ensureAudioGraph();
          player.muted=false;
          const p=player.play();
          if(p&&typeof p.then==="function"){
            p.then(()=>{
              if(userPaused){try{player.pause();}catch(err){}return;}
              markAudible();
            }).catch(()=>{setPlayingUI(false);playBtn.setAttribute("aria-label",tapLabel);});
          }else{
            if(!userPaused)markAudible();
          }
        });
      };
      const togglePlayback=()=>{
        // Prefer userPaused so pause stays paused even if player.paused races.
        // Play is allowed with no track yet (unlockFromGesture will connect).
        if(userPaused||!audible||player.paused){
          unlockFromGesture();
          return;
        }
        if(!trackStream)return;
        pausePlayback();
      };
      playBtn.addEventListener("click",(evt)=>{evt.preventDefault();evt.stopPropagation();togglePlayback();});
      const connect=()=>{
        if(connected)return;
        if(retryTimer!==null){clearTimeout(retryTimer);retryTimer=null;}
        const ticket=++generation;
        if(reader!==null){try{reader.close();}catch(err){}reader=null;}
        reader=new MediaMTXWebRTCReader({
          url:new URL("\(whepPath)",window.location.href).toString(),
          onError:(err)=>{
            if(ticket!==generation)return;
            // Drop the live pipe. Auto-retry only when the user has not paused;
            // a paused listener keeps silence until they press Play (which calls connect).
            connected=false;
            trackStream=null;
            try{player.srcObject=null;}catch(e){}
            stopMeter();
            if(userPaused){
              setPlayingUI(false);
              setSessionPlayback("paused");
              playBtn.disabled=false;
              playBtn.setAttribute("aria-label",playLabel);
              if(retryTimer!==null){clearTimeout(retryTimer);retryTimer=null;}
              return;
            }
            setMessage(waitingText);
            playBtn.disabled=true;
            liveEl.classList.remove("on");
            if(retryTimer!==null)clearTimeout(retryTimer);
            retryTimer=setTimeout(connect,1500);
          },
          onTrack:(evt)=>{
            if(ticket!==generation)return;
            connected=true;
            if(retryTimer!==null){clearTimeout(retryTimer);retryTimer=null;}
            setMessage("");
            trackStream=evt.streams[0];
            player.srcObject=trackStream;
            playBtn.disabled=false;
            applyTitle(document.title);
            startTimer();
            // Reconnect / new track: leave the stream alone while the user is paused.
            if(userPaused){
              setPlayingUI(false);
              setSessionPlayback("paused");
              playBtn.setAttribute("aria-label",playLabel);
              return;
            }
            playBtn.setAttribute("aria-label",tapLabel);
            tryAudiblePlay();
          },
          onDataChannel:(evt)=>{
            evt.channel.binaryType="arraybuffer";
            evt.channel.onmessage=(evt)=>{console.log("data channel message",evt.data);};
          },
        });
      };
      window.addEventListener("load",()=>{
        if(typeof MediaMTXWebRTCReader!=="function"){
          setMessage("\(Self.pageCopy("loadError"))");
          return;
        }
        loadAttributesFromQuery();
        setMessage(waitingText);
        connect();
      });
      player.addEventListener("play",()=>{
        applyTitle(document.title);
        if(!userPaused&&!player.paused){
          resumeAudioGraph().then(()=>{
            if(userPaused||player.paused){stopMeter();return;}
            if(!analyser)ensureAudioGraph();
            startMeter();
          });
        }
      });
      player.addEventListener("pause",()=>{
        userPaused=true;
        stopMeter();
        if(audible)setPlayingUI(false);
        setSessionPlayback("paused");
        clearSeekActions();
      });
      window.addEventListener("beforeunload",()=>{
        if(reader!==null)reader.close();
        stopMeter();
        stopTimer();
        if(audioCtx){try{audioCtx.close();}catch(err){}}
      });
      </script>
      </body>
      </html>
      """
  }

  /// Quiet line under the player. The app icon already sits at the top, so
  /// the footer is text-only. The link needs a network; the page does not.
  static func creditMarkup(iconHref: String) -> String {
    let label = htmlEscape(CoreResources.pageStrings()["poweredBy"] ?? "Powered by RoomCast")
    _ = iconHref
    return
      "<footer id=\"credit\"><a href=\"https://roomcast.channel\" target=\"_blank\" rel=\"noopener\">\(label)</a></footer>"
  }


  private static func artworkSize(for path: String) -> Int? {
    for size in artworkSizes {
      if path == artworkPath(size: size) { return size }
    }
    return nil
  }

  private static func htmlEscape(_ text: String) -> String {
    text
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
  }

  private static func split(_ target: String) -> (path: String, query: String) {
    guard let mark = target.firstIndex(of: "?") else { return (target, "") }
    return (String(target[..<mark]), String(target[target.index(after: mark)...]))
  }

  private static func names(streamName: String) -> [String] {
    let stream = streamName.isEmpty ? "live" : streamName
    if stream == "live" { return ["live"] }
    return [stream, "live"]
  }

  private static func isReader(_ path: String, streamName: String) -> Bool {
    if path == readerPath { return true }
    return names(streamName: streamName).contains { path == "/\($0)\(readerPath)" }
  }

  private static func isPageAlias(_ path: String, streamName: String) -> Bool {
    names(streamName: streamName).contains { path == "/\($0)" || path == "/\($0)/" }
  }

  /// `/whep` and `/<name>/whep` both play the current stream.
  private static func canonicalWHEP(_ path: String, streamName: String) -> String? {
    let stream = streamName.isEmpty ? "live" : streamName
    if let rest = sessionRest(path, prefix: whepPath) {
      return "/\(stream)\(whepPath)" + rest
    }
    for name in names(streamName: stream) {
      if let rest = sessionRest(path, prefix: "/\(name)\(whepPath)") {
        return "/\(stream)\(whepPath)" + rest
      }
    }
    return nil
  }

  /// `""` for the collection, `"/<id>"` for a session, nil when it is not WHEP.
  private static func sessionRest(_ path: String, prefix: String) -> String? {
    if path == prefix { return "" }
    let session = prefix + "/"
    guard path.hasPrefix(session) else { return nil }
    let id = String(path.dropFirst(session.count))
    let token = id.allSatisfy { character in
      character.isLetter || character.isNumber || character == "-"
    }
    guard !id.isEmpty, !id.contains("/"), token else { return nil }
    return "/" + id
  }
}
