#!/usr/bin/env python3
"""Patch a decrypted YNAB Classic 3.4.3 IPA so it runs full screen on modern iPhones and iPads.

Usage:
    python3 patch.py [YNAB.ipa] [-o OUTPUT.ipa] [--bundle-id ID] [--name NAME] [--version VERSION]

Without an IPA argument, it patches the .ipa placed next to this script.

Needs only Python 3 (Mac, Windows or Linux). The result is unsigned: install it with your usual
sideloading tool (AltStore, SideStore, Sideloadly, ...), which signs it.

What it changes:
  - Info.plist: adds a launch screen (which ends the letterboxed compatibility mode), raises the
    minimum iOS version to 14, and gives the app its own bundle ID and version;
  - the app binary: records SDK 12.4 instead of 10.3, and loads YNABModern.dylib;
  - adds YNABModern.dylib (the layout fixes and the "Default cleared status" setting) and the
    launch screen images.
"""
import argparse
import hashlib
import os
import plistlib
import struct
import sys
import zipfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))

DYLIB_NAME = "YNABModern.dylib"
DEFAULT_BUNDLE_ID = "com.ynab.ynab-modernized"
DEFAULT_VERSION = "3.5.0-modernized"
DEFAULT_NAME = "YNAB Classic"

# iOS uses the SDK recorded in the binary to choose a compatibility layout. 12.4 is the newest one
# the app survives: from 13 on, UIKit throws on the UISearchDisplayController its lists use.
MIN_OS = (14, 0, 0)
SDK = (12, 4, 0)

# Launch screen: the gradient behind the app's splash art, at the sizes that cover the largest
# current screens (iOS shows the image at its natural size, centred).
GRADIENT_TOP = (0x23, 0xAF, 0xC1)
GRADIENT_BOTTOM = (0x06, 0x80, 0x9E)
LAUNCH_IMAGES = {
    "LaunchScreen@3x.png": (1320, 2868),       # iPhone, up to 440x956pt
    "LaunchScreen@2x~ipad.png": (2064, 2752),  # iPad, up to 1032x1376pt
}

# Files from the App Store build that would get in the way of re-signing.
DROPPED = {"_CodeSignature", "embedded.mobileprovision", "Entitlements.plist", ".DS_Store"}

# The app the patch was written and tested against: YNAB 3.4.3 (build 263). The patch hooks its
# internal classes by name, so other versions would crash or misbehave.
EXPECTED_BUILD = "263"
EXPECTED_VERSION = "3.4.3"
# SHA-256 of the tested decrypted binary. Copies decrypted with other tools can differ slightly and
# still work, so a mismatch is only a note.
KNOWN_BINARY_SHA256 = "23f5d80af1b7be422f4086c9844a21cf3766a6bf6edb705748fb438b5c9d164e"

MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64 = 0x19
LC_LOAD_DYLIB = 0xC
LC_VERSION_MIN_IPHONEOS = 0x25
LC_BUILD_VERSION = 0x32
LC_ENCRYPTION_INFO_64 = 0x2C
PLATFORM_IOS = 2

def fail(message):
    sys.exit(f"Error: {message}")

def encode_version(v):
    return (v[0] << 16) | (v[1] << 8) | v[2]

