import Foundation

public enum ListenerAction: Equatable {
  /// The listening page.
  case page
  /// `{"title":"..."}` for the page to read.
  case titleJSON
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
      :root{--navy:#1b1840;--violet:#8b5cf6;--teal:#5fe0c8;--muted:#b9b4e0;--dim:#6f6a9c}
      *{box-sizing:border-box;margin:0}
      html,body{min-height:100%;}
      body{
        font:-apple-system-body;
        font-family:-apple-system,"Helvetica Neue",Arial,sans-serif;
        color:#fff;
        min-height:100vh;min-height:100dvh;
        background:radial-gradient(circle at 50% 35%,#2e2670 0,#1b1840 45%,#0d0b24 100%);
        display:flex;flex-direction:column;align-items:center;
        padding:max(28px,env(safe-area-inset-top)) 24px max(20px,env(safe-area-inset-bottom));
        text-align:center;-webkit-tap-highlight-color:transparent;
      }
      .icon{width:56px;height:56px;border-radius:13px;display:block}
      .live{
        margin-top:22px;display:none;gap:8px;align-items:center;
        background:rgba(95,224,200,.14);color:var(--teal);font-weight:700;
        font-size:13px;letter-spacing:.12em;padding:6px 14px;border-radius:99px;
      }
      .live.on{display:inline-flex}
      .dot{width:8px;height:8px;border-radius:50%;background:var(--teal);box-shadow:0 0 0 4px rgba(95,224,200,.25)}
      h1{font:-apple-system-title2;font-size:clamp(22px,7vw,30px);font-weight:700;margin-top:14px;line-height:1.15;padding:0 8px}
      .sub{color:var(--muted);margin-top:6px;font-size:16px}
      #message{
        margin-top:14px;min-height:1.3em;color:#fff;font-weight:600;font-size:15px;
        text-shadow:0 0 5px #000;padding:0 12px;
      }
      .stage{position:relative;margin:36px 0 22px;width:240px;height:240px;display:flex;align-items:center;justify-content:center;flex-shrink:0}
      .ring{position:absolute;border-radius:50%;border:2px solid rgba(139,92,246,.35);pointer-events:none}
      .r1{inset:0}.r2{inset:22px;border-color:rgba(139,92,246,.55)}
      #playBtn{
        width:150px;height:150px;border-radius:50%;border:0;padding:0;cursor:pointer;
        background:var(--violet);box-shadow:0 12px 40px rgba(139,92,246,.55);
        display:flex;align-items:center;justify-content:center;color:#fff;
        -webkit-appearance:none;appearance:none;
      }
      #playBtn:disabled{opacity:.55;cursor:default}
      #playBtn .pause{display:none;gap:14px;align-items:center}
      #playBtn .pause i{display:block;width:16px;height:56px;background:#fff;border-radius:5px}
      #playBtn .play{display:block;width:0;height:0;border-style:solid;border-width:28px 0 28px 46px;border-color:transparent transparent transparent #fff;margin-left:8px}
      #playBtn.playing .pause{display:flex}
      #playBtn.playing .play{display:none}
      #meter{display:flex;gap:5px;align-items:center;justify-content:center;height:44px;opacity:0;transition:opacity .2s;margin-bottom:8px}
      #meter.on{opacity:1}
      #meter i{width:6px;border-radius:3px;background:var(--teal);height:8px;opacity:.5;display:block}
      .tip{margin-top:auto;color:var(--muted);font-size:15px;padding-top:28px}
      #credit{margin-top:16px;color:var(--dim);font-size:12px}
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
      const applyTitle=(title)=>{
        if(!title)return;
        document.title=title;
        titleEl.textContent=title;
        player.setAttribute("title",title);
        if(navigator.mediaSession&&typeof MediaMetadata==="function"){
          navigator.mediaSession.metadata=new MediaMetadata({title:title});
          try{navigator.mediaSession.playbackState=player.paused?"paused":"playing";}catch(err){}
        }
      };
      const applyHost=(host)=>{
        if(!hostEl)return;
        if(!host){hostEl.hidden=true;hostEl.textContent="";return;}
        hostEl.hidden=false;
        hostEl.textContent="from "+host;
      };
      const earfiSpec=\(scriptSpec);
      applyTitle(earfiSpec.title);
      applyHost(earfiSpec.host||"");
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
          if(audible)startMeter();
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
            const src=audioCtx.createMediaStreamSource(trackStream);
            analyser=audioCtx.createAnalyser();
            analyser.fftSize=256;
            analyser.smoothingTimeConstant=0.75;
            src.connect(analyser);
          }catch(err){analyser=null;}
        }
      };
      const stopMeter=()=>{
        if(meterRAF){cancelAnimationFrame(meterRAF);meterRAF=0;}
      };
      const startMeter=()=>{
        if(!analyser||document.hidden){meterEl.classList.remove("on");return;}
        stopMeter();
        meterEl.classList.add("on");
        const bins=new Uint8Array(analyser.frequencyBinCount);
        const paint=()=>{
          meterRAF=requestAnimationFrame(paint);
          if(document.hidden||!analyser)return;
          analyser.getByteFrequencyData(bins);
          const half=barCount/2;
          for(let i=0;i<half;i++){
            const idx=Math.min(bins.length-1,Math.floor((i/(half-1||1))*(bins.length*0.45)));
            const level=bins[idx]/255;
            const h=Math.max(8,8+level*36);
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
        playBtn.disabled=false;
        setPlayingUI(true);
        setMessage("");
        ensureAudioGraph();
        if(audioCtx&&audioCtx.state==="suspended"){
          audioCtx.resume().catch(()=>{});
        }
        startMeter();
        startTimer();
        try{if(navigator.mediaSession)navigator.mediaSession.playbackState="playing";}catch(err){}
      };
      const tryAudiblePlay=()=>{
        player.muted=false;
        const p=player.play();
        if(p&&typeof p.then==="function"){
          return p.then(()=>{
            if(player.muted){setPlayingUI(false);playBtn.setAttribute("aria-label",tapLabel);return false;}
            markAudible();
            return true;
          }).catch(()=>{setPlayingUI(false);playBtn.setAttribute("aria-label",tapLabel);return false;});
        }
        if(player.paused||player.muted){setPlayingUI(false);playBtn.setAttribute("aria-label",tapLabel);return Promise.resolve(false);}
        markAudible();
        return Promise.resolve(true);
      };
      const unlockFromGesture=()=>{
        if(!trackStream)return;
        ensureAudioGraph();
        const resume=audioCtx?audioCtx.resume():Promise.resolve();
        Promise.resolve(resume).catch(()=>{}).then(()=>{
          player.muted=false;
          const p=player.play();
          if(p&&typeof p.then==="function"){
            p.then(markAudible).catch(()=>{setPlayingUI(false);playBtn.setAttribute("aria-label",tapLabel);});
          }else{
            markAudible();
          }
        });
      };
      const togglePlayback=()=>{
        if(!trackStream)return;
        if(!audible||player.paused){
          unlockFromGesture();
          return;
        }
        player.pause();
        setPlayingUI(false);
        try{if(navigator.mediaSession)navigator.mediaSession.playbackState="paused";}catch(err){}
      };
      playBtn.addEventListener("click",(evt)=>{evt.preventDefault();togglePlayback();});
      const connect=()=>{
        if(connected)return;
        if(retryTimer!==null){clearTimeout(retryTimer);retryTimer=null;}
        const ticket=++generation;
        if(reader!==null){try{reader.close();}catch(err){}reader=null;}
        reader=new MediaMTXWebRTCReader({
          url:new URL("\(whepPath)",window.location.href).toString(),
          onError:(err)=>{
            if(ticket!==generation||connected)return;
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
            playBtn.setAttribute("aria-label",tapLabel);
            applyTitle(document.title);
            startTimer();
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
      player.addEventListener("play",()=>applyTitle(document.title));
      player.addEventListener("pause",()=>{if(audible)setPlayingUI(false);});
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
