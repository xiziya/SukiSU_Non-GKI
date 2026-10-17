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
ramoops_platform_status=unknown-device-provisioning
ramoops_cmdline_status=not-checked
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
has_polaris_ramoops_source() {
  local codename=${CODENAME:-}
  [[ "${codename,,}" == polaris ]] && [[ -f "$root/fs/pstore/ram.c" ]] && \
    grep -Fq 'early_param("ramoops_memreserve", ramoops_memreserve);' \
      "$root/fs/pstore/ram.c" && \
    grep -Fq 'ramoops_data.mem_address = 0xB0000000;' \
      "$root/fs/pstore/ram.c" && \
    grep -Fq 'core_initcall(msm_register_ramoops_device);' \
      "$root/fs/pstore/ram.c"
}
select_polaris_ramoops_platform() {
  has_polaris_ramoops_source || return 1
  # SDM845 is shared by several phones; only D5X identifies polaris/MIX 2S.
  has_symbol MACH_XIAOMI_D5X || return 1
  set_y MACH_XIAOMI_D5X
  # D5X selects the SDM845 platform Kconfig symbol, but make this dependency
  # explicit in the generated config before olddefconfig resolves fragments.
  has_symbol MACH_XIAOMI_SDM845 && set_y MACH_XIAOMI_SDM845
  config_y MACH_XIAOMI_SDM845
}
ensure_polaris_ramoops_cmdline() {
  local result
  has_symbol CMDLINE || die symbol-unavailable 'Polaris ramoops source requires CONFIG_CMDLINE support'
  has_symbol CMDLINE_EXTEND || die symbol-unavailable 'Polaris ramoops requires CONFIG_CMDLINE_EXTEND to preserve bootloader arguments'
  set_y CMDLINE_EXTEND
  result=$(python3 - "$config" <<'PY'
import ast
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
lines = path.read_text().splitlines()
value = ""
found = False
for line in lines:
    if line.startswith("CONFIG_CMDLINE="):
        try:
            value = ast.literal_eval(line.split("=", 1)[1])
        except (SyntaxError, ValueError) as exc:
            raise SystemExit(f"Cannot safely parse CONFIG_CMDLINE: {exc}")
        if not isinstance(value, str):
            raise SystemExit("CONFIG_CMDLINE is not a string")
        found = True
        break
    if line == "# CONFIG_CMDLINE is not set":
        found = True
        break
if not found:
    raise SystemExit("CONFIG_CMDLINE is absent from generated .config")

tokens = value.split()
params = [token for token in tokens if token.startswith("ramoops_memreserve=")]
if len(params) > 1:
    raise SystemExit("CONFIG_CMDLINE contains duplicate ramoops_memreserve parameters")
if params:
    if not re.fullmatch(r"ramoops_memreserve=[1-9][0-9]*[KMGkmg]?", params[0]):
        raise SystemExit("CONFIG_CMDLINE contains an invalid ramoops_memreserve value")
    result = "already-configured"
else:
    tokens.append("ramoops_memreserve=4M")
    value = " ".join(tokens)
    quoted = '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'
    replacement = "CONFIG_CMDLINE=" + quoted
    for index, line in enumerate(lines):
        if line.startswith("CONFIG_CMDLINE=") or line == "# CONFIG_CMDLINE is not set":
            lines[index] = replacement
            break
    else:
        raise SystemExit("CONFIG_CMDLINE disappeared while updating .config")
    path.write_text("\n".join(lines) + "\n")
    result = "added-4M-platform-default"
print(result)
PY
) || die config-rejected "could not configure the Polaris ramoops command line: $result"
  ramoops_platform_status=polaris-source-platform-driver
  ramoops_cmdline_status=$result
  status PSTORE_PLATFORM_PROVISIONING_STATUS "$ramoops_platform_status"
  status PSTORE_RAMOOPS_CMDLINE_STATUS "$ramoops_cmdline_status"
}
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
  if has_polaris_ramoops_source; then
    select_polaris_ramoops_platform || die symbol-unavailable 'Polaris ramoops source was detected, but this tree has no MACH_XIAOMI_D5X board selector'
    ensure_polaris_ramoops_cmdline
  else
    ramoops_platform_status=device-dt-or-platform-setup-required
    ramoops_cmdline_status=not-injected
    status PSTORE_PLATFORM_PROVISIONING_STATUS "$ramoops_platform_status"
    status PSTORE_RAMOOPS_CMDLINE_STATUS "$ramoops_cmdline_status"
  fi
  has_symbol PSTORE_PMSG || echo '[WARNING] This tree lacks PSTORE_PMSG; kernel console/crash logging only' >&2
  echo "[+] pstore requested with built-in $backend; platform provisioning: $ramoops_platform_status"
  exit 0
