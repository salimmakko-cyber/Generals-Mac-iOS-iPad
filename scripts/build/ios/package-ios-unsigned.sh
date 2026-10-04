#!/bin/bash
# Package the iOS build of Zero Hour as an UNSIGNED .ipa that contains NO game assets.
#
# For machines without an Apple Developer team (e.g. a GitHub macOS runner). The .ipa
# is meant to be signed at install time by a sideloading tool (Sideloadly, AltStore, ...)
# using a free Apple ID, after you add your own game files to it.
#
# Same assembly as package-ios-zh.sh, except:
#   - the provisioning shell app is built with code signing disabled;
#   - binaries are only ad-hoc signed (the sideloading tool re-signs every one of them);
#   - GameData/ holds only the redistributable support files (Liberation fonts, dxvk.conf,
#     DefaultOptions.ini, ExtrasMenu.wnd). Copy your own game files (Steam install) into
#     Payload/GeneralsXZH.app/GameData/ before signing — or delete GameData/ entirely and
#     the engine loads assets from the app's Documents folder instead.
#
# Usage: GX_BUNDLE_ID=com.you.generalszh ./scripts/build/ios/package-ios-unsigned.sh
#   GX_BUNDLE_ID  bundle identifier (default: io.github.<owner>.generalszh on GitHub
#                 Actions, com.example.generalszh elsewhere)
#   GX_IPA_NAME   output file name (default: GeneralsZH-unsigned-noassets.ipa)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
BUILD_DIR="${PROJECT_ROOT}/build/ios-vulkan"
IOS_DIR="${PROJECT_ROOT}/ios"
DERIVED="${IOS_DIR}/build-unsigned"
OUT_DIR="${PROJECT_ROOT}/build/ios-package"
APP_NAME="GeneralsXZH"

DEFAULT_BUNDLE_ID="com.example.generalszh"
if [[ -n "${GITHUB_REPOSITORY_OWNER:-}" ]]; then
    # GitHub logins are [A-Za-z0-9-], all valid in a bundle identifier
    OWNER_ID="$(echo "${GITHUB_REPOSITORY_OWNER}" | tr '[:upper:]' '[:lower:]')"
    DEFAULT_BUNDLE_ID="io.github.${OWNER_ID}.generalszh"
fi
BUNDLE_ID="${GX_BUNDLE_ID:-${DEFAULT_BUNDLE_ID}}"
IPA_NAME="${GX_IPA_NAME:-GeneralsZH-unsigned-noassets.ipa}"

GAME_BIN="${BUILD_DIR}/GeneralsMD/GeneralsXZH.app/GeneralsXZH"
DXVK_BUILD="${BUILD_DIR}/_deps/dxvk-build-macos"
MVK_FRAMEWORK="${GX_MOLTENVK:-${HOME}/GeneralsX/MoltenVK/MoltenVK/MoltenVK/dynamic/MoltenVK.xcframework/ios-arm64/MoltenVK.framework}"
FONTS_SRC="${GX_FONTS:-${HOME}/GeneralsX/ios-staging/fonts}"
CONFIG_SRC="${GX_CONFIG:-${IOS_DIR}/config}"
EXTRAS_WND="${PROJECT_ROOT}/GeneralsZH/Data/Window/Menus/ExtrasMenu.wnd"

if [[ ! -f "${GAME_BIN}" ]]; then
    echo "ERROR: engine binary not found at ${GAME_BIN} — build the ios-vulkan preset first."
    exit 1
fi
if [[ ! -d "${MVK_FRAMEWORK}" ]]; then
    echo "ERROR: MoltenVK.framework not found at ${MVK_FRAMEWORK}"
    echo "  Run scripts/build/ios/fetch-moltenvk.sh (pinned version + checksum)."
    exit 1
fi
if [[ ! -f "${FONTS_SRC}/arial.ttf" ]]; then
    echo "ERROR: fonts not staged at ${FONTS_SRC} — the app would render no text."
    echo "  Run scripts/build/ios/stage-fonts.sh once."
    exit 1
fi
for cfg in dxvk.conf Options.ini; do
    if [[ ! -f "${CONFIG_SRC}/${cfg}" ]]; then
        echo "ERROR: ${CONFIG_SRC}/${cfg} missing (should ship with the repo in ios/config/)"
        exit 1
    fi
done

echo "==> Generating Xcode project (xcodegen)"
(cd "${IOS_DIR}" && xcodegen generate --quiet)

echo "==> Building unsigned shell app (bundle id ${BUNDLE_ID})"
xcodebuild -quiet -project "${IOS_DIR}/${APP_NAME}.xcodeproj" \
    -scheme "${APP_NAME}" -configuration Release \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "${DERIVED}" \
    PRODUCT_BUNDLE_IDENTIFIER="${BUNDLE_ID}" \
    DEVELOPMENT_TEAM="" CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    build

SHELL_APP="${DERIVED}/Build/Products/Release-iphoneos/${APP_NAME}.app"
if [[ ! -d "${SHELL_APP}" ]]; then
    echo "ERROR: shell app not produced at ${SHELL_APP}"
    exit 1
fi

