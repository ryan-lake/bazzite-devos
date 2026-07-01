#!/usr/bin/env bash
set -euo pipefail

readonly kernel_repo="${ACP_MIC_KERNEL_REPO:-https://github.com/OpenGamingCollective/linux.git}"
readonly module_names=(snd-acp-pci snd-acp-mach snd-acp-legacy-mach)

export CCACHE_DISABLE=1

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

find_signing_key() {
  local candidate
  for candidate in \
    "${KERNEL_MODULE_SIGN_KEY:-}" \
    /etc/pki/akmods/private/private_key.priv \
    /run/secrets/kernel-module-signing.key \
    /tmp/certs/private_key.priv \
    /run/secrets/akmods_private_key; do
    if [[ -n "$candidate" && -r "$candidate" && -s "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

find_signing_cert() {
  local candidate
  for candidate in \
    "${KERNEL_MODULE_SIGN_CERT:-}" \
    /run/secrets/kernel-module-signing.der \
    /etc/pki/akmods/certs/akmods-ublue.der \
    /etc/pki/akmods/certs/public_key.der \
    /tmp/certs/public_key.der \
    /run/secrets/akmods_public_key; do
    if [[ -n "$candidate" && -r "$candidate" && -s "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

branch_for_kernel() {
  local kernel_release="$1"
  local kernel_version major minor

  kernel_version="${kernel_release%%-*}"
  IFS=. read -r major minor _ <<< "$kernel_version"

  if [[ -z "${major:-}" || -z "${minor:-}" ]]; then
    echo "Unable to determine OGC branch from kernel release: $kernel_release" >&2
    return 1
  fi

  printf 'ogc-%s.%s.y\n' "$major" "$minor"
}

source_for_branch() {
  local branch="$1"
  local source_dir="$workdir/linux-$branch"

  if [[ ! -d "$source_dir" ]]; then
    git clone --depth=1 --branch "$branch" "$kernel_repo" "$source_dir"
  fi

  printf '%s\n' "$source_dir"
}

module_is_available() {
  local kernel_release="$1"
  local module_name

  for module_name in "${module_names[@]}"; do
    if ! modinfo -k "$kernel_release" "${module_name//-/_}" >/dev/null 2>&1; then
      return 1
    fi
  done

  return 0
}

build_for_kernel() {
  local kernel_dir="$1"
  local kernel_release branch source_dir install_dir sign_key sign_cert module_path module_name

  kernel_release="$(basename "$kernel_dir")"

  if module_is_available "$kernel_release"; then
    echo "ACP mic modules already available for $kernel_release; skipping build."
    return 0
  fi

  branch="$(branch_for_kernel "$kernel_release")"
  source_dir="$(source_for_branch "$branch")"
  install_dir="/usr/lib/modules/$kernel_release/extra/acp-mic"

  cp "$kernel_dir/.config" "$source_dir/.config"
  pushd "$source_dir" >/dev/null
  scripts/config --module SND_SOC_AMD_ACP_PCI
  scripts/config --module SND_SOC_AMD_MACH_COMMON
  scripts/config --module SND_SOC_AMD_LEGACY_MACH
  make olddefconfig

  make -C "$kernel_dir" \
    M="$source_dir/sound/soc/amd/acp" \
    CONFIG_SND_SOC_AMD_ACP_PCI=m \
    CONFIG_SND_SOC_AMD_MACH_COMMON=m \
    CONFIG_SND_SOC_AMD_LEGACY_MACH=m \
    modules
  popd >/dev/null

  install -d -m 0755 "$install_dir"
  for module_name in "${module_names[@]}"; do
    install -m 0644 "$source_dir/sound/soc/amd/acp/$module_name.ko" "$install_dir/$module_name.ko"
  done

  if sign_key="$(find_signing_key)" && sign_cert="$(find_signing_cert)"; then
    install -d -m 0755 /etc/pki/akmods/certs
    install -m 0644 "$sign_cert" /etc/pki/akmods/certs/kernel-module-signing.der

    for module_name in "${module_names[@]}"; do
      "$kernel_dir/scripts/sign-file" sha256 "$sign_key" "$sign_cert" "$install_dir/$module_name.ko"
    done
  elif [[ "${KERNEL_MODULE_REQUIRE_SIGNING:-0}" == "1" ]]; then
    echo "KERNEL_MODULE_REQUIRE_SIGNING=1, but no module signing key/cert was found." >&2
    return 1
  else
    echo "No module signing key/cert found; ACP mic modules will be unsigned." >&2
  fi

  for module_name in "${module_names[@]}"; do
    module_path="$install_dir/$module_name.ko"
    xz -f -T0 "$module_path"
    chmod 0644 "$module_path.xz"
  done

  depmod -a "$kernel_release"
}

mapfile -t kernel_dirs < <(find /usr/src/kernels -mindepth 1 -maxdepth 1 -type d | sort -V)

if [[ "${#kernel_dirs[@]}" -eq 0 ]]; then
  echo "No kernel-devel trees found under /usr/src/kernels." >&2
  exit 1
fi

for kernel_dir in "${kernel_dirs[@]}"; do
  build_for_kernel "$kernel_dir"
done