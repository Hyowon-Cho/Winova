#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_dir="$project_dir/build/Winova.app"
dist_dir="$project_dir/dist"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_dir/Resources/Info.plist")"
architecture="$(/usr/bin/uname -m)"
archive_name="Winova-${version}-macos-${architecture}.tar.gz"
archive_path="$dist_dir/$archive_name"
checksum_path="$archive_path.sha256"
staging_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/winova-package.XXXXXX")"

cleanup() {
  /bin/rm -rf "$staging_dir"
}
trap cleanup EXIT

"$project_dir/scripts/build.sh"
/usr/bin/codesign --verify --deep --strict "$app_dir"

/bin/mkdir -p "$dist_dir" "$staging_dir/Winova-${version}"
/usr/bin/ditto "$app_dir" "$staging_dir/Winova-${version}/Winova.app"
/bin/cp "$project_dir/README.md" "$staging_dir/Winova-${version}/README.md"
/bin/cp "$project_dir/LICENSE" "$staging_dir/Winova-${version}/LICENSE"
/bin/cp "$project_dir/THIRD_PARTY_NOTICES.md" "$staging_dir/Winova-${version}/THIRD_PARTY_NOTICES.md"
/bin/cp "$project_dir/SECURITY.md" "$staging_dir/Winova-${version}/SECURITY.md"

/bin/rm -f "$archive_path" "$checksum_path"
COPYFILE_DISABLE=1 /usr/bin/tar -czf "$archive_path" -C "$staging_dir" "Winova-${version}"
(
  cd "$dist_dir"
  /usr/bin/shasum -a 256 "$archive_name" > "$archive_name.sha256"
)

echo "Created $archive_path"
echo "Created $checksum_path"
