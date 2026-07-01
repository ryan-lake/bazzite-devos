#!/usr/bin/env bash
set -euo pipefail

readonly modules=(snd_acp_pci snd_acp_mach snd_acp_legacy_mach)
readonly dependencies=(snd_acp_config snd_acp_legacy_common snd_amd_acpi_mach snd_soc_nau8821)

acp_pci_device="${ACP_MIC_PCI_DEVICE:-}"
load_modules=0
restart_audio=0
fix_compression=0
runtime_module_dir="/tmp/acp-mic-runtime-modules-$(uname -r)"

usage() {
  cat <<'EOF'
Usage: test-acp-mic-runtime.sh [--fix-compression] [--load] [--restart-audio]

Checks whether the local AMD ACP mic modules are installed, signed, loadable,
and visible to ALSA/PipeWire.

Options:
  --fix-compression  Recompress installed ACP mic modules as kernel-compatible
                     .ko.xz streams using XZ CRC32, then run depmod.
  --load           Run the same ordered modprobe sequence as the system service.
  --restart-audio  Restart the current user's WirePlumber/PipeWire services.

Environment:
  ACP_MIC_PCI_DEVICE  PCI device to inspect. Default: 0000:c4:00.5
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --load)
      load_modules=1
      ;;
    --fix-compression)
      fix_compression=1
      ;;
    --restart-audio)
      restart_audio=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

section() {
  printf '\n== %s ==\n' "$1"
}

ok() {
  printf 'ok: %s\n' "$1"
}

warn() {
  printf 'warn: %s\n' "$1" >&2
}

fail() {
  printf 'fail: %s\n' "$1" >&2
  return 1
}

run_as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

module_file_for() {
  local module_name="$1"
  local module_file

  module_file="$(modinfo -n "$module_name" 2>/dev/null || true)"
  if [[ -n "$module_file" ]]; then
    printf '%s\n' "$module_file"
  fi
}

custom_module_file_for() {
  local module_name="$1"
  local module_file_name
  local kernel_release

  module_file_name="${module_name//_/-}.ko.xz"
  kernel_release="$(uname -r)"

  printf '/usr/lib/modules/%s/extra/acp-mic/%s\n' "$kernel_release" "$module_file_name"
}

xz_check_for() {
  local module_file="$1"

  xz --robot --list "$module_file" 2>/dev/null | awk '$1 == "file" { print $7; exit }'
}

fix_module_compression() {
  local module_name="$1"
  local module_file temp_file temp_dir

  module_file="$(custom_module_file_for "$module_name")"
  if [[ ! -e "$module_file" ]]; then
    fail "$module_name custom file is missing at $module_file"
    return 1
  fi

  temp_dir="$(mktemp -d)"
  temp_file="$temp_dir/${module_name//_/-}.ko"
  xz --decompress --stdout "$module_file" > "$temp_file"
  xz -f -T1 --check=crc32 "$temp_file"
  if ! run_as_root install -m 0644 "$temp_file.xz" "$module_file"; then
    warn "could not replace $module_file, likely because /usr is read-only on this booted ostree deployment"
    warn "use --load to test with temporary uncompressed modules, then rebuild/rebase for the permanent CRC32 fix"
    rm -rf "$temp_dir"
    return 1
  fi
  rm -rf "$temp_dir"
}

detect_acp_pci_device() {
  local device_path vendor device class

  for device_path in /sys/bus/pci/devices/*; do
    vendor="$(cat "$device_path/vendor" 2>/dev/null || true)"
    device="$(cat "$device_path/device" 2>/dev/null || true)"
    class="$(cat "$device_path/class" 2>/dev/null || true)"

    if [[ "$vendor" == "0x1022" && "$device" == "0x15e2" && "$class" == "0x048000" ]]; then
      printf '%s\n' "${device_path##*/}"
      return 0
    fi
  done

  return 1
}

module_loaded() {
  local module_name="$1"
  grep -q "^${module_name} " /proc/modules
}

load_custom_module() {
  local module_name="$1"
  local custom_module_file module_to_load check_type

  if module_loaded "$module_name"; then
    ok "$module_name is already loaded"
    return 0
  fi

  custom_module_file="$(custom_module_file_for "$module_name")"
  module_to_load="$custom_module_file"
  check_type="$(xz_check_for "$custom_module_file")"

  if [[ "$check_type" != "CRC32" ]]; then
    mkdir -p "$runtime_module_dir"
    module_to_load="$runtime_module_dir/${module_name//_/-}.ko"
    xz --decompress --stdout "$custom_module_file" > "$module_to_load"
    chmod 0644 "$module_to_load"
    warn "$module_name uses XZ ${check_type:-unknown}; loading temporary uncompressed copy at $module_to_load"
  fi

  printf 'insmod %s\n' "$module_to_load"
  run_as_root insmod "$module_to_load"
}

