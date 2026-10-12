#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
# Finder does not inherit the terminal's Homebrew paths.
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

CHECK_ONLY=0
case "${1:-}" in
    --check) CHECK_ONLY=1 ;;
    --help|-h)
        cat <<'HELP'
Usage: ./build_and_run.command [--check]

Builds, packages, signs, installs, and opens Amethyst on an iPhone or iPad.
--check validates the setup without building or installing.

Options via environment variables:
  DEVICE_UDID          Device UDID, identifier, or name.
  PROVISIONING_PROFILE .mobileprovision profile (defaults to the app profile).
  TEAM_ID              Apple team ID; read from the profile if omitted.
  SIGN_IDENTITY        SHA-1 or name of a certificate included in the profile.
  BUNDLE_ID            App identifier; defaults to the current bundle identifier.
  BUILD_VERSION        Build version; incremented automatically.
  BUILD_TAG            Build tag; incremented automatically.
  BOOTJDK              JDK 8 bin directory for building Java.
  LAUNCH_AFTER_INSTALL Set to 0 to install without opening the app (default: 1).
  START_STOPPED        Set to 1 to launch suspended and connect LLDB (default: 0).
HELP
        exit 0 ;;
    "") ;;
    *) printf 'Unknown argument: %s. Use --help.\n' "$1" >&2; exit 1 ;;
esac
if [[ $# -gt 1 ]]; then
    printf 'Usage: ./build_and_run.command [--check].\n' >&2
    exit 1
fi

trap 'status=$?; printf "Build process failed on line %s (exit code %s).\n" "$LINENO" "$status" >&2; exit "$status"' ERR
for tool in python3 cmake make security codesign xcrun; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'Required tool is missing: %s\n' "$tool" >&2
        exit 1
    fi
done

APP="$ROOT/artifacts/Payload/AngelAuraAmethyst.app"
PROFILE_SOURCE="${PROVISIONING_PROFILE:-$APP/embedded.mobileprovision}"
if [[ ! -f "$PROFILE_SOURCE" ]]; then
    printf 'Provisioning profile not found: %s. Set PROVISIONING_PROFILE to its path.\n' "$PROFILE_SOURCE" >&2
    exit 1
fi
if [[ ! -f Natives/build/CMakeCache.txt ]]; then
    printf 'Native build configuration not found in Natives/build. Set up the dependencies first, as described in IOS-INTEGRATION.md.\n' >&2
    exit 1
fi

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/amethyst-build.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
# Packaging replaces APP, including its embedded profile. Save it first.
cp "$PROFILE_SOURCE" "$TEMP_DIR/development.mobileprovision"
security cms -D -i "$TEMP_DIR/development.mobileprovision" -o "$TEMP_DIR/profile.plist"
security find-identity -v -p codesigning > "$TEMP_DIR/identities.txt"
xcrun devicectl --timeout 30 list devices --json-output "$TEMP_DIR/devices.json" >/dev/null

python3 - "$TEMP_DIR" "$APP/Info.plist" <<'PY'
import datetime
import fnmatch
import hashlib
import json
import os
import pathlib
import plistlib
import re
import sys

work = pathlib.Path(sys.argv[1])
profile = plistlib.loads((work / "profile.plist").read_bytes())
current_path = pathlib.Path(sys.argv[2])
current = plistlib.loads(current_path.read_bytes()) if current_path.exists() else {}

def fail(message):
    sys.exit(message)

teams = profile.get("TeamIdentifier", [])
team = os.environ.get("TEAM_ID") or (teams[0] if teams else "")
if not team or team not in teams:
    fail("TEAM_ID does not match the team in the provisioning profile.")
expiration = profile.get("ExpirationDate")
if not expiration or expiration <= datetime.datetime.utcnow():
    fail("The provisioning profile has expired; use a valid one.")
entitlements = dict(profile.get("Entitlements", {}))
if not entitlements.get("get-task-allow"):
    fail("A development profile with get-task-allow is required to run and debug.")

allowed_id = entitlements.get("application-identifier", "")
prefix, separator, profile_bundle = allowed_id.partition(".")
bundle_id = os.environ.get("BUNDLE_ID") or current.get("CFBundleIdentifier")
if not bundle_id:
    bundle_id = profile_bundle if "*" not in profile_bundle else "org.angelauramc.amethyst"
if not separator or not fnmatch.fnmatchcase(prefix + "." + bundle_id, allowed_id):
    fail(f"The profile does not allow BUNDLE_ID={bundle_id}. Use a profile compatible with the app.")

# Certificate names need not contain TeamIdentifier. Match the profile's DER
# certificates to identities with a private key available in the keychain.
certificates = {hashlib.sha1(cert).hexdigest().upper()
                for cert in profile.get("DeveloperCertificates", [])}
identities = re.findall(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"([^"]+)"',
                        (work / "identities.txt").read_text(), re.MULTILINE)
