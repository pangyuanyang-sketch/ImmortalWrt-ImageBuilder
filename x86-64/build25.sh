#!/bin/bash
# Log file for debugging
# 目前支持少部分第三方软件apk 通过打开shell/apk-custom-packages.sh的注释来集成
source shell/apk-custom-packages.sh
echo "第三方apk软件包: $CUSTOM_PACKAGES"
LOGFILE="/tmp/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >> $LOGFILE
echo "编译固件大小为: $PROFILE MB"
echo "Include Docker: $INCLUDE_DOCKER"

echo "Create pppoe-settings"
mkdir -p  /home/build/immortalwrt/files/etc/config

# 创建pppoe配置文件 yml传入环境变量ENABLE_PPPOE等 写入配置文件 供99-custom.sh读取
cat << EOF > /home/build/immortalwrt/files/etc/config/pppoe-settings
enable_pppoe=${ENABLE_PPPOE}
pppoe_account=${PPPOE_ACCOUNT}
pppoe_password=${PPPOE_PASSWORD}
# 25.12 x86-64 默认启用 IPv6
enable_ipv6=yes
EOF

echo "cat pppoe-settings"
cat /home/build/immortalwrt/files/etc/config/pppoe-settings

if [ -z "$CUSTOM_PACKAGES" ]; then
  echo "⚪️ 未选择 任何第三方软件包"
else
  # ============= 同步第三方插件库==============
  # 同步第三方软件仓库run/apk
  echo "🔄 正在同步第三方软件仓库 Cloning run file repo..."
  git clone --depth=1 https://github.com/wukongdaily/apk.git /tmp/store-apk-repo

  # 拷贝 run/x86 下所有 run 文件和apk文件 到 extra-packages 目录
  mkdir -p /home/build/immortalwrt/extra-packages
  cp -r /tmp/store-apk-repo/run/x86/* /home/build/immortalwrt/extra-packages/

  echo "✅ Run files copied to extra-packages:"
  # 解压并拷贝apk到packages目录
  sh shell/apk-prepare-packages.sh
  ls -lah /home/build/immortalwrt/packages/
fi

# MosDNS v5：使用上游为 OpenWrt 25.12 x86-64 发布的 APK，并校验下载完整性
MOSDNS_VERSION="v5.3.4-r5"
MOSDNS_ASSET="x86_64-openwrt-25.12.tar.gz"
MOSDNS_URL="https://github.com/sbwml/luci-app-mosdns/releases/download/$MOSDNS_VERSION/$MOSDNS_ASSET"
MOSDNS_ARCHIVE="/tmp/$MOSDNS_ASSET"
MOSDNS_PACKAGE_DIR="/tmp/mosdns-packages"
MOSDNS_SHA256="76123d2e21a72a8bde89da7c45dd87b5791cc6249983386d4b4746cd5fa520bb"

echo "⬇️ 下载 MosDNS $MOSDNS_VERSION（OpenWrt 25.12 x86-64）"
curl --fail --location --retry 3 --output "$MOSDNS_ARCHIVE" "$MOSDNS_URL"
echo "$MOSDNS_SHA256  $MOSDNS_ARCHIVE" | sha256sum -c -

rm -rf "$MOSDNS_PACKAGE_DIR"
mkdir -p "$MOSDNS_PACKAGE_DIR" /home/build/immortalwrt/packages
tar -xzf "$MOSDNS_ARCHIVE" -C "$MOSDNS_PACKAGE_DIR"

for package in mosdns luci-app-mosdns luci-i18n-mosdns-zh-cn v2dat v2ray-geosite; do
  if ! compgen -G "$MOSDNS_PACKAGE_DIR/packages_ci/$package-*.apk" >/dev/null; then
    echo "❌ MosDNS 发布包缺少 $package APK"
    exit 1
  fi
done

cp -v "$MOSDNS_PACKAGE_DIR"/packages_ci/*.apk /home/build/immortalwrt/packages/
echo "✅ MosDNS APK 已加入本地软件包目录"


# 输出调试信息
echo "$(date '+%Y-%m-%d %H:%M:%S') - 开始构建固件..."

# ============= imm仓库内的插件==============
# 定义所需安装的包列表 下列插件你都可以自行删减
PACKAGES=""
PACKAGES="$PACKAGES curl"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-theme-argon"
PACKAGES="$PACKAGES luci-app-argon-config"
PACKAGES="$PACKAGES luci-i18n-argon-config-zh-cn"
#25.12
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"

# 文件管理器
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"

# MosDNS v5、LuCI 中文界面及完整运行依赖
PACKAGES="$PACKAGES mosdns luci-app-mosdns luci-i18n-mosdns-zh-cn v2dat v2ray-geoip v2ray-geosite"

# x86-64 作为纯有线路由使用，明确排除 Wi-Fi 服务、工具和内核无线模块
PACKAGES="$PACKAGES -wifi-scripts -wireless-regdb -hostapd-common -iw"
PACKAGES="$PACKAGES -kmod-cfg80211 -kmod-mac80211"

# x86-64 主路由不使用 mwan3 多 WAN/多拨，明确排除服务、LuCI 页面和中文语言包
PACKAGES="$PACKAGES -mwan3 -luci-app-mwan3 -luci-i18n-mwan3-zh-cn"

# ======== shell/apk-custom-packages.sh =======
# 合并imm仓库以外的第三方插件 暂时注释
PACKAGES="$PACKAGES $CUSTOM_PACKAGES"


# 判断是否需要编译 Docker 插件
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
    echo "Adding package: luci-i18n-dockerman-zh-cn"
fi

# 若构建openclash 则添加内核
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "✅ 已选择 luci-app-openclash，添加 openclash core"
    mkdir -p files/etc/openclash/core
    # Download clash_meta
    META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-v1.tar.gz"
    wget -qO- $META_URL | tar xOvz > files/etc/openclash/core/clash_meta
    chmod +x files/etc/openclash/core/clash_meta
    # Download GeoIP and GeoSite
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -O files/etc/openclash/GeoIP.dat
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -O files/etc/openclash/GeoSite.dat
    # Download latest openclash Client
    URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases/latest \
      | grep "browser_download_url.*apk" \
      | head -n1 \
      | cut -d '"' -f 4)
    echo "OpenClash latest apk: $URL"
    wget "$URL" -P /home/build/immortalwrt/packages/
else
    echo "⚪️ 未选择 luci-app-openclash"
fi

if echo "$PACKAGES" | grep -q "luci-app-ssr-plus"; then
    echo "✅ 已选择 luci-app-ssr-plus，添加 mihomo core"
    mkdir -p files/usr/bin
    # Download mihomo
    MIHOMO_URL="https://github.com/MetaCubeX/mihomo/releases/download/v1.19.24/mihomo-linux-amd64-compatible-v1.19.24.gz"
    mkdir -p files/usr/bin
    wget -qO- "$MIHOMO_URL" | gzip -dc > files/usr/bin/mihomo
    chmod +x files/usr/bin/mihomo
    echo "✅ 已下载 mihomo core"
    ls -lah files/usr/bin
else
    echo "⚪️ 未选择 luci-app-ssr-plus"
fi

# 构建镜像
echo "$(date '+%Y-%m-%d %H:%M:%S') - Building image with the following packages:"
echo "$PACKAGES"

make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files" ROOTFS_PARTSIZE=$PROFILE

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."
