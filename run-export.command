#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
binary="$script_dir/WeChat Media Exporter.app/Contents/MacOS/WeChat Media Exporter"
config="$script_dir/config.json"

if [[ ! -f "$config" ]]; then
  print -u2 "Missing $config"
  print -u2 "Duplicate config.example.json as config.json and set its destination first."
  exit 1
fi

exec "$binary" run --config "$config"
