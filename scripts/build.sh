#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_dir="$project_dir/build/Winova.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"

mkdir -p "$macos_dir" "$resources_dir"
source_files=("$project_dir"/Sources/Winova/*.m)

/usr/bin/clang \
  -fobjc-arc \
  -O \
  -mmacosx-version-min=13.0 \
  -framework AppKit \
  -framework UniformTypeIdentifiers \
  "${source_files[@]}" \
  -o "$macos_dir/Winova"

cp "$project_dir/Resources/Info.plist" "$contents_dir/Info.plist"
cp "$project_dir/THIRD_PARTY_NOTICES.md" "$resources_dir/THIRD_PARTY_NOTICES.md"

plutil -lint "$contents_dir/Info.plist"
codesign --force --sign - --timestamp=none "$app_dir"

echo "Built $app_dir"
