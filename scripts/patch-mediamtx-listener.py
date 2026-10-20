#!/usr/bin/env python3
"""Give the bundled MediaMTX listener page a title.

MediaMTX v1.21.2 serves an embedded page (internal/servers/webrtc/read_index.html)
with no <title> and no Media Session name. Phones then show "Live Broadcast".
The file is stored uncompressed in the binary. This replaces that exact byte
string with a same-length page that reads ?title=, sets document.title and
navigator.mediaSession.metadata, and removes title before the WHEP request.

scripts/mediamtx-read-index.html is the unmodified v1.21.2 page (MIT).
The ffmpeg build is not involved. Run --self-test without a binary.
"""

import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent
ORIGINAL_PATH = ROOT / "mediamtx-read-index.html"
MARKER = b"const earfiTitle="

# Shorter than the upstream page. The patcher pads with an HTML comment so
# the embedded slice keeps its original length.
TEMPLATE = """<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width">
<title>Broadcast</title>
<style>
html,body{margin:0;padding:0;height:100%;font-family:Arial,sans-serif}
#video{position:absolute;top:0;left:0;width:100%;height:100%;background:rgb(30,30,30)}
#message{position:absolute;left:0;top:0;width:100%;height:100%;display:flex;align-items:center;text-align:center;justify-content:center;font-size:16px;font-weight:bold;color:#fff;pointer-events:none;padding:20px;box-sizing:border-box;text-shadow:0 0 5px #000}
</style>
<script defer src="./reader.js"></script>
</head>
<body>
<video id="video"></video>
<div id="message"></div>
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
const earfiTitle=()=>{
const title=new URLSearchParams(window.location.search).get("title");
if(!title)return;
document.title=title;
video.title=title;
if(navigator.mediaSession&&typeof MediaMetadata==="function"){
navigator.mediaSession.metadata=new MediaMetadata({title:title});
}
};
const whepSearch=()=>{
const kept=window.location.search.replace(/^\\?/,"").split("&").filter((part)=>part&&part.slice(0,6)!=="title=");
return kept.length?"?"+kept.join("&"):"";
};
const loadAttributesFromQuery=()=>{
const params=new URLSearchParams(window.location.search);
video.controls=parseBoolString(params.get("controls"),true);
video.muted=parseBoolString(params.get("muted"),true);
video.autoplay=parseBoolString(params.get("autoplay"),true);
video.playsInline=parseBoolString(params.get("playsinline"),true);
video.disablepictureinpicture=parseBoolString(params.get("disablepictureinpicture"),false);
defaultControls=video.controls;
earfiTitle();
};
window.addEventListener("load",()=>{
loadAttributesFromQuery();
reader=new MediaMTXWebRTCReader({
url:new URL("whep",window.location.href)+whepSearch(),
onError:(err)=>{setMessage(err);},
onTrack:(evt)=>{setMessage("");video.srcObject=evt.streams[0];earfiTitle();},
onDataChannel:(evt)=>{
evt.channel.binaryType="arraybuffer";
evt.channel.onmessage=(evt)=>{console.log("data channel message",evt.data);};
},
});
});
window.addEventListener("beforeunload",()=>{if(reader!==null)reader.close();});
</script>
</body>
</html>
"""


def whep_search(search: str) -> str:
    """Same rule as whepSearch() in the patched page."""
    raw = search[1:] if search.startswith("?") else search
    kept = [part for part in raw.split("&") if part and not part.startswith("title=")]
    return ("?" + "&".join(kept)) if kept else ""


def patched_page(size: int) -> bytes:
    body = TEMPLATE.encode("utf-8")
    if b"earfiTitle" not in body or b"reader.js" not in body or b"whepSearch" not in body:
        raise SystemExit("patched listener page is missing its title hook")
    pad = size - len(body)
    if pad < 7:
        raise SystemExit(
            f"patched listener page is {len(body)} bytes; the embedded page is {size}"
        )
    comment = b"<!--" + (b" " * (pad - 7)) + b"-->"
    if b"</html>" not in body:
        raise SystemExit("patched listener page has no </html>")
    updated = body.replace(b"</html>", comment + b"</html>", 1)
    if len(updated) != size:
        raise SystemExit(f"padded page is {len(updated)} bytes, wanted {size}")
    return updated


def patch(blob: bytes, original: bytes, replacement: bytes) -> bytes:
    if len(original) != len(replacement):
        raise SystemExit("listener page replacement changed length")
    count = blob.count(original)
    if count == 0:
        if MARKER in blob:
            return blob
        raise SystemExit(
            "mediamtx does not contain the v1.21.2 listener page, so the title cannot be set"
        )
    updated = blob.replace(original, replacement)
    if updated.count(MARKER) < count:
        raise SystemExit("listener page patch did not land in every copy")
    if original in updated:
        raise SystemExit("the original listener page is still in mediamtx")
    if len(updated) != len(blob):
        raise SystemExit("patching mediamtx changed its size")
    return updated


def self_test() -> None:
    original = ORIGINAL_PATH.read_bytes()
    replacement = patched_page(len(original))
    assert whep_search("?title=Hi&controls=1") == "?controls=1"
    assert whep_search("?title=Hi") == ""
    assert whep_search("?muted=0&title=A&autoplay=1") == "?muted=0&autoplay=1"
    assert whep_search("?titlepage=1") == "?titlepage=1"
    blob = b"prefix" + original + b"middle" + original + b"suffix"
    once = patch(blob, original, replacement)
    assert len(once) == len(blob)
    assert original not in once
    assert once.count(MARKER) == 2
    twice = patch(once, original, replacement)
    assert twice == once
    print("listener page patch self-test passed")


def main(argv: list[str]) -> None:
    if argv == ["--self-test"]:
        self_test()
        return
    if not argv:
        raise SystemExit("usage: patch-mediamtx-listener.py [--self-test] <mediamtx>...")
    original = ORIGINAL_PATH.read_bytes()
    replacement = patched_page(len(original))
    for raw in argv:
        path = pathlib.Path(raw)
        blob = path.read_bytes()
        updated = patch(blob, original, replacement)
        if updated != blob:
            path.write_bytes(updated)
        print(f"listener page title hook is in {path}")


if __name__ == "__main__":
    main(sys.argv[1:])