check_module() {
  local module_name="$1"
  local module_file custom_module_file

  custom_module_file="$(custom_module_file_for "$module_name")"
  if [[ -e "$custom_module_file" ]]; then
    ok "$module_name custom file exists at $custom_module_file"
    check_type="$(xz_check_for "$custom_module_file")"
    if [[ "$check_type" == "CRC32" ]]; then
      ok "$module_name XZ check type is CRC32"
    else
      warn "$module_name XZ check type is ${check_type:-unknown}; kernel module loading expects CRC32"
    fi
    modinfo "$custom_module_file" | grep -E '^(filename|signer|sig_key|sig_hashalgo):' || true
  else
    warn "$module_name custom file is missing at $custom_module_file"
  fi

  module_file="$(module_file_for "$module_name")"
  if [[ -z "$module_file" ]]; then
    fail "$module_name is not discoverable by modinfo for kernel $(uname -r)"
    return 1
  fi

  ok "$module_name modprobe resolution is $module_file"
  modinfo "$module_file" | grep -E '^(filename|signer|sig_key|sig_hashalgo):' || true
}

if [[ -z "$acp_pci_device" ]]; then
  acp_pci_device="$(detect_acp_pci_device || true)"
fi

section "Kernel"
printf 'running kernel: %s\n' "$(uname -r)"
printf 'module directory: /usr/lib/modules/%s\n' "$(uname -r)"
if [[ -n "$acp_pci_device" ]]; then
  printf 'ACP PCI device: %s\n' "$acp_pci_device"
else
  warn "could not auto-detect AMD ACP PCI device 1022:15e2; set ACP_MIC_PCI_DEVICE manually"
fi

section "Module files and signatures"
missing_modules=0
for module_name in "${modules[@]}"; do
  if ! check_module "$module_name"; then
    missing_modules=1
  fi
done

if [[ "$missing_modules" -ne 0 ]]; then
  warn "One or more ACP mic modules are missing. Boot into the image that built them, or rebuild the image."
fi

if [[ "$fix_compression" -eq 1 ]]; then
  section "Fixing module compression"
  for module_name in "${modules[@]}"; do
    fix_module_compression "$module_name"
    ok "recompressed $module_name with XZ CRC32"
  done
  run_as_root depmod -a "$(uname -r)"
else
  section "Fixing module compression"
  warn "skipped; rerun with --fix-compression if any custom module reports an XZ check type other than CRC32"
fi

section "Load state before test"
for module_name in "${dependencies[@]}" "${modules[@]}"; do
  if module_loaded "$module_name"; then
    ok "$module_name is loaded"
  else
    warn "$module_name is not loaded"
  fi
done

if [[ "$load_modules" -eq 1 ]]; then
  section "Loading modules"
  for module_name in "${dependencies[@]}"; do
    printf 'modprobe %s\n' "$module_name"
    run_as_root modprobe "$module_name"
  done

  for module_name in "${modules[@]}"; do
    load_custom_module "$module_name"
  done
else
  section "Loading modules"
  warn "skipped; rerun with --load to exercise the ordered modprobe/insmod sequence"
fi

section "Driver binding"
if [[ -z "$acp_pci_device" ]]; then
  warn "skipped PCI driver check because no ACP PCI device was detected"
elif [[ -e "/sys/bus/pci/devices/$acp_pci_device/driver" ]]; then
  readlink "/sys/bus/pci/devices/$acp_pci_device/driver"
else
  warn "no PCI driver bound at /sys/bus/pci/devices/$acp_pci_device/driver"
fi

if [[ -e /sys/bus/platform/devices/acp-pdm-mach/driver ]]; then
  readlink /sys/bus/platform/devices/acp-pdm-mach/driver
else
  warn "no platform driver bound at /sys/bus/platform/devices/acp-pdm-mach/driver"
fi

section "Audio devices"
if command -v arecord >/dev/null 2>&1; then
  arecord -l || true
else
  warn "arecord is not installed"
fi

if command -v pactl >/dev/null 2>&1; then
  pactl list sources short || true
else
  warn "pactl is not installed"
fi

if [[ "$restart_audio" -eq 1 ]]; then
  section "Restarting user audio"
  systemctl --user restart wireplumber pipewire pipewire-pulse
  ok "restarted wireplumber, pipewire, and pipewire-pulse for the current user"
elif command -v systemctl >/dev/null 2>&1; then
  section "User audio restart"
  warn "skipped; rerun with --restart-audio after --load if PipeWire scanned before the ACP device appeared"
fi

section "Expected success signals"
cat <<EOF
- PCI driver path includes: drivers/snd_acp_pci
- Platform driver path includes: drivers/acp_mach
- arecord shows: acppdmmach / DMIC capture dmic-hifi-0
- pactl shows: HiFi__Mic1__source and/or HiFi__Mic2__source
EOF