requested_identity = os.environ.get("SIGN_IDENTITY", "")
matches = [(sha.upper(), name) for sha, name in identities
           if sha.upper() in certificates
           and (not requested_identity or requested_identity.upper() == sha.upper()
                or requested_identity == name)]
if not matches:
    fail("No valid certificate with an available private key is included in the profile. "
         "Check the keychain, PROVISIONING_PROFILE, and SIGN_IDENTITY.")
identity = matches[0][0]

devices = json.loads((work / "devices.json").read_text())["result"]["devices"]
devices = [d for d in devices
           if d.get("hardwareProperties", {}).get("platform") == "iOS"
           and d.get("hardwareProperties", {}).get("deviceType", "").lower() in ("ipad", "iphone")
           and d.get("hardwareProperties", {}).get("reality") == "physical"]
requested_device = os.environ.get("DEVICE_UDID", "")
if requested_device:
    def identifiers(device):
        connection = device.get("connectionProperties", {})
        return [device["identifier"], device.get("hardwareProperties", {}).get("udid", ""),
                device.get("deviceProperties", {}).get("name", "")] + \
               connection.get("potentialHostnames", []) + connection.get("localHostnames", [])
    matches = [d for d in devices if requested_device.casefold() in
               [value.casefold() for value in identifiers(d)]]
else:
    connected = [d for d in devices
                 if d.get("connectionProperties", {}).get("tunnelState") == "connected"]
    wired = [d for d in connected
             if d.get("connectionProperties", {}).get("transportType") == "wired"]
    matches = wired or connected
if len(matches) != 1:
    available = ", ".join(f'{d.get("deviceProperties", {}).get("name", "iOS")} ({d["identifier"]})'
                          for d in (matches or devices)) or "none"
    fail(f"Could not select a single iPhone/iPad. Devices: {available}. "
         "Connect a device or set DEVICE_UDID.")
device = matches[0]
if device.get("deviceProperties", {}).get("developerModeStatus") != "enabled":
    fail("Enable Developer Mode on the device before installing.")
if device.get("hardwareProperties", {}).get("udid") not in profile.get("ProvisionedDevices", []):
    fail("The device is not included in the profile. Register it and renew the profile.")

def increment(value):
    match = re.fullmatch(r"(.*?)(\d+)", value)
    return match[1] + str(int(match[2]) + 1) if match else value + ".1"

config = dict(TEAM_ID=team, BUNDLE_ID=bundle_id, SIGN_IDENTITY=identity,
              DEVICE_UDID=device["identifier"],
              DEVICE_NAME=device.get("deviceProperties", {}).get("name", "iOS"),
              BUILD_VERSION=os.environ.get("BUILD_VERSION") or increment(current.get("CFBundleVersion", "1.0.0")),
              BUILD_TAG=os.environ.get("BUILD_TAG") or increment(current.get("MCOptIOSBuildTag", "mcopt-ios.0")))
