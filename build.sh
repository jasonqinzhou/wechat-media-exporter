#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
app_dir="$project_dir/WeChat Media Exporter.app"
contents_dir="$app_dir/Contents"
executable_dir="$contents_dir/MacOS"

mkdir -p "$executable_dir"
cp "$project_dir/Resources/Info.plist" "$contents_dir/Info.plist"

xcrun swiftc \
  "$project_dir/WeChatMediaExporter.swift" \
  -o "$executable_dir/WeChat Media Exporter" \
  -framework AppKit \
  -framework ApplicationServices

plutil -lint "$contents_dir/Info.plist"
codesign --force --deep --sign - "$app_dir"
codesign --verify --deep --strict --verbose=2 "$app_dir"

print "Built: $app_dir"

