#!/usr/bin/env python3
"""
Patch Wine 11.0's mf.dll (audio_renderer_stream_Flush) to check for a NULL
renderer->audio_client before calling IAudioClient_Reset().

Fixes an upstream Wine 11.0 null-pointer dereference (fixed in Wine 11.19:
"mf/sar: Check for null audio client before resetting during flush") that
crashes VRChat/Unity AVProVideo MediaFoundation players when flushing a stream.

Idempotent and safe: only patches if the exact expected Wine 11.0 x86-64 bytes
at RVA 0x19794 match; already-patched binaries and other Wine versions are
skipped cleanly.
"""

import os
import struct
import sys

RVA = 0x19794
EXPECTED_ORIG = bytes.fromhex("488b01ff506089c785c07925")
EXPECTED_TAIL = bytes.fromhex("4889f1")  # movq %rsi, %rcx (LeaveCriticalSection)
PATCH_LEN = 0x31

PATCH_BYTES = bytes.fromhex(
    "31c0"        # xorl %eax, %eax          (default hr = S_OK)
    "4885c9"      # testq %rcx, %rcx         (if audio_client != NULL)
    "7406"        # je +6 -> 0x1800197a1
    "488b01"      # movq (%rcx), %rax
    "ff5060"      # callq *0x60(%rax)        (IAudioClient_Reset)
    "89c7"        # movl %eax, %edi
    "eb20"        # jmp +0x20 -> 0x1800197c5 (LeaveCriticalSection)
) + (b"\x90" * (PATCH_LEN - 17))


def patch_file(path: str) -> str:
    if not os.path.isfile(path) or os.path.islink(path):
        return "skip (not a regular file)"
    with open(path, "rb") as f:
        data = bytearray(f.read())
    if len(data) < 0x200 or data[:2] != b"MZ":
        return "skip (not a PE binary)"
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if pe + 0x80 > len(data) or data[pe : pe + 4] != b"PE\x00\x00":
        return "skip (invalid PE header)"
    magic = struct.unpack_from("<H", data, pe + 24)[0]
    if magic != 0x20B:
        return "skip (not PE32+)"

    n_sec = struct.unpack_from("<H", data, pe + 6)[0]
    opt_sz = struct.unpack_from("<H", data, pe + 20)[0]
    img_base = struct.unpack_from("<Q", data, pe + 24 + 24)[0]
    if img_base != 0x180000000:
        return f"skip (unexpected ImageBase {hex(img_base)})"

    file_off = None
    for i in range(n_sec):
        sec_off = pe + 24 + opt_sz + i * 40
        vsize, vaddr, rsize, rptr = struct.unpack_from("<IIII", data, sec_off + 8)
        if vaddr <= RVA < vaddr + rsize:
            file_off = rptr + (RVA - vaddr)
            break
    if file_off is None or file_off + PATCH_LEN + 3 > len(data):
        return "skip (RVA out of range)"

    cur = bytes(data[file_off : file_off + PATCH_LEN])
    tail = bytes(data[file_off + PATCH_LEN : file_off + PATCH_LEN + 3])
    if cur == PATCH_BYTES and tail == EXPECTED_TAIL:
        return "already patched"
    if not cur.startswith(EXPECTED_ORIG) or tail != EXPECTED_TAIL:
        return "skip (different Wine build)"

    data[file_off : file_off + PATCH_LEN] = PATCH_BYTES

    csum_off = pe + 24 + 64
    old_csum = struct.unpack_from("<I", data, csum_off)[0]
    if old_csum != 0:
        struct.pack_into("<I", data, csum_off, 0)
        csum = 0
        padded = data + (b"\x00" if len(data) % 2 else b"")
        for i in range(0, len(padded), 2):
            csum += struct.unpack_from("<H", padded, i)[0]
            csum = (csum & 0xFFFF) + (csum >> 16)
        csum = (csum & 0xFFFF) + (csum >> 16) + len(data)
        struct.pack_into("<I", data, csum_off, csum & 0xFFFFFFFF)

    tmp = path + ".mfpatch.tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, path)
    return "patched"


def main() -> int:
    targets = sys.argv[1:]
    if not targets:
        base = os.path.expanduser("~/Library/Application Support/com.zagrios.obelisk")
        targets = [
            os.path.join(base, "Voile/current/linux/wine/lib/wine/x86_64-windows/mf.dll")
        ]
        prefixes = os.path.join(base, "Prefixes")
        if os.path.isdir(prefixes):
            for entry in sorted(os.listdir(prefixes)):
                if entry.endswith("-windows-linux"):
                    cand = os.path.join(prefixes, entry, "prefix/drive_c/windows/system32/mf.dll")
                    if os.path.isfile(cand) and not os.path.islink(cand):
                        targets.append(cand)

    for t in targets:
        status = patch_file(t)
        print(f"mf.dll: {status} -> {t}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
