#!/usr/bin/env bash
# Capability-based pstore configuration; never allocate physical memory here.
set -euo pipefail
mode=${1:-}
case "$mode" in prepare|verify|report) ;; *) echo 'Usage: configure-pstore.sh prepare|verify|report' >&2; exit 2 ;; esac
[[ "${ENABLE_PSTORE_DEBUG:-false}" == true ]] || exit 0
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=${KERNEL_ROOT:-}
out=${OUT_DIR:-out}
[[ "$out" == /* ]] || out="$root/$out"
config="$out/.config"
backend=unavailable
symbols=
status() {
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_ENV"
  fi
}
die() { status PSTORE_DEBUG_STATUS "$1"; echo "[ERROR] $2" >&2; exit 1; }
read_symbols() {
  [[ -d "$root/fs/pstore" ]] || return 0
  # Include vendor/legacy driver Kconfigs, but not generated output or .git.
  symbols=$(find "$root" -type d \( -name .git -o -path "$out" \) -prune -o \
    -type f \( -name Kconfig -o -name 'Kconfig.*' \) -exec \
    awk '$1 == "config" || $1 == "menuconfig" { print $2 }' {} + | sort -u)
  if has_symbol PSTORE_RAM; then backend=PSTORE_RAM
  elif has_symbol RAMOOPS; then backend=RAMOOPS
  fi
}
has_symbol() { grep -Fxq "$1" <<< "$symbols"; }
set_y() {
  sed -i -E "/^(# )?CONFIG_$1(=.*| is not set)$/d" "$config"
  printf 'CONFIG_%s=y\n' "$1" >> "$config"
}
config_y() { [[ -f "$config" ]] && grep -qx "CONFIG_$1=y" "$config"; }
read_symbols
required=(PRINTK PSTORE PSTORE_CONSOLE)
[[ "$backend" == unavailable ]] || required+=("$backend")
# PMSG is supplementary; unlike console it requires a userspace writer.
has_symbol PSTORE_PMSG && required+=(PSTORE_PMSG)

if [[ "$mode" == prepare ]]; then
  status PSTORE_DEBUG_STATUS configuring
  [[ -f "$config" ]] || die config-missing "pstore requested but $config is missing"
  [[ "$backend" != unavailable ]] || die backend-unavailable 'No PSTORE_RAM/RAMOOPS Kconfig backend in this tree'
  for key in "${required[@]}"; do
    has_symbol "$key" || die symbol-unavailable "Required pstore symbol CONFIG_$key is not defined"
  done
  for key in "${required[@]}"; do set_y "$key"; done
  has_symbol PSTORE_PMSG || echo '[WARNING] This tree lacks PSTORE_PMSG; kernel console/crash logging only' >&2
  echo "[+] pstore requested with built-in $backend; reserved RAM must come from the device"
  exit 0
fi

if [[ "$mode" == verify ]]; then
  [[ "$backend" != unavailable ]] || die backend-unavailable 'No ramoops backend was found'
  for key in "${required[@]}"; do
    config_y "$key" || die config-rejected "Kconfig did not retain CONFIG_$key=y; check dependencies and source support"
  done
  status PSTORE_DEBUG_STATUS config-verified
  status PSTORE_BACKEND_STATUS "$backend=builtin"
  echo '[+] pstore config verified (device runtime/reserved memory not yet verified)'
  exit 0
fi

# Always-run diagnostics: preserve the effective config even when configure/build
# failed. A source DTS candidate is NOT proof of an active node in the boot DTB.
artifact=${ARTIFACT_DIR:?ARTIFACT_DIR is required}
diag="$artifact/pstore-debug"
mkdir -p "$diag"
cp "$script_dir/collect-pstore.sh" "$diag/collect-pstore.sh"
cp "$script_dir/../../docs/pstore-debug.md" "$diag/README.md"
if [[ -f "$config" ]]; then
  cp "$config" "$diag/kernel.config"
  grep -E '^(# )?CONFIG_(PSTORE[^ =]*|RAMOOPS|PRINTK|PANIC[^ =]*|LOG_BUF_SHIFT|CMDLINE[^ =]*)(=| is not set)' \
    "$config" > "$diag/pstore-config.txt" || true
else
  printf '%s\n' 'No generated .config (configuration stage may not have been reached).' > "$diag/pstore-config.txt"
fi
python3 - "$root" "${ARCH:-arm64}" > "$diag/ramoops-dts-candidates.txt" <<'PY'
import pathlib
import re
import sys
root = pathlib.Path(sys.argv[1]) if sys.argv[1] else None
if root and root.is_dir():
    # Qualcomm vendor trees may place DTS under a vendor/ subdirectory.
    dirs = [root / 'arch' / sys.argv[2] / 'boot' / 'dts', root / 'vendor']
    for directory in dirs:
        if not directory.is_dir():
            continue
        for path in sorted(directory.rglob('*')):
            if path.suffix not in ('.dts', '.dtsi') or not path.is_file():
                continue
            source = path.read_text(errors='replace')
            source = re.sub(r'/\*.*?\*/|//[^\n]*', '', source, flags=re.S)
            if re.search(r'\bcompatible\s*=[^;]*"ramoops"[^;]*;', source):
                print(path.relative_to(root))
PY
if [[ -s "$diag/ramoops-dts-candidates.txt" ]]; then
  dt_status=source-candidates-only
else
  dt_status=no-source-node-found-check-device-dt
fi
backend_status=unavailable
if [[ "$backend" != unavailable ]]; then
  backend_status="$backend=not-builtin"
  config_y "$backend" && backend_status="$backend=builtin"
fi
pmsg_status=not-enabled
config_y PSTORE_PMSG && pmsg_status=enabled-needs-userspace-writer
ftrace_status=not-enabled
config_y PSTORE_FTRACE && ftrace_status=enabled-by-existing-config
status PSTORE_BACKEND_STATUS "$backend_status"
status PSTORE_DTS_STATUS "$dt_status"
status PSTORE_PMSG_STATUS "$pmsg_status"
status PSTORE_FTRACE_STATUS "$ftrace_status"
{
  printf 'Request: true\nConfiguration: %s\nBackend: %s\nDTS: %s\nPMSG: %s\nFTRACE: %s\n' \
    "${PSTORE_DEBUG_STATUS:-not-verified}" "$backend_status" "$dt_status" "$pmsg_status" "$ftrace_status"
  printf '%s\n' \
    'Runtime: UNVERIFIED. Confirm active device DT/DTBO, reserved memory and buffer sizes.' \
    'Source candidates may belong to OTHER devices or disabled nodes. No physical addresses were changed.' \
    'Console logs wrap; panic/oops records depend on dump policy. Hard power loss may erase RAM.' \
    'No forced panic, watchdog, tracing, thermal or SELinux policy changes were made.'
} > "$diag/status.txt"
echo '[WARNING] pstore runtime still requires device-specific reserved memory; see pstore-debug/README.md' >&2
