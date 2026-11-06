#!/bin/bash

#########################################
# 0.准备内容
#########################################
set -Eeuo pipefail
trap 'rc=$?; printf "[ERROR] 第 %s 行失败，退出码 %s\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR

if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] 请使用 sudo bash $0 执行"
    exit 1
fi

#########################################
# 0.1 非交互安装设置：主脚本和子脚本共同继承
#########################################

# 禁止 debconf 弹出交互式配置界面，使用默认或已有答案
export DEBIAN_FRONTEND=noninteractive

# 为本次安装创建专用 APT 配置，不修改系统全局配置
APT_CONFIG="$(mktemp /var/tmp/b300-install-apt.XXXXXX.conf)"

cat > "$APT_CONFIG" <<'EOF'
APT::Get::Assume-Yes "true";
EOF

export APT_CONFIG

# 主脚本退出时清理临时配置
trap 'rm -f -- "$APT_CONFIG"' EXIT

LOG_DIR="/opt/ubuntu/workspace/logs"
mkdir -p "$LOG_DIR"

LOG_FILE="$LOG_DIR/b300-doca-$(hostname -s)-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1


DRIVER_DIR="/opt/ubuntu/workspace/drivers"
cd "$DRIVER_DIR"


source /etc/os-release
[[ "$ID" == "ubuntu" && "$VERSION_ID" == "24.04" ]] || {
    echo "[ERROR] 本脚本只适用于 Ubuntu 24.04"
    exit 1
}


[[ "$(dpkg --print-architecture)" == amd64 ]] || { echo "[ERROR] 需要 amd64"; exit 1; }
[[ "$(uname -r)" == 6.8.0-139-generic ]] || { echo "[ERROR] 需要内核 6.8.0-139-generic"; exit 1; }
STATE_DIR="/var/lib/b300-install"
tar -xzf b300-build-offline-6.8.0-139.tar.gz
(
    cd b300-build-offline-6.8.0-139
    bash install-offline.sh --install
)


tar -xzf b300-doca-offline-deps-3.5.0.tar.gz

dpkg -i ./doca-host_3.5.0-082000-26.07-ubuntu2404_amd64.deb

bash \
    "$DRIVER_DIR/b300-doca-offline-deps-3.5.0/install-doca-offline.sh" \
    --install

echo "[INFO] DOCA 软件包安装完成"
echo "[CHECK] 检查 DKMS 构建和驱动加载状态，必要时重启后验证"
echo -e "\e[32m$(date +%Y-%m-%d_%H-%M-%S) [INFO]: install DOCA-3.5.0 it·s OK \e[0m"



depmod -a
update-initramfs -u -k "$(uname -r)"
mkdir -p "$STATE_DIR"
cat /proc/sys/kernel/random/boot_id > "$STATE_DIR/doca-install.boot-id"
echo "[INFO] 第一阶段安装完成，请执行 sudo reboot"
echo "[ACTION] 重启后运行 02_install_gpu_stack.sh；本脚本不会自动重启"


echo -e "\e[32m$(date +%Y-%m-%d_%H-%M-%S) [INFO]: 预留 安装CX8 和CX7固件版本的安装 \e[0m"
######################################################################
cd "$DRIVER_DIR"
tar -xzf b300-ipmitool-offline-ubuntu2404.tar.gz
bash ./b300-ipmitool-offline-ubuntu2404/install-ipmitool-offline.sh --install

sudo apt-get --simulate --no-download --no-remove install ./*.deb
echo -e "\e[32m$(date +%Y-%m-%d_%H-%M-%S) [INFO]: 8秒后断电重启 \e[0m"
sleep 8
ipmitool chassis power cycle


