#!/bin/bash
# Install the Obelisk FX Linux engine binaries, media playback stack, clipboard sync, and stability fixes
# into Obelisk's Voile development runtime (Voile/current):
#   1. wsd            (MetalFX Spatial + 2x FrameGen + Mic Voice Isolation + native clipboard sync + Dock icon guard)
#   2. fexdarwin-run  (FEXCore push/pop/ret boundary fix #25 + LKD ptrace SIGSTOP race fix)
#   3. Neptune server (512 MiB resource upload cap + same-process D3D11 shared textures / IDXGIKeyedMutex)
#   4. Wine media + clipboard pack (Proton-GE FFmpeg 7.1 winedmo/MediaFoundation + mfplat format guard + wineobelisk.drv clipboard sync)
#
# Works either with a local wsd binary (`./install-metalfx-wsd.sh /path/to/wsd`) or by downloading
# the latest prebuilt arm64 release from https://github.com/SpecialOperations/voile-lkd/releases.
set -euo pipefail

OBELISK_ROOT="${OBELISK_ROOT:-$HOME/Library/Application Support/com.zagrios.obelisk}"
VOILE_ROOT="${OBELISK_VOILE_ROOT:-$OBELISK_ROOT/Voile}"
RELEASE_BASE="${METALFX_RELEASE_BASE:-https://github.com/SpecialOperations/voile-lkd/releases/latest/download}"
RELEASE_URL="${METALFX_WSD_URL:-$RELEASE_BASE/wsd-arm64}"
SHA_URL="${METALFX_WSD_SHA_URL:-$RELEASE_BASE/wsd-arm64.sha256}"

if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
    echo "MetalFX wsd requires macOS on Apple silicon (arm64)." >&2
    exit 1
fi

if [ ! -d "$VOILE_ROOT" ]; then
    echo "Obelisk Voile directory not found at: $VOILE_ROOT" >&2
    echo "Launch any Windows game once in Obelisk so Voile is installed, then run this script again." >&2
    exit 1
fi

# Find the newest installed Voile release folder (excluding 'current' and hidden dirs).
latest_release=""
for candidate in "$VOILE_ROOT"/v*; do
    [ -d "$candidate/linux/engine" ] && [ -x "$candidate/linux/engine/wsd" ] || continue
    latest_release="$candidate"
done

if [ ! -d "$VOILE_ROOT/current/linux/engine" ] && [ -z "$latest_release" ]; then
    echo "No installed Voile Linux engine runtime found under: $VOILE_ROOT" >&2
    echo "Launch a Linux-engine game once in Obelisk so Voile is downloaded, then re-run this script." >&2
    exit 1
fi

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/install-metalfx-wsd.XXXXXXXX")
trap 'rm -rf "$tmpdir"' EXIT

download_verified() {
    local url="$1"
    local sha_url="$2"
    local dst="$3"
    /usr/bin/curl -fsSL "$url" -o "$dst"
    if /usr/bin/curl -fsSL "$sha_url" -o "${dst}.sha256" 2>/dev/null; then
        local expected actual
        expected=$(awk '{print $1}' "${dst}.sha256")
        actual=$(/usr/bin/shasum -a 256 "$dst" | awk '{print $1}')
        if [ -n "$expected" ] && [ "$expected" != "$actual" ]; then
            echo "SHA-256 checksum mismatch for $(basename "$dst")! Expected $expected, got $actual." >&2
            return 1
        fi
        echo "  SHA-256 verified ($actual)."
    fi
}

install_macho() {
    local src="$1"
    local dst="$2"
    chmod 755 "$src"
    /usr/bin/xattr -d com.apple.quarantine "$src" 2>/dev/null || true
    /usr/bin/codesign --verify "$src"
    /bin/cp -f "$src" "${dst}.new"
    chmod 755 "${dst}.new"
    /bin/mv -f "${dst}.new" "$dst"
    /usr/bin/codesign --verify "$dst"
}

if [ ! -d "$VOILE_ROOT/current/linux/engine" ]; then
    echo "Cloning $(basename "$latest_release") -> Voile/current (APFS copy-on-write)..."
    /bin/cp -cRP "$latest_release" "$VOILE_ROOT/current"
fi

# 1. Install wsd (MetalFX Spatial + 2x FrameGen + Dock icon fix)
if [ "${1-}" != "" ]; then
    wsd_src="$1"
    if [ ! -f "$wsd_src" ]; then
        echo "File not found: $wsd_src" >&2
        exit 1
    fi
else
    echo "Downloading MetalFX wsd..."
    wsd_src="$tmpdir/wsd-arm64"
    download_verified "$RELEASE_URL" "$SHA_URL" "$wsd_src"
fi
install_macho "$wsd_src" "$VOILE_ROOT/current/linux/engine/wsd"
echo "Installed wsd -> $VOILE_ROOT/current/linux/engine/wsd"

