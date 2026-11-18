#!/usr/bin/env bash
# Packages a Flutter Linux Release bundle into a verified RunMyAI AppImage.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

ARCH_NAME=""
OUT_DIR="$REPO_DIR/dist"
APPIMAGETOOL_BIN="${APPIMAGETOOL:-}"
SKIP_SMOKE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --arch) ARCH_NAME="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --appimagetool) APPIMAGETOOL_BIN="$2"; shift 2 ;;
    --skip-smoke) SKIP_SMOKE=1; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$ARCH_NAME" ]; then
  case "$(uname -m)" in
    x86_64|amd64) ARCH_NAME="x64" ;;
    aarch64|arm64) ARCH_NAME="arm64" ;;
    *) echo "Unsupported host architecture: $(uname -m)" >&2; exit 2 ;;
  esac
fi

case "$ARCH_NAME" in
  x64) APPIMAGE_ARCH="x86_64" ;;
  arm64) APPIMAGE_ARCH="aarch64" ;;
  *) echo "Unsupported --arch '$ARCH_NAME' (expected x64 or arm64)" >&2; exit 2 ;;
esac

BUNDLE="$REPO_DIR/build/linux/$ARCH_NAME/release/bundle"
if [ ! -x "$BUNDLE/runmyai" ]; then
  echo "Missing Linux release bundle at: $BUNDLE" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rma-appimage-XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "=== Bundle architecture & shared libraries ($ARCH_NAME) ==="
file "$BUNDLE/runmyai"
ldd "$BUNDLE/runmyai" || true
for lib in "$BUNDLE"/lib/*.so*; do
  [ -e "$lib" ] || continue
  file "$lib"
  ldd "$lib" || true
done

APPDIR="$WORK_DIR/RunMyAI.AppDir"
mkdir -p "$APPDIR/usr/bin"
cp -a "$BUNDLE"/. "$APPDIR/usr/bin/"

cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/usr/bin/runmyai" "$@"
EOF
chmod 755 "$APPDIR/AppRun"

cat > "$APPDIR/com.runmyai.runmyai.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Run My AI
Comment=Run AI models locally
Exec=runmyai
Icon=runmyai
Categories=Utility;
Terminal=false
EOF

cp -f "$REPO_DIR/assets/app-icon/app-icon-256.png" "$APPDIR/runmyai.png"
ln -sf "runmyai.png" "$APPDIR/.DirIcon"

if [ -z "$APPIMAGETOOL_BIN" ]; then
  if command -v appimagetool >/dev/null 2>&1; then
    APPIMAGETOOL_BIN="$(command -v appimagetool)"
  else
    APPIMAGETOOL_BIN="$WORK_DIR/appimagetool-${APPIMAGE_ARCH}.AppImage"
    curl -fsSL -o "$APPIMAGETOOL_BIN" \
      "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-${APPIMAGE_ARCH}.AppImage"
    chmod 755 "$APPIMAGETOOL_BIN"
  fi
fi

mkdir -p "$OUT_DIR"
OUT_APPIMAGE="$OUT_DIR/RunMyAI-linux-${ARCH_NAME}.AppImage"
export ARCH="$APPIMAGE_ARCH"
export APPIMAGE_EXTRACT_AND_RUN=1
"$APPIMAGETOOL_BIN" --no-appstream "$APPDIR" "$OUT_APPIMAGE"
chmod 755 "$OUT_APPIMAGE"
file "$OUT_APPIMAGE"
ls -lh "$OUT_APPIMAGE"

OFFSET="$(python3 -c 'import pathlib, struct, sys
b = pathlib.Path(sys.argv[1]).read_bytes()
assert b[:4] == b"\x7fELF" and b[8:11] == b"AI\x02", f"Bad AppImage header: {b[:16]!r}"
e_shoff = struct.unpack_from("<Q", b, 40)[0]
shentsize, shnum = struct.unpack_from("<HH", b, 58)
elf_end = e_shoff + shentsize * shnum
off = b.find(b"hsqs", elf_end)
assert off >= elf_end, "Missing SquashFS superblock after ELF payload"
print(off)' "$OUT_APPIMAGE")"

if [ "$SKIP_SMOKE" -eq 0 ]; then
  echo "=== Smoke testing extracted AppImage under Xvfb ==="
  SMOKE_DIR="$WORK_DIR/smoke-extract"
  SMOKE_HOME="$WORK_DIR/smoke-home"
  OUT_ABS="$(realpath "$OUT_APPIMAGE")"
  mkdir -p "$SMOKE_HOME"
  unsquashfs -o "$OFFSET" -d "$SMOKE_DIR" "$OUT_ABS" >/dev/null
  set +e
  HOME="$SMOKE_HOME" APPIMAGE="$OUT_ABS" xvfb-run -a timeout 8 "$SMOKE_DIR/AppRun" >"$WORK_DIR/smoke.log" 2>&1
  RC=$?
  set -e
  echo "Smoke exit code=$RC"
  cat "$WORK_DIR/smoke.log" || true
  if [ "$RC" -ne 124 ] && [ "$RC" -ne 0 ]; then
    echo "AppImage exited unexpectedly with status $RC" >&2
    exit "$RC"
  fi
fi
