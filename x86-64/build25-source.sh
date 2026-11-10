#!/usr/bin/env bash
# Prepare the full-source .config and the first-boot files for x86-64.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <ImmortalWrt-source-directory>" >&2
  exit 2
fi

SOURCE_DIR=$1
REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

for required in PROFILE INCLUDE_DOCKER ENABLE_STORE ENABLE_PPPOE; do
  : "${!required:?missing workflow environment variable: $required}"
done

if ! [[ "$PROFILE" =~ ^[1-9][0-9]*$ ]]; then
  echo "PROFILE must be a positive integer in MB" >&2
  exit 2
fi

mkdir -p "$REPO_DIR/custom"
printf '%s\n' "${CUSTOM_ROUTER_IP:-}" > "$REPO_DIR/custom/custom_router_ip.txt"
cat > "$REPO_DIR/custom/pppoe-settings" <<EOF
enable_pppoe=${ENABLE_PPPOE}
pppoe_account=${PPPOE_ACCOUNT:-}
pppoe_password=${PPPOE_PASSWORD:-}
enable_ipv6=yes
EOF

cd "$SOURCE_DIR"

# The old ImageBuilder config is a suitable x86 baseline.  Disable buildbot-only
# settings so this job compiles only the selected device and its required kmods.
cp "$REPO_DIR/x86-64/imm25.config" .config
sed -i \
  -e 's/^CONFIG_ALL_KMODS=y/# CONFIG_ALL_KMODS is not set/' \
  -e 's/^CONFIG_ALL_NONSHARED=y/# CONFIG_ALL_NONSHARED is not set/' \
  -e 's/^CONFIG_BUILDBOT=y/# CONFIG_BUILDBOT is not set/' \
  -e 's/^CONFIG_COLLECT_KERNEL_DEBUG=y/# CONFIG_COLLECT_KERNEL_DEBUG is not set/' \
  -e 's/^CONFIG_KERNEL_DEBUG_KERNEL=y/# CONFIG_KERNEL_DEBUG_KERNEL is not set/' \
  -e 's/^CONFIG_KERNEL_DEBUG_INFO=y/# CONFIG_KERNEL_DEBUG_INFO is not set/' \
  -e 's/^CONFIG_KERNEL_DEBUG_INFO_BTF=y/# CONFIG_KERNEL_DEBUG_INFO_BTF is not set/' \
  -e 's/^CONFIG_KERNEL_DEBUG_INFO_BTF_MODULES=y/# CONFIG_KERNEL_DEBUG_INFO_BTF_MODULES is not set/' \
  -e 's/^CONFIG_TARGET_MULTI_PROFILE=y/# CONFIG_TARGET_MULTI_PROFILE is not set/' \
  -e 's/^CONFIG_TARGET_ALL_PROFILES=y/# CONFIG_TARGET_ALL_PROFILES is not set/' \
  -e "s/^CONFIG_TARGET_ROOTFS_PARTSIZE=.*/CONFIG_TARGET_ROOTFS_PARTSIZE=${PROFILE}/" \
  .config

CUSTOM_PACKAGES=${CUSTOM_PACKAGES:-}
source "$REPO_DIR/shell/apk-custom-packages.sh"

PACKAGES=(
  curl
  luci
  luci-theme-argon
  luci-app-argon-config
  luci-i18n-argon-config-zh-cn
  luci-i18n-diskman-zh-cn
  luci-i18n-firewall-zh-cn
  luci-i18n-package-manager-zh-cn
  luci-i18n-ttyd-zh-cn
  openssh-sftp-server
  luci-i18n-filemanager-zh-cn
  mosdns
  luci-app-mosdns
  luci-i18n-mosdns-zh-cn
  v2dat
  v2ray-geoip
  v2ray-geosite
  kmod-igc
  kmod-igb
  kmod-e1000e
)

# Preserve the active third-party set from apk-custom-packages.sh.
read -r -a ACTIVE_CUSTOM_PACKAGES <<< "${CUSTOM_PACKAGES:-}"
PACKAGES+=("${ACTIVE_CUSTOM_PACKAGES[@]}")

if [[ "$INCLUDE_DOCKER" == "yes" ]]; then
  PACKAGES+=(dockerd docker luci-app-dockerman luci-i18n-dockerman-zh-cn)
fi
if [[ "$ENABLE_STORE" == "true" ]]; then
  PACKAGES+=(luci-app-store)
fi

for package in "${PACKAGES[@]}"; do
  [[ -n "$package" ]] || continue
  if [[ "$package" == -* ]]; then
    printf '# CONFIG_PACKAGE_%s is not set\n' "${package#-}" >> .config
  else
    printf 'CONFIG_PACKAGE_%s=y\n' "$package" >> .config
  fi
done

# This is a wired x86 router. Keep wireless packages out of the source build.
cat >> .config <<'EOF'
# CONFIG_PACKAGE_wifi-scripts is not set
# CONFIG_PACKAGE_wireless-regdb is not set
# CONFIG_PACKAGE_hostapd-common is not set
# CONFIG_PACKAGE_iw is not set
# CONFIG_PACKAGE_kmod-cfg80211 is not set
# CONFIG_PACKAGE_kmod-mac80211 is not set
# CONFIG_PACKAGE_mwan3 is not set
# CONFIG_PACKAGE_luci-app-mwan3 is not set
# CONFIG_PACKAGE_luci-i18n-mwan3-zh-cn is not set
EOF

make defconfig

# Never silently publish a firmware that omitted a selected application because a
# third-party feed changed its package name or failed to load.
for package in "${PACKAGES[@]}"; do
  [[ -n "$package" && "$package" != -* ]] || continue
  if ! grep -qx "CONFIG_PACKAGE_${package}=y" .config; then
    echo "Selected package is unavailable in the current source tree: ${package}" >&2
    exit 1
  fi
done

# FILES is copied by the image build.  Keep secrets only in the generated image;
# neither the source repository nor the release notes contain PPPoE credentials.
rm -rf files
mkdir -p files
cp -a "$REPO_DIR/files/." files/
mkdir -p files/etc/config
cp "$REPO_DIR/custom/custom_router_ip.txt" files/etc/config/custom_router_ip.txt
cp "$REPO_DIR/custom/pppoe-settings" files/etc/config/pppoe-settings

echo "Prepared source build configuration for x86/64, rootfs ${PROFILE} MB."
