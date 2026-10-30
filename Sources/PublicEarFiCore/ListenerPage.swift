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

  public static func json(title: String) -> String {
    guard
      let data = try? JSONSerialization.data(withJSONObject: ["title": title]),
      let text = String(data: data, encoding: .utf8)
    else { return "{\"title\":\"\"}" }
    return text
  }

  /// JSON object safe to drop into a `<script>` block.
  public static func jsonForScript(title: String) -> String {
    json(title: title)
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

  public static func html(title: String) -> String {
    let safeTitle = htmlEscape(title)
    let scriptTitle = jsonForScript(title: title)
    let waiting = htmlEscape(
      CoreResources.pageStrings()["waiting"] ?? "Waiting for the host to start…")
    let icon =
      faviconHref.isEmpty
      ? ""
      : "<link rel=\"icon\" type=\"image/png\" href=\"\(faviconHref)\">"
    let credit = creditMarkup(iconHref: faviconHref)
    return """
      <!doctype html>
      <html>
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width">
      <title>\(safeTitle)</title>
      \(icon)
      <style>
      html,body{margin:0;padding:0;height:100%;background:#161a42;font-family:Arial,sans-serif;color:#fff}
      #video{position:absolute;top:0;left:0;width:100%;height:calc(100% - 44px);background:#161a42}
      #message{position:absolute;left:0;top:0;right:0;bottom:44px;display:flex;align-items:center;text-align:center;justify-content:center;font-size:16px;font-weight:bold;color:#fff;pointer-events:none;padding:20px;box-sizing:border-box;text-shadow:0 0 5px #000;z-index:1}
      #unlock{position:absolute;left:0;top:0;right:0;bottom:44px;display:none;align-items:center;justify-content:center;z-index:5;background:rgba(22,26,66,0.88);cursor:pointer;-webkit-tap-highlight-color:transparent}
      #unlockBtn{border:0;border-radius:18px;padding:22px 36px;font-size:22px;font-weight:700;color:#161a42;background:#2fd0bd;box-shadow:0 8px 28px rgba(0,0,0,0.35);pointer-events:none}
      #vu{position:absolute;left:16px;right:16px;bottom:56px;height:26px;z-index:3;pointer-events:none;opacity:0;transition:opacity .2s}
      #vu.on{opacity:1}
      #credit{position:absolute;left:0;right:0;bottom:0;height:44px;display:flex;align-items:center;justify-content:center;gap:8px;background:#161a42;border-top:1px solid rgba(47,208,189,0.35);z-index:2;font-size:13px}
      #credit img{width:28px;height:28px;border-radius:7px;display:block}
      #credit a{color:rgba(255,255,255,0.58);text-decoration:none}
      </style>
      <script defer src="\(readerPath)"></script>
      </head>
      <body>
      <video id="video" title="\(safeTitle)" playsinline webkit-playsinline></video>
      <div id="message">\(waiting)</div>
      <div id="unlock" role="button" aria-label="\(Self.pageCopy("tapToListen"))"><span id="unlockBtn">\(Self.pageCopy("tapToListen"))</span></div>
      <canvas id="vu" width="320" height="26" aria-hidden="true"></canvas>
      <script>
      const video=document.getElementById("video");
      const message=document.getElementById("message");
      const unlock=document.getElementById("unlock");
      const vu=document.getElementById("vu");
      let defaultControls=false;
      let reader=null;
      let audioCtx=null;
      let analyser=null;
      let meterRAF=0;
      let audible=false;
      let trackStream=null;
      const setMessage=(str)=>{video.controls=str!==""?false:defaultControls;message.innerText=str;};
      const showUnlock=()=>{unlock.style.display="flex";};
      const hideUnlock=()=>{unlock.style.display="none";};
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
      const earfiSpec=\(scriptTitle);
      applyTitle(earfiSpec.title);
      const refreshTitle=()=>{
      fetch("\(titlePath)").then((res)=>res.json()).then((data)=>applyTitle(data.title)).catch(()=>{});
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
      const loadAttributesFromQuery=()=>{
      const params=new URLSearchParams(window.location.search);
      video.controls=parseBoolString(params.get("controls"),true);
      // Prefer unmuted; browsers that block audible autoplay get the Tap overlay.
      video.muted=parseBoolString(params.get("muted"),false);
      video.autoplay=parseBoolString(params.get("autoplay"),true);
      video.playsInline=parseBoolString(params.get("playsinline"),true);
      video.disablepictureinpicture=parseBoolString(params.get("disablepictureinpicture"),false);
      defaultControls=video.controls;
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
      if(!analyser||document.hidden)return;
      stopMeter();
      vu.classList.add("on");
      const bins=new Uint8Array(analyser.frequencyBinCount);
      const paint=()=>{
      meterRAF=requestAnimationFrame(paint);
      if(document.hidden||!analyser)return;
      analyser.getByteFrequencyData(bins);
      const w=vu.clientWidth||320;
      const h=vu.clientHeight||26;
      if(vu.width!==w)vu.width=w;
      if(vu.height!==h)vu.height=h;
      const ctx=vu.getContext("2d");
      if(!ctx)return;
      ctx.clearRect(0,0,w,h);
      const bars=24;
      const gap=2;
      const bw=Math.max(2,(w-(bars-1)*gap)/bars);
      for(let i=0;i<bars;i++){
      const idx=Math.min(bins.length-1,Math.floor(i*bins.length/bars));
      const level=bins[idx]/255;
      const bh=Math.max(2,level*h);
      const x=i*(bw+gap);
      ctx.fillStyle="rgba(47,208,189,"+(0.35+level*0.65).toFixed(2)+")";
      ctx.fillRect(x,h-bh,bw,bh);
      }
      };
      paint();
      };
      const markAudible=()=>{
      audible=true;
      hideUnlock();
      ensureAudioGraph();
      if(audioCtx&&audioCtx.state==="suspended"){
      audioCtx.resume().catch(()=>{});
      }
      startMeter();
      };
      const tryAudiblePlay=()=>{
      video.muted=false;
      const p=video.play();
      if(p&&typeof p.then==="function"){
      return p.then(()=>{
      if(video.muted){showUnlock();return false;}
      markAudible();
      return true;
      }).catch(()=>{showUnlock();return false;});
      }
      if(video.paused||video.muted){showUnlock();return Promise.resolve(false);}
      markAudible();
      return Promise.resolve(true);
      };
      // Safari iOS: create/resume AudioContext inside the gesture.
      const unlockFromGesture=()=>{
      if(!trackStream)return;
      ensureAudioGraph();
      const resume=audioCtx?audioCtx.resume():Promise.resolve();
      Promise.resolve(resume).catch(()=>{}).then(()=>{
      video.muted=false;
      const p=video.play();
      if(p&&typeof p.then==="function"){
      p.then(markAudible).catch(()=>{showUnlock();});
      }else{
      markAudible();
      }
      });
      };
      const onFirstGesture=()=>{
      if(audible)return;
      if(!trackStream)return;
      unlockFromGesture();
      };
      ["pointerdown","touchstart","click"].forEach((type)=>{
      document.addEventListener(type,onFirstGesture,{passive:true});
      });
      unlock.addEventListener("click",(evt)=>{evt.preventDefault();onFirstGesture();});
      const waitingText="\(Self.pageCopy("waiting"))";
      let retryTimer=null;
      let connected=false;
      let generation=0;
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
      hideUnlock();
      if(retryTimer!==null)clearTimeout(retryTimer);
      retryTimer=setTimeout(connect,1500);
      },
      onTrack:(evt)=>{
      if(ticket!==generation)return;
      connected=true;
      if(retryTimer!==null){clearTimeout(retryTimer);retryTimer=null;}
      setMessage("");
      trackStream=evt.streams[0];
      video.srcObject=trackStream;
      applyTitle(document.title);
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
      video.addEventListener("play",()=>applyTitle(document.title));
      window.addEventListener("beforeunload",()=>{if(reader!==null)reader.close();stopMeter();if(audioCtx){try{audioCtx.close();}catch(err){}}});
      </script>
      \(credit)
      </body>
      </html>
      """
  }

  /// Quiet line under the player. The icon is the favicon PNG. No icon when
  /// that file is missing. The link needs a network; the page does not.
  static func creditMarkup(iconHref: String) -> String {
    let label = htmlEscape(CoreResources.pageStrings()["poweredBy"] ?? "Powered by RoomCast")
    let logo =
      iconHref.isEmpty
      ? ""
      : "<img alt=\"\" width=\"28\" height=\"28\" src=\"\(iconHref)\">"
    return
      "<footer id=\"credit\">\(logo)<a href=\"https://roomcast.channel\" target=\"_blank\" rel=\"noopener\">\(label)</a></footer>"
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
