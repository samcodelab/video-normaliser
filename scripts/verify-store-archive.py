#!/usr/bin/env python3
"""Read-only checks of the current Store archive and prepared listing assets.

This verifies an archive, not an exported package or Apple's server validation.
"""
import pathlib
import plistlib
import re
import subprocess
import sys


def require(condition, message):
    if not condition:
        raise ValueError(message)


def command(*args):
    return subprocess.check_output(args, stderr=subprocess.PIPE)


def main():
    require(len(sys.argv) == 2, "Usage: python3 scripts/verify-store-archive.py PATH.xcarchive")
    root = pathlib.Path(__file__).resolve().parent.parent
    archive = pathlib.Path(sys.argv[1]).resolve()
    metadata = plistlib.loads((archive / "Info.plist").read_bytes())
    application_path = pathlib.Path(metadata["ApplicationProperties"]["ApplicationPath"])
    app = (archive / "Products" / application_path).resolve()
    require(app.is_relative_to(archive / "Products"), "Invalid archive application path")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    configuration = (root / "Configuration/Base.xcconfig").read_text()
    for key, setting in [("CFBundleShortVersionString", "MARKETING_VERSION"),
                         ("CFBundleVersion", "CURRENT_PROJECT_VERSION")]:
        expected = re.search(rf"^{setting}\s*=\s*(\S+)", configuration, re.M).group(1)
        require(info[key] == expected, f"Outdated archive: {key} is {info[key]}, current source is {expected}")
    require(info["CFBundleIdentifier"] == "com.broadframestudio.frankluma", "Unexpected bundle identifier")
    require(info["LSMinimumSystemVersion"] == "14.0", "Unexpected minimum macOS version")
    require(info["LSApplicationCategoryType"] == "public.app-category.video", "Missing Video category")
    require(info.get("ITSAppUsesNonExemptEncryption") is False, "Encryption declaration differs from listing")
    executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
    require(set(command("lipo", "-archs", str(executable)).decode().split()) == {"arm64", "x86_64"}, "Missing release architecture")
    command("codesign", "--verify", "--strict", str(app))
    signature = subprocess.run(["codesign", "--display", "--verbose=4", str(app)], capture_output=True, check=True).stderr.decode()
    require("TeamIdentifier=PLQG3PMFP8" in signature, "Wrong signing team")
    require("Authority=Apple Development:" in signature or "Authority=Apple Distribution:" in signature, "Not a Store/development archive signature")
    entitlements = plistlib.loads(command("codesign", "--display", "--entitlements", ":-", str(app)))
    for key in ["com.apple.security.app-sandbox", "com.apple.security.files.user-selected.read-write", "com.apple.security.files.bookmarks.app-scope"]:
        require(entitlements.get(key) is True, f"Missing entitlement: {key}")
    require(not entitlements.get("com.apple.security.get-task-allow"), "Debug entitlement in release archive")
    resources = app / "Contents/Resources"
    privacy = plistlib.loads((resources / "PrivacyInfo.xcprivacy").read_bytes())
    require(privacy == plistlib.loads((root / "Resources/PrivacyInfo.xcprivacy").read_bytes()), "Privacy manifest differs from reviewed source")
    require((resources / "FrankLuma Demo.mov").read_bytes() == (root / "Resources/FrankLuma Demo.mov").read_bytes(), "Original review demo missing or changed")
    require((resources / "Assets.car").is_file(), "Compiled artwork missing")
    for name in ["01-comparison", "02-scenes", "03-reference", "04-export"]:
        shot = root / "docs/app-store/screenshots" / (name + ".png")
        image = shot.read_bytes()
        require(image[:8] == b"\x89PNG\r\n\x1a\n", f"Invalid screenshot: {name}")
        require(int.from_bytes(image[16:20], "big") == 2560 and int.from_bytes(image[20:24], "big") == 1600, f"Wrong screenshot dimensions: {name}")
    print(f"PASS: {info['CFBundleShortVersionString']} ({info['CFBundleVersion']}) archive, signature, sandbox, privacy, demo and four screenshots")
    print(f"Archive: {archive}")
    print("Store package signing/export, account questionnaires and Apple processing remain separate checks.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError, plistlib.InvalidFileException) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr.decode(errors="replace").strip(), file=sys.stderr)
        sys.exit(1)
