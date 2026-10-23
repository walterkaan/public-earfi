#!/bin/bash
# Download pinned MediaMTX binaries and build a universal LGPL ffmpeg + libopus.
# Nothing in this script enables GPL or non-free components.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck disable=SC1091
source "$ROOT/scripts/versions.env"

OUT="$ROOT/build/helpers"
SRC="$ROOT/build/src"
mkdir -p "$OUT" "$SRC"

if ! command -v pkg-config >/dev/null 2>&1; then
  echo "Installing pkg-config"
  brew install pkg-config
fi

stamp_input="$(cat "$ROOT/scripts/versions.env" "$ROOT/scripts/ffmpeg-configure-flags.txt")"
STAMP="$(printf '%s' "$stamp_input" | shasum -a 256 | awk '{print $1}')"
if [[ -f "$OUT/STAMP" && "$(cat "$OUT/STAMP")" == "$STAMP" \
  && -x "$OUT/mediamtx" && -x "$OUT/ffmpeg" ]]; then
  if lipo -info "$OUT/ffmpeg" | grep -q "arm64" && lipo -info "$OUT/ffmpeg" | grep -q "x86_64" \
    && lipo -info "$OUT/mediamtx" | grep -q "arm64" && lipo -info "$OUT/mediamtx" | grep -q "x86_64"; then
    echo "Helper cache is current ($STAMP)"
    exit 0
  fi
fi

download() {
  local url="$1" dest="$2" sha="$3"
  echo "Downloading $url"
  curl -fL --retry 5 --retry-delay 2 -o "$dest" "$url"
  echo "$sha  $dest" | shasum -a 256 -c -
}

JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
export MACOSX_DEPLOYMENT_TARGET=13.0

download \
  "https://github.com/bluenviron/mediamtx/releases/download/v${MEDIAMTX_VERSION}/mediamtx_v${MEDIAMTX_VERSION}_darwin_arm64.tar.gz" \
  "$SRC/mediamtx-arm64.tar.gz" \
  "$MEDIAMTX_DARWIN_ARM64_SHA256"
download \
  "https://github.com/bluenviron/mediamtx/releases/download/v${MEDIAMTX_VERSION}/mediamtx_v${MEDIAMTX_VERSION}_darwin_amd64.tar.gz" \
  "$SRC/mediamtx-amd64.tar.gz" \
  "$MEDIAMTX_DARWIN_AMD64_SHA256"
download \
  "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" \
  "$SRC/ffmpeg.tar.xz" \
  "$FFMPEG_SHA256"
download \
  "https://downloads.xiph.org/releases/opus/opus-${OPUS_VERSION}.tar.gz" \
  "$SRC/opus.tar.gz" \
  "$OPUS_SHA256"

rm -rf "$SRC/mediamtx-arm64" "$SRC/mediamtx-amd64"
mkdir -p "$SRC/mediamtx-arm64" "$SRC/mediamtx-amd64"
tar -xzf "$SRC/mediamtx-arm64.tar.gz" -C "$SRC/mediamtx-arm64"
tar -xzf "$SRC/mediamtx-amd64.tar.gz" -C "$SRC/mediamtx-amd64"
cmp "$SRC/mediamtx-arm64/LICENSE" "$ROOT/Sources/PublicEarFi/Resources/Licenses/MediaMTX-LICENSE"

python3 - "$SRC/mediamtx-arm64/mediamtx.yml" "$ROOT/scripts/ffmpeg-configure-flags.txt" << 'PY'
import pathlib, sys
sample = pathlib.Path(sys.argv[1]).read_text()
required = [
    "logLevel", "api", "apiAddress", "rtsp", "rtspAddress", "rtspTransports",
    "rtmp", "hls", "srt", "moq", "webrtc", "webrtcAddress",
    "webrtcLocalUDPAddress", "webrtcLocalTCPAddress", "webrtcIPsFromInterfaces",
    "webrtcAdditionalHosts", "paths", "source", "maxReaders",
]
missing = []
for key in required:
    if f"\n{key}:" not in "\n" + sample and f"\n  {key}:" not in "\n" + sample:
        missing.append(key)
if missing:
    raise SystemExit("Pinned MediaMTX sample is missing keys: " + ", ".join(missing))
print("MediaMTX sample contains every key this app writes")
PY

