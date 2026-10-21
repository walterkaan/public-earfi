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

  public static func html(title: String) -> String {
    let safeTitle = htmlEscape(title)
    let scriptTitle = jsonForScript(title: title)
    return """
      <!doctype html>
      <html>
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width">
      <title>\(safeTitle)</title>
      <style>
      html,body{margin:0;padding:0;height:100%;font-family:Arial,sans-serif}
      #video{position:absolute;top:0;left:0;width:100%;height:100%;background:rgb(30,30,30)}
      #message{position:absolute;left:0;top:0;width:100%;height:100%;display:flex;align-items:center;text-align:center;justify-content:center;font-size:16px;font-weight:bold;color:#fff;pointer-events:none;padding:20px;box-sizing:border-box;text-shadow:0 0 5px #000;z-index:1}
      #playerTitle{position:absolute;z-index:2;left:8px;bottom:calc(env(safe-area-inset-bottom, 0px) + 5px);max-width:calc(100% - 124px);min-width:9em;height:32px;box-sizing:border-box;display:flex;align-items:center;padding:0 10px;color:#fff;background:rgb(30,30,30);font:600 16px/1.1 -apple-system,BlinkMacSystemFont,sans-serif;pointer-events:none;overflow:hidden;white-space:nowrap;text-overflow:ellipsis}
      </style>
      <script defer src="\(readerPath)"></script>
      </head>
      <body>
      <video id="video" title="\(safeTitle)"></video>
      <div id="message"></div>
      <div id="playerTitle">\(safeTitle)</div>
      <script>
      const video=document.getElementById("video");
      const message=document.getElementById("message");
      const playerTitle=document.getElementById("playerTitle");
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
      if(playerTitle)playerTitle.textContent=title;
      if(navigator.mediaSession&&typeof MediaMetadata==="function"){
      navigator.mediaSession.metadata=new MediaMetadata({title:title});
      try{navigator.mediaSession.playbackState="playing";}catch(err){}
      }
      const root=video.shadowRoot;
      if(root){
      const label=root.querySelector(".status-label");
      if(label)label.textContent=title;
      }
      };
      const earfiSpec=\(scriptTitle);
      applyTitle(earfiSpec.title);
      const refreshTitle=()=>{
      fetch("\(titlePath)").then((res)=>res.json()).then((data)=>applyTitle(data.title)).catch(()=>{});
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
      window.addEventListener("load",()=>{
      if(typeof MediaMTXWebRTCReader!=="function"){
      setMessage("The listener page could not load.");
      return;
      }
      loadAttributesFromQuery();
      reader=new MediaMTXWebRTCReader({
      url:new URL("\(whepPath)",window.location.href).toString(),
      onError:(err)=>{setMessage(err);},
      onTrack:(evt)=>{setMessage("");video.srcObject=evt.streams[0];applyTitle(playerTitle?playerTitle.textContent:document.title);},
      onDataChannel:(evt)=>{
      evt.channel.binaryType="arraybuffer";
      evt.channel.onmessage=(evt)=>{console.log("data channel message",evt.data);};
      },
      });
      });
      video.addEventListener("play",()=>applyTitle(playerTitle?playerTitle.textContent:document.title));
      window.addEventListener("beforeunload",()=>{if(reader!==null)reader.close();});
      </script>
      </body>
      </html>
      """
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