echo "==> Assembling final app"
rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}/Payload"
cp -R "${SHELL_APP}" "${OUT_DIR}/Payload/"
APP="${OUT_DIR}/Payload/${APP_NAME}.app"

# Replace stub executable with the engine
cp "${GAME_BIN}" "${APP}/${APP_NAME}"

# Embed runtime dylibs
mkdir -p "${APP}/Frameworks"
for lib in \
    "${DXVK_BUILD}/src/d3d8/libdxvk_d3d8.0.dylib" \
    "${DXVK_BUILD}/src/d3d9/libdxvk_d3d9.0.dylib" \
    "${BUILD_DIR}/_deps/sdl3-build/libSDL3.0.dylib" \
    "${BUILD_DIR}/_deps/sdl3_image-build/libSDL3_image.0.dylib" \
    "${BUILD_DIR}/_deps/openal_soft-build/libopenal.1.24.2.dylib" \
    "${BUILD_DIR}/libgamespy.dylib"; do
    if [[ -f "${lib}" ]]; then
        cp "${lib}" "${APP}/Frameworks/"
        echo "    embedded $(basename "${lib}")"
    else
        case "$(basename "${lib}")" in
            libgamespy.dylib)
                echo "    (skip, optional: $(basename "${lib}"))" ;;
            *)
                echo "ERROR: required dylib not built: ${lib}"
                exit 1 ;;
        esac
    fi
done

# openal-soft's install name is libopenal.1.dylib; the embedded file must match it
if [[ -f "${APP}/Frameworks/libopenal.1.24.2.dylib" ]]; then
    mv "${APP}/Frameworks/libopenal.1.24.2.dylib" "${APP}/Frameworks/libopenal.1.dylib"
fi

# MoltenVK: DXVK dlopens @executable_path/Frameworks/MoltenVK.framework/MoltenVK
cp -R "${MVK_FRAMEWORK}" "${APP}/Frameworks/"
echo "    embedded MoltenVK.framework"

# Redistributable support files only — the game's own data is added later, locally.
echo "==> Adding redistributable support files to GameData/"
mkdir -p "${APP}/GameData/fonts"
cp "${FONTS_SRC}"/*.ttf "${APP}/GameData/fonts/"
cp "${CONFIG_SRC}/dxvk.conf" "${APP}/GameData/dxvk.conf"
cp "${CONFIG_SRC}/Options.ini" "${APP}/GameData/DefaultOptions.ini"
if [[ -f "${EXTRAS_WND}" ]]; then
    mkdir -p "${APP}/GameData/Window/Menus"
    cp "${EXTRAS_WND}" "${APP}/GameData/Window/Menus/ExtrasMenu.wnd"
fi

# Loose icon PNGs alongside the compiled asset catalog (see package-ios-zh.sh)
ICON_SRC="${IOS_DIR}/Stub/Assets.xcassets/AppIcon.appiconset/icon.png"
if [[ -f "${ICON_SRC}" ]]; then
    sips -z 120 120 "${ICON_SRC}" --out "${APP}/AppIcon60x60@2x.png"  >/dev/null
    sips -z 152 152 "${ICON_SRC}" --out "${APP}/AppIcon76x76@2x.png"  >/dev/null
    sips -z 167 167 "${ICON_SRC}" --out "${APP}/AppIcon83.5x83.5@2x.png" >/dev/null
    echo "    icon PNG fallbacks added"
fi

# Point the executable's rpath at the embedded frameworks
install_name_tool -add_rpath "@executable_path/Frameworks" "${APP}/${APP_NAME}" 2>/dev/null || true

# Every @rpath dependency must resolve to a file shipped in Frameworks/, or the app
# dies at launch with "Library not loaded" before showing anything.
echo "==> Checking @rpath dependencies"
missing=0
for bin in "${APP}/${APP_NAME}" "${APP}/Frameworks/"*.dylib; do
    while read -r dep; do
        if [[ ! -e "${APP}/Frameworks/${dep#@rpath/}" ]]; then
            echo "ERROR: $(basename "${bin}") needs ${dep}, which is not in Frameworks/"
            missing=1
        fi
    done < <(otool -L "${bin}" | awk 'NR > 1 && $1 ~ /^@rpath\// { print $1 }')
done
[[ "${missing}" == "0" ]] || exit 1
echo "    all @rpath dependencies present"

echo "==> Ad-hoc signing (the sideloading tool re-signs everything with your Apple ID)"
for f in "${APP}/Frameworks/"*.dylib; do
    codesign --force --sign - --timestamp=none "$f"
done
codesign --force --sign - --timestamp=none "${APP}/Frameworks/MoltenVK.framework"
codesign --force --sign - --timestamp=none "${APP}"
codesign --verify --deep --strict "${APP}" && echo "    ad-hoc signature OK"

echo "==> Creating ${IPA_NAME}"
(cd "${OUT_DIR}" && zip -qry "${IPA_NAME}" Payload)
rm -rf "${OUT_DIR}/Payload"
ls -lh "${OUT_DIR}/${IPA_NAME}"
echo "==> Done: ${OUT_DIR}/${IPA_NAME} (bundle id ${BUNDLE_ID})"