def patch_binary(data):
    """Return the app binary with LC_BUILD_VERSION (min iOS 14, SDK 12.4) and an LC_LOAD_DYLIB for
    YNABModern.dylib, both fitted into the padding between the load commands and the first section."""
    if len(data) < 32 or struct.unpack_from("<I", data, 0)[0] != MH_MAGIC_64:
        fail("the app binary isn't a 64-bit iOS binary (is this the right IPA?)")
    ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
    header = 32

    build_version = struct.pack("<IIIIII", LC_BUILD_VERSION, 24, PLATFORM_IOS,
                                encode_version(MIN_OS), encode_version(SDK), 0)
    dylib_path = f"@executable_path/{DYLIB_NAME}".encode() + b"\0"
    dylib_size = (24 + len(dylib_path) + 7) & ~7
    load_dylib = (struct.pack("<IIIIII", LC_LOAD_DYLIB, dylib_size, 24, 2, 0x10000, 0x10000)
                  + dylib_path).ljust(dylib_size, b"\0")

    commands = []
    first_section = len(data)
    has_dylib = has_version = False
    off = header
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        raw = data[off:off + cmdsize]
        if cmd == LC_SEGMENT_64:
            nsects = struct.unpack_from("<I", data, off + 64)[0]
            for i in range(nsects):
                sect_offset = struct.unpack_from("<I", data, off + 72 + i * 80 + 48)[0]
                if sect_offset:
                    first_section = min(first_section, sect_offset)
        if cmd in (LC_VERSION_MIN_IPHONEOS, LC_BUILD_VERSION):
            raw, has_version = build_version, True
        elif cmd == LC_LOAD_DYLIB and dylib_path in raw:
            has_dylib = True
        commands.append(raw)
        off += cmdsize
    if not has_version:
        commands.append(build_version)
    if not has_dylib:
        commands.append(load_dylib)

    blob = b"".join(commands)
    if header + len(blob) > first_section:
        fail("not enough room in the app binary for the new load commands")
    out = bytearray(data)
    out[header:header + max(sizeofcmds, len(blob))] = blob.ljust(max(sizeofcmds, len(blob)), b"\0")
    struct.pack_into("<II", out, 16, len(commands), len(blob))
    return bytes(out)

def is_encrypted(data):
    """True if the binary's code is still FairPlay-encrypted (cryptid != 0)."""
    if len(data) < 32 or struct.unpack_from("<I", data, 0)[0] != MH_MAGIC_64:
        return False  # patch_binary reports this
    ncmds = struct.unpack_from("<I", data, 16)[0]
    off = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == LC_ENCRYPTION_INFO_64 and struct.unpack_from("<I", data, off + 16)[0] != 0:
            return True
        off += cmdsize
    return False

def check_input(info, binary, already_patched):
    """Stop on IPAs the patch can't work with; note copies that differ from the tested one."""
    build = str(info.get("CFBundleVersion", "?"))
    version = str(info.get("CFBundleShortVersionString", "?"))
    if build != EXPECTED_BUILD or (not already_patched and version != EXPECTED_VERSION):
        fail(f"this is YNAB {version} (build {build}). The patch only works with YNAB "
             f"{EXPECTED_VERSION} (build {EXPECTED_BUILD}).")
    if is_encrypted(binary):
        fail("this IPA is still encrypted (as downloaded from the App Store), so the patched app "
             "would crash at launch. You need a decrypted copy; see the FAQ in README.md.")
    if not already_patched and hashlib.sha256(binary).hexdigest() != KNOWN_BINARY_SHA256:
        print("Note: this copy of YNAB 3.4.3 differs from the one the patch was tested with "
              "(probably decrypted with a different tool). It will most likely work; if the app "
              "misbehaves, try another copy.")

def patch_info_plist(data, bundle_id, version, name):
    info = plistlib.loads(data)
    info.pop("UILaunchImages", None)
    info["UILaunchScreen"] = {"UIImageName": "LaunchScreen", "UIImageRespectsSafeAreaInsets": False}
    info["MinimumOSVersion"] = "%d.%d" % MIN_OS[:2]
    info["CFBundleIdentifier"] = bundle_id
    info["CFBundleShortVersionString"] = version
    info["CFBundleDisplayName"] = name
    return info, plistlib.dumps(info, fmt=plistlib.FMT_BINARY)

def gradient_png(width, height):
    """A vertical gradient as a PNG, using only the standard library."""
    rows = []
    for y in range(height):
        t = y / (height - 1)
        pixel = bytes(round(a + (b - a) * t) for a, b in zip(GRADIENT_TOP, GRADIENT_BOTTOM))
        rows.append(b"\0" + pixel * width)

    def chunk(kind, payload):
        return (struct.pack(">I", len(payload)) + kind + payload
                + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF))

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)  # 8-bit RGB
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b""))

def file_info(name, mode):
    info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
    info.external_attr = (0o100000 | mode) << 16
    info.compress_type = zipfile.ZIP_DEFLATED
    return info