lipo -create "$SRC/mediamtx-arm64/mediamtx" "$SRC/mediamtx-amd64/mediamtx" -output "$OUT/mediamtx"
chmod +x "$OUT/mediamtx"

build_opus() {
  local arch="$1" host="$2" prefix="$3"
  rm -rf "$SRC/opus-$arch"
  mkdir -p "$SRC/opus-$arch"
  tar -xzf "$SRC/opus.tar.gz" -C "$SRC/opus-$arch" --strip-components=1
  cmp "$SRC/opus-$arch/COPYING" "$ROOT/Sources/PublicEarFi/Resources/Licenses/opus-COPYING"
  pushd "$SRC/opus-$arch" >/dev/null
  # CC carries the architecture so a native Apple silicon runner can
  # produce the x86_64 static library without a separate toolchain.
  CC="clang -arch $arch" CFLAGS="-O2" LDFLAGS="-arch $arch" ./configure \
    --host="$host" \
    --disable-shared \
    --enable-static \
    --disable-extra-programs \
    --prefix="$prefix"
  make -j"$JOBS"
  make install
  popd >/dev/null
  rm -rf "$SRC/opus-$arch"
}

build_ffmpeg() {
  local arch="$1" ffmpeg_arch="$2" opus_prefix="$3" dest="$4"
  rm -rf "$SRC/ffmpeg"
  mkdir -p "$SRC/ffmpeg"
  tar -xJf "$SRC/ffmpeg.tar.xz" -C "$SRC/ffmpeg" --strip-components=1
  cmp "$SRC/ffmpeg/COPYING.LGPLv2.1" "$ROOT/Sources/PublicEarFi/Resources/Licenses/FFmpeg-COPYING.LGPLv2.1"
  pushd "$SRC/ffmpeg" >/dev/null
  # shellcheck disable=SC2046
  PKG_CONFIG_PATH="$opus_prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
    ./configure \
      --prefix="$SRC/ffmpeg-prefix-$arch" \
      --arch="$ffmpeg_arch" \
      --cc="clang -arch $arch" \
      --extra-cflags="-arch $arch -I$opus_prefix/include" \
      --extra-ldflags="-arch $arch -L$opus_prefix/lib" \
      $(grep -v '^[[:space:]]*#' "$ROOT/scripts/ffmpeg-configure-flags.txt" | tr '\n' ' ')
  make -j"$JOBS"
  cp ffmpeg "$dest"
  python3 - "$dest" << 'PY'
import pathlib, sys
text = pathlib.Path("config.h").read_text() + "\n" + pathlib.Path("config_components.h").read_text()
needed = {
    "CONFIG_GPL": "0",
    "CONFIG_NONFREE": "0",
    "CONFIG_LIBOPUS": "1",
    "CONFIG_AVFOUNDATION": "1",
    "CONFIG_LIBOPUS_ENCODER": "1",
    "CONFIG_AVFOUNDATION_INDEV": "1",
    "CONFIG_RTSP_MUXER": "1",
    "CONFIG_RTP_MUXER": "1",
    "CONFIG_PAN_FILTER": "1",
    "CONFIG_ARESAMPLE_FILTER": "1",
    "CONFIG_AFORMAT_FILTER": "1",
    "CONFIG_FILE_PROTOCOL": "1",
    "CONFIG_PIPE_PROTOCOL": "1",
    "CONFIG_TCP_PROTOCOL": "1",
    "CONFIG_UDP_PROTOCOL": "1",
    "CONFIG_RTP_PROTOCOL": "1",
    "CONFIG_HTTP_PROTOCOL": "1",
    "CONFIG_PCM_F32LE_DECODER": "1",
    "CONFIG_PCM_F32BE_DECODER": "1",
    "CONFIG_PCM_F64LE_DECODER": "1",
    "CONFIG_PCM_F64BE_DECODER": "1",
    "CONFIG_PCM_S16LE_DECODER": "1",
    "CONFIG_PCM_S16BE_DECODER": "1",
    "CONFIG_PCM_S24LE_DECODER": "1",
    "CONFIG_PCM_S24BE_DECODER": "1",
    "CONFIG_PCM_S32LE_DECODER": "1",
    "CONFIG_PCM_S32BE_DECODER": "1",
    "CONFIG_PCM_F32LE_DEMUXER": "1",
}
missing = [f"#define {key} {value}" for key, value in needed.items() if f"#define {key} {value}" not in text]
if missing:
    raise SystemExit(sys.argv[1] + " is missing " + ", ".join(missing))
print("ffmpeg config matches the LGPL avfoundation + libopus build")
PY
  if can_execute "$dest"; then
    "$dest" -version > "$OUT/ffmpeg-$arch-version.txt"
  else
    echo "Not executing $dest (its architecture cannot run here). config.h was checked."
    grep 'FFMPEG_CONFIGURATION' config.h > "$OUT/ffmpeg-$arch-version.txt" || true
  fi
  popd >/dev/null
  rm -rf "$SRC/ffmpeg"
}

