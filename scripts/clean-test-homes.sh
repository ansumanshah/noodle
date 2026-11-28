#!/usr/bin/env bash
# Lists leftover Noodle test folders in /tmp and their real disk use. Deletes them only with --delete.
# Skips anything modified in the last MINUTES (default 360), and any folder holding a .keep file.
#   scripts/clean-test-homes.sh [--delete] [MINUTES]
set -euo pipefail

delete=0
if [[ ${1:-} == --delete ]]; then
  delete=1
  shift
fi
minutes=${1:-360}
[[ $minutes =~ ^[0-9]+$ ]] || { echo "usage: $0 [--delete] [MINUTES]" >&2; exit 2; }

total=0
count=0
while IFS= read -r dir; do
  [[ -e $dir/.keep ]] && { echo "keep    $dir"; continue; }
  # A folder whose contents are in use by a running process must survive.
  if lsof +D "$dir" >/dev/null 2>&1; then
    echo "in use  $dir"
    continue
  fi
  kb=$(du -sk "$dir" | cut -f1)
  total=$((total + kb))
  count=$((count + 1))
  printf '%6d MB  %s\n' $((kb / 1024)) "$dir"
  if [[ $delete == 1 ]]; then
    rm -rf -- "$dir"
  fi
done < <(find /private/tmp -maxdepth 1 -type d -name 'noodle*' -mmin "+$minutes" | sort)

verb=$([[ $delete == 1 ]] && echo removed || echo "would remove")
printf '%s %d folders, %d MB\n' "$verb" "$count" $((total / 1024))
