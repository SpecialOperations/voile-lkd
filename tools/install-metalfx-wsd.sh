#!/bin/bash
# Install the MetalFX-enabled wsd window server into Obelisk's Voile development runtime (Voile/current).
# Works either with a local wsd binary (`./install-metalfx-wsd.sh /path/to/wsd`) or by downloading
# the latest prebuilt arm64 release from https://github.com/SpecialOperations/voile-lkd/releases.
set -euo pipefail

VOILE_ROOT="${OBELISK_VOILE_ROOT:-$HOME/Library/Application Support/com.zagrios.obelisk/Voile}"
RELEASE_URL="${METALFX_WSD_URL:-https://github.com/SpecialOperations/voile-lkd/releases/latest/download/wsd-arm64}"
SHA_URL="${METALFX_WSD_SHA_URL:-https://github.com/SpecialOperations/voile-lkd/releases/latest/download/wsd-arm64.sha256}"

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

if [ "${1-}" != "" ]; then
    wsd_src="$1"
    if [ ! -f "$wsd_src" ]; then
        echo "File not found: $wsd_src" >&2
        exit 1
    fi
else
    echo "Downloading MetalFX wsd from $RELEASE_URL ..."
    wsd_src="$tmpdir/wsd-arm64"
    /usr/bin/curl -fsSL "$RELEASE_URL" -o "$wsd_src"
    if /usr/bin/curl -fsSL "$SHA_URL" -o "$tmpdir/wsd-arm64.sha256" 2>/dev/null; then
        expected=$(awk '{print $1}' "$tmpdir/wsd-arm64.sha256")
        actual=$(/usr/bin/shasum -a 256 "$wsd_src" | awk '{print $1}')
        if [ -n "$expected" ] && [ "$expected" != "$actual" ]; then
            echo "SHA-256 checksum mismatch! Expected $expected, got $actual." >&2
            exit 1
        fi
        echo "SHA-256 verified ($actual)."
    fi
fi

chmod 755 "$wsd_src"
/usr/bin/xattr -d com.apple.quarantine "$wsd_src" 2>/dev/null || true
/usr/bin/codesign --verify "$wsd_src"

if [ ! -d "$VOILE_ROOT/current/linux/engine" ]; then
    echo "Cloning $(basename "$latest_release") -> Voile/current (APFS copy-on-write)..."
    /bin/cp -cRP "$latest_release" "$VOILE_ROOT/current"
fi

/bin/rm -f "$VOILE_ROOT/current/linux/engine/wsd"
/bin/cp "$wsd_src" "$VOILE_ROOT/current/linux/engine/wsd"
chmod 755 "$VOILE_ROOT/current/linux/engine/wsd"
/usr/bin/codesign --verify "$VOILE_ROOT/current/linux/engine/wsd"

echo ""
echo "Installed MetalFX-enabled wsd into:"
echo "  $VOILE_ROOT/current/linux/engine/wsd"
echo ""
echo "If you use the SpecialOperations/Obelisk fork, toggle MetalFX Spatial and MetalFX Frame Generation"
echo "directly in each game's Launch Settings."
echo ""
echo "If you use stock Obelisk, you can also enable them per game via defaults:"
echo "  defaults write com.zagrios.obelisk.game.<GameName> WsdMetalFXSpatial -bool YES"
echo "  defaults write com.zagrios.obelisk.game.<GameName> WsdMetalFXFrameGen -bool YES"
echo ""
echo "To revert to the stock Voile runtime at any time:"
echo "  rm -rf \"$VOILE_ROOT/current\""
