#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
source_files=("$project_dir"/Sources/Winova/*.m)

plutil -lint "$project_dir/Resources/Info.plist"
zsh -n "$project_dir/scripts/build.sh" "$project_dir/scripts/run.sh"
zsh -n "$project_dir/scripts/package.sh"
/usr/bin/clang \
  -fobjc-arc \
  -fsyntax-only \
  -mmacosx-version-min=13.0 \
  "${source_files[@]}"

legacy_name='cross''over'
if rg -ni "$legacy_name" "$project_dir" \
  --hidden \
  --glob '!.git/**' \
  --glob '!build/**'; then
  echo "Disallowed legacy reference found" >&2
  exit 1
fi

echo "Verification passed"
