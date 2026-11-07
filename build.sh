#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BUILD_ROOT="$ROOT/build"
ICONSET="$BUILD_ROOT/OldLaunchpad.iconset"
ARCH=$(uname -m)
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

build_variant() {
    variant=$1
    app_name=$2
    bundle_identifier=$3
    if [ "$variant" = developer ]; then
        output_dir="$BUILD_ROOT/Developer"
    elif [ "$variant" = paid ]; then
        output_dir="$BUILD_ROOT/Paid"
    else
        output_dir="$BUILD_ROOT/Release"
    fi
    app="$output_dir/$app_name.app"

    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$ROOT/Info.plist" "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_identifier" "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $app_name" "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $app_name" "$app/Contents/Info.plist"
    cp "$BUILD_ROOT/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"

    if [ "$variant" = developer ]; then
        swiftc -parse-as-library -target "$ARCH-apple-macosx13.0" \
            -DDEVELOPER_BUILD \
            -framework AppKit \
            -framework Security \
            "$ROOT/Sources/OldLaunchpad.swift" \
            "$ROOT/Sources/LemonSqueezyLicense.swift" \
            "$ROOT/Sources/LicenseActivationWindow.swift" \
            -o "$app/Contents/MacOS/OldLaunchpad"
    elif [ "$variant" = paid ]; then
        swiftc -parse-as-library -target "$ARCH-apple-macosx13.0" \
            -DPAID_BUILD \
            -framework AppKit \
            -framework Security \
            "$ROOT/Sources/OldLaunchpad.swift" \
            "$ROOT/Sources/LemonSqueezyLicense.swift" \
            "$ROOT/Sources/LicenseActivationWindow.swift" \
            -o "$app/Contents/MacOS/OldLaunchpad"
    else
        swiftc -parse-as-library -target "$ARCH-apple-macosx13.0" \
            -framework AppKit \
            -framework Security \
            "$ROOT/Sources/OldLaunchpad.swift" \
            "$ROOT/Sources/LemonSqueezyLicense.swift" \
            "$ROOT/Sources/LicenseActivationWindow.swift" \
            -o "$app/Contents/MacOS/OldLaunchpad"
    fi

    if [ -x "$LSREGISTER" ]; then
        "$LSREGISTER" -f "$app"
    fi
    printf 'Erstellt: %s\n' "$app"
}

case "${1:-}" in
    "")
        build_both=true
        build_developer=false
        build_release=false
        build_paid=false
        ;;
    --all)
        build_both=true
        build_developer=false
        build_release=false
        build_paid=false
        ;;
    --developer)
        build_both=false
        build_developer=true
        build_release=false
        build_paid=false
        ;;
    --release)
        build_both=false
        build_developer=false
        build_release=true
        build_paid=false
        ;;
    --paid)
        build_both=false
        build_developer=false
        build_release=false
        build_paid=true
        ;;
    *)
        printf 'Verwendung: %s [--all|--developer|--release|--paid]\n' "$0" >&2
        exit 2
        ;;
esac
if [ "$#" -gt 1 ]; then
    printf 'Verwendung: %s [--all|--developer|--release|--paid]\n' "$0" >&2
    exit 2
fi

mkdir -p "$BUILD_ROOT"
swift "$ROOT/Sources/GenerateIcon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$BUILD_ROOT/AppIcon.icns"

if [ "$build_both" = true ] || [ "$build_release" = true ]; then
    build_variant release "Old Launchpad" "local.deepal.oldlaunchpad"
fi
if [ "$build_both" = true ] || [ "$build_developer" = true ]; then
    build_variant developer "Old Launchpad Developer" "local.deepal.oldlaunchpad.developer"
fi
if [ "$build_paid" = true ]; then
    build_variant paid "Old Launchpad" "local.deepal.oldlaunchpad"
fi
