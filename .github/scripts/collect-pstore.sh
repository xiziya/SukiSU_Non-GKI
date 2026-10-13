#!/system/bin/sh
# Run once as root on Android/recovery after reboot. Never clear pstore records.
set -eu
if [ "$(id -u)" != 0 ]; then
  echo 'Run with root (su -c) or in a root recovery shell.' >&2
  exit 1
fi
parent=${1:-/data/local/tmp}
[ -d "$parent" ] || { echo "Output directory does not exist: $parent" >&2; exit 1; }
umask 077
output=$(mktemp -d "$parent/pstore-$(date +%Y%m%d-%H%M%S)-XXXXXX")
if ! grep -qs ' /sys/fs/pstore pstore ' /proc/mounts; then
  mkdir -p /sys/fs/pstore
  mount -t pstore pstore /sys/fs/pstore 2>"$output/mount-error.txt" || true
fi
mkdir "$output/pstore"
count=0
for record in /sys/fs/pstore/*; do
  [ -f "$record" ] || continue
  if cp "$record" "$output/pstore/"; then count=$((count+1)); fi
done
{
  uname -a
  printf 'Copied pstore records: %s\n' "$count"
  grep ' pstore ' /proc/mounts || true
  ls -l /sys/fs/pstore || true
  for param in /sys/module/ramoops/parameters/* /sys/module/pstore/parameters/*; do
    [ -f "$param" ] || continue
    printf '\n%s: ' "$param"
    cat "$param" || true
  done
  if command -v getprop >/dev/null 2>&1; then
    for prop in ro.boot.bootreason sys.boot.reason persist.sys.boot.reason; do
      printf '\n%s: ' "$prop"
      getprop "$prop" || true
    done
  fi
} >"$output/runtime-status.txt" 2>&1
for file in /proc/cmdline /proc/bootconfig /proc/last_kmsg; do
  [ -r "$file" ] || continue
  cp "$file" "$output/$(basename "$file")" 2>>"$output/read-errors.txt" || true
done
dmesg >"$output/current-boot-dmesg.txt" 2>&1 || true
if command -v logcat >/dev/null 2>&1; then
  logcat -b all -d >"$output/current-boot-logcat.txt" 2>&1 || true
fi
printf 'Saved to %s (%s pstore records). Original records were NOT deleted.\n' "$output" "$count"
if [ "$count" -eq 0 ]; then
  echo 'Empty pstore does not prove no crash: check backend, active DT, retention and boot-time log collectors.'
fi
