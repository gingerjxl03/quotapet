#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
sdk_path=${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}
app_dir="$project_dir/build/QuotaPet.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$project_dir/src/Info.plist" "$app_dir/Contents/Info.plist"
xcrun clang -fobjc-arc -fblocks -O2 \
    -isysroot "$sdk_path" -mmacosx-version-min=13.0 \
    -framework Cocoa "$project_dir/src/QuotaPet.m" \
    -o "$app_dir/Contents/MacOS/QuotaPet"
codesign --force --sign - "$app_dir"
printf 'Built %s\n' "$app_dir"