fi

if [[ "$mode" == verify ]]; then
  [[ "$backend" != unavailable ]] || die backend-unavailable 'No ramoops backend was found'
  for key in "${required[@]}"; do
    config_y "$key" || die config-rejected "Kconfig did not retain CONFIG_$key=y; check dependencies and source support"
  done
  if has_polaris_ramoops_source; then
    has_symbol MACH_XIAOMI_D5X && config_y MACH_XIAOMI_D5X || \
      die config-rejected 'Polaris ramoops source was detected, but Kconfig did not retain the MIX 2S platform symbol'
    config_y MACH_XIAOMI_SDM845 || die config-rejected 'Polaris ramoops source was detected, but Kconfig did not retain CONFIG_MACH_XIAOMI_SDM845=y'
    config_y CMDLINE_EXTEND || die config-rejected 'Kconfig did not retain CONFIG_CMDLINE_EXTEND=y for Polaris ramoops'
    if ! python3 - "$config" <<'PY'
import ast
import pathlib
import re
import sys

config = pathlib.Path(sys.argv[1]).read_text().splitlines()
line = next((line for line in config if line.startswith("CONFIG_CMDLINE=")), None)
if line is None:
    raise SystemExit(1)
try:
    cmdline = ast.literal_eval(line.split("=", 1)[1])
except (SyntaxError, ValueError):
    raise SystemExit(1)
matches = [arg for arg in cmdline.split() if arg.startswith("ramoops_memreserve=")]
if len(matches) != 1 or not re.fullmatch(r"ramoops_memreserve=[1-9][0-9]*[KMGkmg]?", matches[0]):
    raise SystemExit(1)
PY
    then
      die config-rejected 'Polaris ramoops source is active but CONFIG_CMDLINE lacks ramoops_memreserve'
    fi
    ramoops_platform_status=polaris-source-platform-driver
    ramoops_cmdline_status=verified
  else
    ramoops_platform_status=device-dt-or-platform-setup-required
    ramoops_cmdline_status=not-injected
  fi
  status PSTORE_DEBUG_STATUS config-verified
  status PSTORE_BACKEND_STATUS "$backend=builtin"
  status PSTORE_PLATFORM_PROVISIONING_STATUS "$ramoops_platform_status"
  status PSTORE_RAMOOPS_CMDLINE_STATUS "$ramoops_cmdline_status"
  echo "[+] pstore config verified; platform provisioning: $ramoops_platform_status (runtime still needs device verification)"
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
status PSTORE_PLATFORM_PROVISIONING_STATUS "${PSTORE_PLATFORM_PROVISIONING_STATUS:-device-dt-or-platform-setup-required}"
status PSTORE_RAMOOPS_CMDLINE_STATUS "${PSTORE_RAMOOPS_CMDLINE_STATUS:-not-verified}"
{
  printf 'Request: true\nConfiguration: %s\nBackend: %s\nDTS: %s\nPlatform provisioning: %s\nRamoops command line: %s\nPMSG: %s\nFTRACE: %s\n' \
    "${PSTORE_DEBUG_STATUS:-not-verified}" "$backend_status" "$dt_status" \
    "${PSTORE_PLATFORM_PROVISIONING_STATUS:-device-dt-or-platform-setup-required}" \
    "${PSTORE_RAMOOPS_CMDLINE_STATUS:-not-verified}" "$pmsg_status" "$ftrace_status"
  printf '%s\n' \
    'Runtime: UNVERIFIED. Confirm active device DT/DTBO, reserved memory and buffer sizes.' \
    'Source candidates may belong to OTHER devices or disabled nodes. Generic physical addresses are never injected.' \
    'Console logs wrap; panic/oops records depend on dump policy. Hard power loss may erase RAM.' \
    'No forced panic, watchdog, tracing, thermal or SELinux policy changes were made.'
} > "$diag/status.txt"
echo '[WARNING] pstore runtime still requires device-specific reserved memory; see pstore-debug/README.md' >&2
