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
Uso: ./build_and_run.command [--check]

Compila, empaqueta, firma, instala y abre Amethyst en un iPhone o iPad.
--check comprueba la configuración sin compilar ni instalar.

Opciones mediante variables de entorno:
  DEVICE_UDID          UDID, identificador o nombre del dispositivo.
  PROVISIONING_PROFILE Perfil .mobileprovision (por defecto, el de la app).
  TEAM_ID              Equipo de Apple; se obtiene del perfil si se omite.
  SIGN_IDENTITY        SHA-1 o nombre de un certificado incluido en el perfil.
  BUNDLE_ID            Identificador de la app; conserva el del paquete actual.
  BUILD_VERSION        Versión de compilación; se incrementa automáticamente.
  BUILD_TAG            Etiqueta de compilación; se incrementa automáticamente.
  BOOTJDK              Directorio bin de un JDK 8 para compilar Java.
  DEPENDENCIES_DIR     Directorio con los runtimes iOS 8, 17, 21 y 25.
  RENDERER_LIB_DIR     Directorio con MobileGlues y SPIRV-Cross ya compilados.
  LAUNCH_AFTER_INSTALL 0 para instalar sin abrir la app (por defecto, 1).
  START_STOPPED        1 para abrir suspendida y conectar LLDB (por defecto, 0).

En un worktree se reutilizan las dependencias y el perfil del checkout
principal cuando no están presentes aquí. La app se compila en esta rama.
HELP
        exit 0 ;;
    "") ;;
    *) printf 'Argumento desconocido: %s. Usa --help.\n' "$1" >&2; exit 1 ;;