can_execute() {
  local binary="$1"
  local info machine
  info="$(lipo -info "$binary")"
  machine="$(uname -m)"
  if [[ "$machine" == "arm64" && "$info" == *"architecture: x86_64"* && "$info" != *"arm64"* ]]; then
    arch -x86_64 /usr/bin/true >/dev/null 2>&1
    return
  fi
  if [[ "$machine" == "x86_64" && "$info" == *"architecture: arm64"* && "$info" != *"x86_64"* ]]; then
    return 1
  fi
  return 0
}

run_binary() {
  local binary="$1"
  shift
  local info
  info="$(lipo -info "$binary")"
  if [[ "$info" == *"architecture: x86_64"* && "$info" != *"arm64"* ]]; then
    arch -x86_64 "$binary" "$@"
  else
    "$binary" "$@"
  fi
}

assert_lgpl() {
  local binary="$1"
  if otool -L "$binary" | grep -i 'libopus' >/dev/null; then
    echo "ffmpeg is dynamically linked to libopus; the LGPL build must be static" >&2
    exit 1
  fi
  if ! can_execute "$binary"; then
    echo "Skipping the runtime licence check for $binary. config.h was already checked."
    return 0
  fi
  local version
  version="$(run_binary "$binary" -version)"
  printf '%s\n' "$version" | grep -q -- '--disable-gpl'
  printf '%s\n' "$version" | grep -q -- '--disable-nonfree'
  printf '%s\n' "$version" | grep -q -- '--enable-libopus'
  printf '%s\n' "$version" | grep -q -- '--enable-avfoundation'
  if printf '%s\n' "$version" | grep -E '(^|[ ])--enable-gpl([ ]|$)' >/dev/null; then
    echo "ffmpeg was built with --enable-gpl" >&2
    exit 1
  fi
  if printf '%s\n' "$version" | grep -E '(^|[ ])--enable-nonfree([ ]|$)' >/dev/null; then
    echo "ffmpeg was built with --enable-nonfree" >&2
    exit 1
  fi
}

echo "Building libopus and ffmpeg for arm64"
build_opus arm64 aarch64-apple-darwin "$SRC/opus-prefix-arm64"
build_ffmpeg arm64 arm64 "$SRC/opus-prefix-arm64" "$OUT/ffmpeg-arm64"
assert_lgpl "$OUT/ffmpeg-arm64"

if ! arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
  echo "Installing Rosetta so the x86_64 ffmpeg binary can be executed"
  softwareupdate --install-rosetta --agree-to-license \
    || sudo softwareupdate --install-rosetta --agree-to-license \
    || echo "Rosetta is unavailable. The x86_64 slice will be checked from config.h."
fi

echo "Building libopus and ffmpeg for x86_64"
build_opus x86_64 x86_64-apple-darwin "$SRC/opus-prefix-x86_64"
build_ffmpeg x86_64 x86_64 "$SRC/opus-prefix-x86_64" "$OUT/ffmpeg-x86_64"
assert_lgpl "$OUT/ffmpeg-x86_64"

lipo -create "$OUT/ffmpeg-arm64" "$OUT/ffmpeg-x86_64" -output "$OUT/ffmpeg"
chmod +x "$OUT/ffmpeg"
cp "$OUT/ffmpeg-arm64-version.txt" "$OUT/ffmpeg-version.txt"
printf '%s\n' "$STAMP" > "$OUT/STAMP"
echo "Helpers ready in $OUT"
lipo -info "$OUT/ffmpeg"
lipo -info "$OUT/mediamtx"