# When invoked without a local-file override, also install the companion stability fixes.
if [ "${1-}" = "" ]; then
    # 2. Install patched fexdarwin-run (FEXCore #25 push/pop/ret fix + LKD ptrace SIGSTOP fix)
    if download_verified "$RELEASE_BASE/fexdarwin-run-arm64" "$RELEASE_BASE/fexdarwin-run-arm64.sha256" "$tmpdir/fexdarwin-run-arm64" 2>/dev/null; then
        install_macho "$tmpdir/fexdarwin-run-arm64" "$VOILE_ROOT/current/linux/engine/fexdarwin-run"
        echo "Installed fexdarwin-run -> $VOILE_ROOT/current/linux/engine/fexdarwin-run"
    fi

    # 3. Install patched Neptune server (512 MiB resource upload cap + same-process D3D11 shared textures / keyed mutex)
    neptune_sha=$(/usr/bin/python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("linux",{}).get("neptune",""))' "$VOILE_ROOT/current/runtime.json" 2>/dev/null || true)
    case "$neptune_sha" in
        265be8a*|be783d9*)
            if download_verified "$RELEASE_BASE/virgl_render_server-arm64" "$RELEASE_BASE/virgl_render_server-arm64.sha256" "$tmpdir/virgl_render_server-arm64" 2>/dev/null && \
               download_verified "$RELEASE_BASE/libvirglrenderer.1.dylib-arm64" "$RELEASE_BASE/libvirglrenderer.1.dylib-arm64.sha256" "$tmpdir/libvirglrenderer.1.dylib-arm64" 2>/dev/null; then
                install_macho "$tmpdir/virgl_render_server-arm64" "$VOILE_ROOT/current/linux/graphics/libexec/virgl_render_server"
                install_macho "$tmpdir/libvirglrenderer.1.dylib-arm64" "$VOILE_ROOT/current/linux/graphics/lib/libvirglrenderer.1.dylib"
                echo "Installed Neptune server (512 MiB cap + shared textures) -> $VOILE_ROOT/current/linux/graphics/"
            fi
            ;;
        *)
            echo "Skipping Neptune server (runtime Neptune commit '$neptune_sha' differs)."
            ;;
    esac

    # 4. Install Wine Proton-GE FFmpeg 7.1 media playback DLLs + wineobelisk.drv native clipboard sync
    wine_dir="$VOILE_ROOT/current/linux/wine"
    if [ -d "$wine_dir/lib/wine/x86_64-windows" ] && [ -e "$VOILE_ROOT/current/linux/root/usr/lib/x86_64-linux-gnu/libavcodec.so.61" ]; then
        echo "Downloading Wine media playback & clipboard sync pack..."
        if download_verified "$RELEASE_BASE/wine-media-clipboard-x86_64.tar.gz" "$RELEASE_BASE/wine-media-clipboard-x86_64.tar.gz.sha256" "$tmpdir/wine-media-clipboard-x86_64.tar.gz" 2>/dev/null; then
            mkdir -p "$tmpdir/wine-pack"
            /usr/bin/tar -xzf "$tmpdir/wine-media-clipboard-x86_64.tar.gz" -C "$tmpdir/wine-pack"
            /usr/bin/xattr -cr "$tmpdir/wine-pack" 2>/dev/null || true
            /usr/bin/ditto "$tmpdir/wine-pack" "$wine_dir"
            # Bump wine.inf mtime so Wine automatically refreshes existing prefixes (wineboot -u) on next launch.
            /usr/bin/touch "$wine_dir/share/wine/wine.inf"
            # Also sync updated DLLs directly into existing Linux prefixes so they take effect immediately.
            for pfx in "$OBELISK_ROOT"/Prefixes/*-linux/prefix; do
                [ -d "$pfx/drive_c/windows/system32" ] || continue
                for dll in "$tmpdir/wine-pack/lib/wine/x86_64-windows"/*; do
                    [ -f "$dll" ] && /bin/cp -f "$dll" "$pfx/drive_c/windows/system32/$(basename "$dll")"
                done
                if [ -d "$pfx/drive_c/windows/syswow64" ]; then
                    for dll in "$tmpdir/wine-pack/lib/wine/i386-windows"/*; do
                        [ -f "$dll" ] && /bin/cp -f "$dll" "$pfx/drive_c/windows/syswow64/$(basename "$dll")"
                    done
                fi
            done
            echo "Installed Wine media playback (winedmo/FFmpeg) & clipboard sync -> $wine_dir"
        fi
    else
        echo "Skipping Wine media/clipboard pack (compatible Voile Wine/FFmpeg 7.1 runtime not found)."
    fi
fi

echo ""
echo "Done! Active runtime updated at:"
echo "  $VOILE_ROOT/current"
echo ""
echo "If you use Obelisk FX (SpecialOperations/Obelisk), toggle MetalFX Spatial, MetalFX Frame Generation,"
echo "and Mic Voice Isolation directly in each game's Launch Settings."
echo ""
echo "If you use stock Obelisk, you can also enable them per game via defaults:"
echo "  defaults write com.zagrios.obelisk.game.<GameName> WsdMetalFXSpatial -bool YES"
echo "  defaults write com.zagrios.obelisk.game.<GameName> WsdMetalFXFrameGen -bool YES"
echo "  defaults write com.zagrios.obelisk.game.<GameName> WsdVoiceProcessing -bool YES"
echo ""
echo "To revert to the stock Voile runtime at any time:"
echo "  rm -rf \"$VOILE_ROOT/current\""