esac
if [[ $# -gt 1 ]]; then
    printf 'Usa ./build_and_run.command [--check].\n' >&2
    exit 1
fi

trap 'status=$?; printf "El flujo ha fallado en la línea %s (código %s).\n" "$LINENO" "$status" >&2; exit "$status"' ERR
for tool in python3 cmake make security codesign xcrun git; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'Falta una herramienta necesaria: %s\n' "$tool" >&2
        exit 1
    fi
done

APP="$ROOT/artifacts/Payload/AngelAuraAmethyst.app"
COMMON_DIR="$(git rev-parse --git-common-dir)"
PRIMARY_ROOT="$(cd "$COMMON_DIR/.." && pwd)"
PRIMARY_APP="$PRIMARY_ROOT/artifacts/Payload/AngelAuraAmethyst.app"
CURRENT_INFO="$APP/Info.plist"
[[ -f "$CURRENT_INFO" ]] || CURRENT_INFO="$PRIMARY_APP/Info.plist"
DEFAULT_PROFILE="$APP/embedded.mobileprovision"
[[ -f "$DEFAULT_PROFILE" ]] || DEFAULT_PROFILE="$PRIMARY_APP/embedded.mobileprovision"
PROFILE_SOURCE="${PROVISIONING_PROFILE:-$DEFAULT_PROFILE}"
DEFAULT_DEPENDENCIES="$ROOT/depends"
[[ -d "$DEFAULT_DEPENDENCIES" ]] || DEFAULT_DEPENDENCIES="$PRIMARY_ROOT/depends"
DEPENDENCIES_DIR="${DEPENDENCIES_DIR:-$DEFAULT_DEPENDENCIES}"
DEFAULT_RENDERER="$ROOT/Natives/build"
if [[ ! -f "$DEFAULT_RENDERER/libmobileglues.dylib" && -f "$PRIMARY_ROOT/Natives/build/libmobileglues.dylib" ]]; then
    DEFAULT_RENDERER="$PRIMARY_ROOT/Natives/build"
fi
RENDERER_LIB_DIR_OVERRIDE="${RENDERER_LIB_DIR:-}"
RENDERER_LIB_DIR="${RENDERER_LIB_DIR:-$DEFAULT_RENDERER}"
if [[ ! -f "$PROFILE_SOURCE" ]]; then
    printf 'No se encuentra el perfil: %s. Indícalo con PROVISIONING_PROFILE.\n' "$PROFILE_SOURCE" >&2
    exit 1
fi
for required in scripts/build/package-development.py scripts/build/sign-development.py \
    Natives/external/AFNetworking/AFNetworking/AFSecurityPolicy.m \
    Natives/external/DBNumberedSlider/Classes/DBNumberedSlider.m \
    Natives/external/fishhook/fishhook.c Natives/external/UnzipKit/UnzipKit.h; do
    if [[ ! -f "$required" ]]; then
        printf 'Falta una dependencia: %s. Inicializa los submódulos y prepara los headers de UnzipKit.\n' "$required" >&2
        exit 1
    fi
done
for version in 8 17 21 25; do
    if [[ ! -f "$DEPENDENCIES_DIR/java-$version-openjdk/release" ]]; then
        printf 'Falta el runtime iOS de Java %s en %s. Indica DEPENDENCIES_DIR.\n' "$version" "$DEPENDENCIES_DIR" >&2
        exit 1
    fi
done
if [[ ! -f "$RENDERER_LIB_DIR/libmobileglues.dylib" || ! -f "$RENDERER_LIB_DIR/libspirv-cross-c-shared.0.dylib" ]]; then
    if [[ -n "${RENDERER_LIB_DIR_OVERRIDE:-}" ]]; then
        printf 'Las bibliotecas del renderer no están completas.\n' >&2
        exit 1
    fi
    RENDERER_LIB_DIR="$ROOT/Natives/build"
    if [[ ! -f Natives/external/MobileGlues/src/main/cpp/CMakeLists.txt || ! -f Natives/external/MobileGlues/src/main/cpp/libraries/ios/libspirv-cross-c-shared.0.dylib ]]; then
        printf 'Falta MobileGlues. Inicializa sus submódulos recursivamente o indica RENDERER_LIB_DIR.\n' >&2
        exit 1
    fi
fi

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/amethyst-build.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
# Packaging replaces APP, including its embedded profile. Save it first.
cp "$PROFILE_SOURCE" "$TEMP_DIR/development.mobileprovision"
security cms -D -i "$TEMP_DIR/development.mobileprovision" -o "$TEMP_DIR/profile.plist"
security find-identity -v -p codesigning > "$TEMP_DIR/identities.txt"
xcrun devicectl --timeout 30 list devices --json-output "$TEMP_DIR/devices.json" >/dev/null

python3 - "$TEMP_DIR" "$CURRENT_INFO" <<'PY'
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
    fail("TEAM_ID no coincide con el equipo del perfil de aprovisionamiento.")
expiration = profile.get("ExpirationDate")
if not expiration or expiration <= datetime.datetime.utcnow():
    fail("El perfil de aprovisionamiento ha caducado; usa uno vigente.")
entitlements = dict(profile.get("Entitlements", {}))
if not entitlements.get("get-task-allow"):
    fail("Se necesita un perfil de desarrollo con get-task-allow para ejecutar y depurar.")

allowed_id = entitlements.get("application-identifier", "")
prefix, separator, profile_bundle = allowed_id.partition(".")
bundle_id = os.environ.get("BUNDLE_ID") or current.get("CFBundleIdentifier")
if not bundle_id:
    bundle_id = profile_bundle if "*" not in profile_bundle else "org.angelauramc.amethyst"
if not separator or not fnmatch.fnmatchcase(prefix + "." + bundle_id, allowed_id):
    fail(f"El perfil no permite BUNDLE_ID={bundle_id}. Usa un perfil compatible con la app.")

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
    fail("No hay un certificado válido con clave privada que esté incluido en el perfil. "
         "Comprueba el llavero, PROVISIONING_PROFILE y SIGN_IDENTITY.")
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
    # CoreDevice opens tunnels on demand, including for attached USB devices.
    wired = [d for d in devices
             if d.get("connectionProperties", {}).get("transportType") == "wired"]
    paired = [d for d in devices
              if d.get("connectionProperties", {}).get("pairingState") == "paired"]
    matches = wired or connected or paired
if len(matches) != 1:
    available = ", ".join(f'{d.get("deviceProperties", {}).get("name", "iOS")} ({d["identifier"]})'
                          for d in (matches or devices)) or "ninguno"
    fail(f"No se puede elegir un único iPhone/iPad. Dispositivos: {available}. "
         "Conecta el dispositivo o indica DEVICE_UDID.")
device = matches[0]
if device.get("deviceProperties", {}).get("developerModeStatus") != "enabled":
    fail("Activa el modo de desarrollador en el dispositivo antes de instalar.")
if device.get("hardwareProperties", {}).get("udid") not in profile.get("ProvisionedDevices", []):
    fail("El dispositivo no está incluido en el perfil. Regístralo y renueva el perfil.")

def increment(value):
    match = re.fullmatch(r"(.*?)(\d+)", value)
    return match[1] + str(int(match[2]) + 1) if match else value + ".1"

config = dict(TEAM_ID=team, BUNDLE_ID=bundle_id, SIGN_IDENTITY=identity,
              DEVICE_UDID=device["identifier"],
              DEVICE_NAME=device.get("deviceProperties", {}).get("name", "iOS"),
              BUILD_VERSION=os.environ.get("BUILD_VERSION") or increment(current.get("CFBundleVersion", "1.0.0")),
              BUILD_TAG=os.environ.get("BUILD_TAG") or increment(current.get("AmethystBuildTag", "modrinth-ios.0")))
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
    if [[ -x "$DEPENDENCIES_DIR/jdk8u504-b01/Contents/Home/bin/javac" ]]; then
        BOOTJDK="$DEPENDENCIES_DIR/jdk8u504-b01/Contents/Home/bin"
    else
        BOOTJDK="$(/usr/libexec/java_home -v 1.8)/bin"
    fi
fi
if [[ ! -x "$BOOTJDK/javac" || ! -x "$BOOTJDK/jar" ]]; then
    printf 'BOOTJDK debe apuntar al directorio bin de un JDK 8: %s\n' "$BOOTJDK" >&2
    exit 1
fi
if [[ "$("$BOOTJDK/javac" -version 2>&1)" != 'javac 1.8.'* ]]; then
    printf 'La compilación Java necesita JDK 8. Indícalo con BOOTJDK.\n' >&2
    exit 1
fi

printf 'Amethyst %s (%s) → %s\nEquipo: %s · Bundle: %s\n' "$BUILD_VERSION" "$BUILD_TAG" "$DEVICE_NAME" "$TEAM_ID" "$BUNDLE_ID"
printf 'Runtimes: %s\nRenderer: %s\n' "$DEPENDENCIES_DIR" "$RENDERER_LIB_DIR"
if [[ "$CHECK_ONLY" == "1" ]]; then
    printf 'Configuración de desarrollo válida. No se ha compilado ni instalado.\n'
    exit 0
fi

SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
CMAKE_OPTIONS=(-DCMAKE_BUILD_TYPE=Debug -DCMAKE_CROSSCOMPILING=true
    -DCMAKE_SYSTEM_NAME=Darwin -DCMAKE_SYSTEM_PROCESSOR=aarch64
    "-DCMAKE_OSX_SYSROOT=$SDK_PATH" -DCMAKE_OSX_ARCHITECTURES=arm64
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 '-DCMAKE_C_FLAGS=-arch arm64')
cmake -S Natives -B Natives/build "${CMAKE_OPTIONS[@]}" \
    "-DCONFIG_BRANCH=$(git branch --show-current)" \
    "-DCONFIG_COMMIT=$(git rev-parse --short HEAD)" -DCONFIG_RELEASE=0
cmake --build Natives/build --target AngelAuraAmethyst awt_xawt AmethystAccountJNI tinygl4angle
if [[ ! -f "$RENDERER_LIB_DIR/libmobileglues.dylib" || ! -f "$RENDERER_LIB_DIR/libspirv-cross-c-shared.0.dylib" ]]; then
    cmake -S Natives/external/MobileGlues/src/main/cpp -B Natives/build/mobileglues \
        "${CMAKE_OPTIONS[@]}" -DMACOS=1
    cmake --build Natives/build/mobileglues --target mobileglues
    cp Natives/build/mobileglues/libmobileglues.dylib "$RENDERER_LIB_DIR/"
    cp Natives/external/MobileGlues/src/main/cpp/libraries/ios/libspirv-cross-c-shared.0.dylib "$RENDERER_LIB_DIR/"
fi
make -C JavaApp BOOTJDK="$BOOTJDK"
mkdir -p Natives/build/assets
xcrun actool Natives/Assets.xcassets --compile Natives/build/assets \
    --platform iphoneos --minimum-deployment-target 14.0 \
    --app-icon AppIcon-Light --output-partial-info-plist /dev/null

python3 scripts/build/package-development.py \
    --bundle-id "$BUNDLE_ID" --build-version "$BUILD_VERSION" --build-tag "$BUILD_TAG" \
    --runtime-dir "$DEPENDENCIES_DIR" --renderer-dir "$RENDERER_LIB_DIR"
python3 scripts/build/sign-development.py \
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
        printf 'Amethyst está suspendida. Conecta LLDB para continuar y activar JIT.\n'
    else
        printf 'Amethyst está abierta. Para Minecraft, conecta LLDB y activa JIT; mantén el depurador conectado.\n'
    fi
else
    printf 'Amethyst instalada; se ha omitido el lanzamiento.\n'
fi