entitlements["application-identifier"] = prefix + "." + bundle_id
(work / "entitlements.plist").write_bytes(plistlib.dumps(entitlements))
(work / "config.plist").write_bytes(plistlib.dumps(config))
PY

TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print :TEAM_ID' "$TEMP_DIR/config.plist")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :BUNDLE_ID' "$TEMP_DIR/config.plist")"
SIGN_IDENTITY="$(/usr/libexec/PlistBuddy -c 'Print :SIGN_IDENTITY' "$TEMP_DIR/config.plist")"
DEVICE_UDID="$(/usr/libexec/PlistBuddy -c 'Print :DEVICE_UDID' "$TEMP_DIR/config.plist")"
DEVICE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :DEVICE_NAME' "$TEMP_DIR/config.plist")"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :BUILD_VERSION' "$TEMP_DIR/config.plist")"
BUILD_TAG="$(/usr/libexec/PlistBuddy -c 'Print :BUILD_TAG' "$TEMP_DIR/config.plist")"

if [[ -z "${BOOTJDK:-}" ]]; then
    if [[ -x "$ROOT/depends/jdk8u504-b01/Contents/Home/bin/javac" ]]; then
        BOOTJDK="$ROOT/depends/jdk8u504-b01/Contents/Home/bin"
    else
        BOOTJDK="$(/usr/libexec/java_home -v 1.8)/bin"
    fi
fi
if [[ ! -x "$BOOTJDK/javac" || ! -x "$BOOTJDK/jar" ]]; then
    printf 'BOOTJDK must point to the bin directory of a JDK 8: %s\n' "$BOOTJDK" >&2
    exit 1
fi
if [[ "$("$BOOTJDK/javac" -version 2>&1)" != 'javac 1.8.'* ]]; then
    printf 'Java builds require JDK 8. Set BOOTJDK to its bin directory.\n' >&2
    exit 1
fi

printf 'Amethyst %s (%s) → %s\nTeam: %s · Bundle: %s\n' "$BUILD_VERSION" "$BUILD_TAG" "$DEVICE_NAME" "$TEAM_ID" "$BUNDLE_ID"
if [[ "$CHECK_ONLY" == "1" ]]; then
    printf 'Development setup is valid. Nothing was built or installed.\n'
    exit 0
fi

cmake --build Natives/build --target AngelAuraAmethyst awt_xawt AmethystAccountJNI
make -C JavaApp BOOTJDK="$BOOTJDK"
xcrun actool Natives/Assets.xcassets --compile Natives/resources \
    --platform iphoneos --minimum-deployment-target 14.0 \
    --app-icon AppIcon-Light --output-partial-info-plist /dev/null

python3 tools/mcopt/package-development.py \
    --bundle-id "$BUNDLE_ID" --build-version "$BUILD_VERSION" --build-tag "$BUILD_TAG"
python3 tools/mcopt/sign-development.py \
    --identity "$SIGN_IDENTITY" --profile "$TEMP_DIR/development.mobileprovision" \
    --entitlements "$TEMP_DIR/entitlements.plist"

xcrun devicectl device install app --device "$DEVICE_UDID" "$APP"
if [[ "${LAUNCH_AFTER_INSTALL:-1}" != "0" ]]; then
    LAUNCH_OPTIONS=(--terminate-existing)
    if [[ "${START_STOPPED:-0}" == "1" ]]; then
        LAUNCH_OPTIONS+=(--start-stopped)
    fi
    xcrun devicectl device process launch --device "$DEVICE_UDID" "${LAUNCH_OPTIONS[@]}" "$BUNDLE_ID"
    if [[ "${START_STOPPED:-0}" == "1" ]]; then
        printf 'Amethyst is waiting for LLDB. Import tools/mcopt/lldb_jit26.py, run amethyst-jit-enable, then continue.\n'
    else
        printf 'Amethyst is open. For Minecraft, connect LLDB and enable JIT; keep the debugger connected.\n'
    fi
else
    printf 'Amethyst is installed; launch was skipped.\n'
fi
