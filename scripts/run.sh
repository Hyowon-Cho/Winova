#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_dir="$project_dir/build/Winova.app"

if [[ ! -x "$app_dir/Contents/MacOS/Winova" ]]; then
  "$project_dir/scripts/build.sh"
fi

open "$app_dir"