def patch_ipa(src, dst, dylib, bundle_id, version, name):
    if not os.path.isfile(src):
        fail(f"can't find {src}")
    if not os.path.isfile(dylib):
        fail(f"{dylib} is missing (it should be next to patch.py)")
    try:
        zin = zipfile.ZipFile(src)
    except (OSError, zipfile.BadZipFile) as e:
        fail(f"can't open {src} as an IPA: {e}")

    with zin:
        apps = sorted({n.split("/")[1] for n in zin.namelist()
                       if n.startswith("Payload/") and n.split("/")[1].endswith(".app")})
        if len(apps) != 1:
            fail("couldn't find the app inside the IPA (expected one Payload/*.app)")
        app = f"Payload/{apps[0]}/"
        original_info = plistlib.loads(zin.read(app + "Info.plist"))
        executable = app + original_info.get("CFBundleExecutable", "")
        if executable not in zin.namelist():
            fail("couldn't find the app's binary inside the IPA")
        original_binary = zin.read(executable)
        check_input(original_info, original_binary, already_patched=app + DYLIB_NAME in zin.namelist())
        info, plist = patch_info_plist(zin.read(app + "Info.plist"), bundle_id, version, name)
        binary = patch_binary(original_binary)
        added = {app + DYLIB_NAME, *(app + n for n in LAUNCH_IMAGES)}

        tmp = dst + ".tmp"
        with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zout:
            for item in zin.infolist():
                n = item.filename
                # Only the app goes into the result (no iTunes metadata or artwork).
                if not n.startswith(app) or n in added:
                    continue
                if any(part in DROPPED for part in n[len(app):].split("/")):
                    continue
                if n == app + "Info.plist":
                    zout.writestr(item, plist)
                elif n == executable:
                    zout.writestr(item, binary)
                else:
                    zout.writestr(item, zin.read(item))
            with open(dylib, "rb") as f:
                zout.writestr(file_info(app + DYLIB_NAME, 0o755), f.read())
            for image, (w, h) in LAUNCH_IMAGES.items():
                zout.writestr(file_info(app + image, 0o644), gradient_png(w, h))
        os.replace(tmp, dst)


def find_ipa():
    """The decrypted IPA dropped next to this script (anything but a previous result)."""
    found = sorted(n for n in os.listdir(HERE)
                   if n.lower().endswith(".ipa") and not n.lower().endswith("-modernized.ipa"))
    if not found:
        fail(f"put your decrypted YNAB .ipa in {HERE}, or pass its path: python3 patch.py YNAB.ipa")
    if len(found) > 1:
        fail(f"found several .ipa files in {HERE} ({', '.join(found)}); keep one, or pass its path")
    return os.path.join(HERE, found[0])

def main():
    parser = argparse.ArgumentParser(description="Patch a decrypted YNAB 3.4.3 IPA to run full screen on modern iPhones.")
    parser.add_argument("ipa", nargs="?", help="the decrypted YNAB 3.4.3 .ipa (default: the .ipa next to this script)")
    parser.add_argument("-o", "--output", help="where to write the patched IPA (default: build/<input name>-modernized.ipa next to this script)")
    parser.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID, help=f"bundle ID (default: {DEFAULT_BUNDLE_ID}, so it installs alongside the original)")
    parser.add_argument("--name", default=DEFAULT_NAME, help=f"home-screen name (default: {DEFAULT_NAME})")
    parser.add_argument("--version", default=DEFAULT_VERSION, help=f"version (default: {DEFAULT_VERSION})")
    parser.add_argument("--dylib", default=os.path.join(HERE, DYLIB_NAME), help=argparse.SUPPRESS)
    args = parser.parse_args()

    src = os.path.abspath(os.path.expanduser(args.ipa.strip().strip("'\""))) if args.ipa else find_ipa()
    if args.output:
        dst = os.path.abspath(args.output)
    else:
        name = os.path.splitext(os.path.basename(src))[0] + "-modernized.ipa"
        dst = os.path.join(HERE, "build", name)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    patch_ipa(src, dst, args.dylib, args.bundle_id, args.version, args.name)
    print(f"Done: {dst}")
    print("Install it with your sideloading tool (AltStore, SideStore, Sideloadly, ...).")

if __name__ == "__main__":
    main()
