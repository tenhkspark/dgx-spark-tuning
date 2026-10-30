#!/usr/bin/env bash
# trash.sh — move paths to the trash instead of deleting them.
#
#   ./trash.sh ~/models/old-checkpoint ~/logs/run-0912.log
#
# Uses gio (freedesktop trash, with .trashinfo so restore works). Falls back to
# ~/.local/share/Trash/files when gio is not installed.
set -euo pipefail

if [ $# -eq 0 ]; then
  sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 1
fi

if command -v gio >/dev/null 2>&1; then
  gio trash -- "$@"
  printf 'trashed: %s\n' "$*"
  exit 0
fi

FILES="$HOME/.local/share/Trash/files"
INFO="$HOME/.local/share/Trash/info"
mkdir -p "$FILES" "$INFO"

for p in "$@"; do
  if [ ! -e "$p" ] && [ ! -L "$p" ]; then
    echo "missing: $p" >&2
    continue
  fi
  abs=$(cd "$(dirname "$p")" && pwd)/$(basename "$p")
  name=$(basename "$p")
  dest="$FILES/$name"
  n=1
  while [ -e "$dest" ] || [ -L "$dest" ]; do
    dest="$FILES/$name.$n"
    n=$((n + 1))
  done
  mv -- "$p" "$dest"
  {
    printf '[Trash Info]\n'
    printf 'Path=%s\n' "$abs"
    printf 'DeletionDate=%s\n' "$(date +%Y-%m-%dT%H:%M:%S)"
  } > "$INFO/$(basename "$dest").trashinfo"
  printf 'trashed: %s -> %s\n' "$p" "$dest"
done
