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

LOG_FILE="$LOG_DIR/b300-gpu-stack-$(hostname -s)-$(date +%Y%m%d-%H%M%S).log"
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

SKIP_NVIDIA_DRIVER=0
RESUME_FROM_NVLSM=0
case "${1:-}" in
    "") ;;
    --skip-nvidia-driver) SKIP_NVIDIA_DRIVER=1 ;;
    --resume-from-nvlsm) SKIP_NVIDIA_DRIVER=1; RESUME_FROM_NVLSM=1 ;;
    *) echo "用法：sudo bash $0 [--skip-nvidia-driver | --resume-from-nvlsm]"; exit 1 ;;
esac

if [[ -f "$STATE_DIR/doca-install.boot-id" ]] &&
   [[ "$(cat "$STATE_DIR/doca-install.boot-id")" == "$(cat /proc/sys/kernel/random/boot_id)" ]]; then
    echo "[ERROR] 第一阶段后尚未重启，请先 sudo reboot"
    exit 1
fi

[[ "$(dpkg-query -W -f='${Status}' doca-all 2>/dev/null)" == "install ok installed" ]] || {
    echo "[ERROR] doca-all 未正确安装"; exit 1;
}
test -f "/lib/modules/$(uname -r)/build/Makefile"
modprobe mlx5_ib
modprobe ib_umad
for module in ib_core mlx5_core mlx5_ib; do
    loaded="$(cat "/sys/module/$module/srcversion")"
    disk="$(modinfo -F srcversion "$module")"
    echo "[INFO] $module 当前加载=$loaded 磁盘=$disk"
    if [[ -z "$loaded" || -z "$disk" || "$loaded" != "$disk" ]]; then
        echo "[ERROR] 模块不一致，请检查 initramfs 并重启"
        exit 1
    fi
done
for symbol in ib_register_peer_memory_client ib_unregister_peer_memory_client; do
    if ! awk -v symbol="$symbol" '$3 == symbol { found=1 } END { exit !found }' /proc/kallsyms; then
        echo "[ERROR] 当前内核缺少 $symbol，停止安装"
        exit 1
    fi
done

# 自动检测已有驱动；本套 FM 要求 NVIDIA 610.57.04。
EXPECTED_NVIDIA_VERSION="610.57.04"
DISK_NVIDIA_VERSION="$(modinfo -F version nvidia 2>/dev/null || true)"
if [[ -n "$DISK_NVIDIA_VERSION" ]] || command -v nvidia-smi >/dev/null 2>&1; then
    if [[ "$DISK_NVIDIA_VERSION" != "$EXPECTED_NVIDIA_VERSION" ]]; then
        echo "[ERROR] 检测到已有或不完整的 NVIDIA 安装，磁盘模块版本：${DISK_NVIDIA_VERSION:-未找到}"
        echo "[ACTION] 本套 FM 需要 $EXPECTED_NVIDIA_VERSION，请先处理版本；不自动覆盖已有驱动"
        exit 1
    fi
    modprobe nvidia
    LOADED_NVIDIA_VERSION="$(cat /sys/module/nvidia/version)"
    if [[ "$LOADED_NVIDIA_VERSION" != "$EXPECTED_NVIDIA_VERSION" ]]; then
        echo "[ERROR] 已加载 NVIDIA $LOADED_NVIDIA_VERSION 与目标版本不一致，请先重启或排查"
        exit 1
    fi
    if ! GPU_DRIVER_VERSIONS="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader)"; then
        echo "[ERROR] 已安装 NVIDIA 驱动，但 nvidia-smi 不正常；停止，不重复安装"
        exit 1
    fi
    if [[ -z "$GPU_DRIVER_VERSIONS" ]] || ! awk -v expected="$EXPECTED_NVIDIA_VERSION" '{gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if ($0 != expected) bad=1} END {exit bad}' <<< "$GPU_DRIVER_VERSIONS"; then
        echo "[ERROR] GPU 报告的驱动版本不符合 $EXPECTED_NVIDIA_VERSION"
        exit 1
    fi
    SKIP_NVIDIA_DRIVER=1
    echo "[INFO] NVIDIA $EXPECTED_NVIDIA_VERSION 已安装且可用，自动跳过驱动安装器"
elif [[ "$SKIP_NVIDIA_DRIVER" == 1 ]]; then
    echo "[ERROR] 指定了跳过驱动，但当前未检测到可用的 NVIDIA 安装"
    exit 1
fi

enable_nvidia_persistenced() {
    local file="/etc/systemd/system/nvidia-persistenced.service"

    systemctl daemon-reload

    if systemctl cat nvidia-persistenced.service >/dev/null 2>&1; then
        echo "[INFO] 已存在 nvidia-persistenced 服务，沿用现有定义"
        return 0
    fi

    if [[ ! -x /usr/bin/nvidia-persistenced ]]; then
        echo "[ERROR] 未找到 /usr/bin/nvidia-persistenced"
        return 1
    fi

cat > "$file" <<'EOF'
    [Unit]
    Description=NVIDIA Persistence Daemon
    After=local-fs.target

    [Service]
    Type=forking
    ExecStart=/usr/bin/nvidia-persistenced --persistence-mode --verbose
    Restart=on-failure
    RestartSec=5

    [Install]
    WantedBy=multi-user.target
EOF

    chmod 0644 "$file"
    systemctl daemon-reload
    echo "[INFO] nvidia-persistenced 服务定义已创建"
}

enable_nvidia_peermem() {
    local service_file="/etc/systemd/system/load-nvidia-peermem.service"
    local modprobe_bin

    modprobe_bin="$(command -v modprobe)" || {
        echo "[ERROR] 未找到 modprobe，请先安装 kmod"
        return 1
    }

    # 检查当前内核是否具有该模块
    if ! modinfo nvidia_peermem >/dev/null 2>&1; then
        echo "[ERROR] 当前内核下找不到 nvidia_peermem 模块"
        echo "[ERROR] 请检查 NVIDIA 驱动、DOCA 安装及当前内核版本"
        return 1
    fi

    # 备份旧定义，确保旧版服务也能更新为 oneshot
    if [[ -f "$service_file" ]]; then
        cp -a -- "$service_file" \
            "${service_file}.bak.$(date +%Y%m%d-%H%M%S).$$"
    fi

    cat > "$service_file" <<EOF
[Unit]
Description=Load NVIDIA peer memory module
After=systemd-modules-load.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${modprobe_bin} nvidia_peermem

[Install]
WantedBy=multi-user.target
EOF

    chmod 0644 "$service_file"

    systemctl daemon-reload
    systemctl enable load-nvidia-peermem.service

    # restart 确保现有服务也采用新定义执行加载检查
    if ! systemctl restart load-nvidia-peermem.service; then
        echo "[ERROR] nvidia_peermem 加载失败"
        journalctl -u load-nvidia-peermem.service \
            -b -n 80 --no-pager || true
        return 1
    fi

    # 服务启动成功后，再确认模块确实已加载
    if [[ ! -d /sys/module/nvidia_peermem ]]; then
        echo "[ERROR] 服务执行完成，但未检测到已加载的 nvidia_peermem"
        return 1
    fi

    echo "[INFO] nvidia_peermem 已加载，并已设置开机加载"
}

if [[ "$RESUME_FROM_NVLSM" == 0 ]]; then
# 2.0 install NVIDIA-Linux-x86_64-610.57.04.run
##############################################
if [[ "$SKIP_NVIDIA_DRIVER" == 0 ]]; then
sh ./NVIDIA-Linux-x86_64-610.57.04.run \
    --accept-license \
    --no-questions \
    --no-install-compat32-libs \
    --ui=none \
    --disable-nouveau \
    --kernel-module-type=open
fi


echo -e "\033[32m[INFO]: Load nvidia_peermem module\033[0m"
enable_nvidia_peermem
echo -e "\033[32m[INFO]: Enable nvidia-persistenced\033[0m"
enable_nvidia_persistenced
systemctl daemon-reload

systemctl enable nvidia-persistenced.service
systemctl start nvidia-persistenced.service

systemctl status load-nvidia-peermem.service --no-pager -l
lsmod | grep nvidia_peermem
echo -e "\e[32m$(date +%Y-%m-%d_%H-%M-%S) [INFO]: install NVIDIA-Linux-x86_64-610.57.04.run it·s OK \e[0m"

###############################################
# 3.0 install cuda-13.3.1
###############################################
sh ./cuda_13.3.1_610.43.02_linux.run \
    --silent \
    --toolkit

/usr/local/cuda-13.3/bin/nvcc --version
echo -e "\e[32m$(date +%Y-%m-%d_%H-%M-%S) [INFO]: install cuda-13.3.1 it·s OK \e[0m"


fi

# 将 CUDA PATH 添加到 /etc/profile；重复执行不重复追加。
# /usr/local/cuda 应指向本次使用的 CUDA 安装目录。
if [[ ! -x /usr/local/cuda/bin/nvcc ]]; then
    echo "[ERROR] /usr/local/cuda/bin/nvcc 不存在，请检查 /usr/local/cuda 软链接"
    exit 1
fi
if ! grep -Fxq 'export PATH=$PATH:/usr/local/cuda/bin' /etc/profile; then
    echo 'export PATH=$PATH:/usr/local/cuda/bin' >> /etc/profile
fi

# 使当前安装脚本生效；不在安装过程中加载整个 /etc/profile。
export PATH=$PATH:/usr/local/cuda/bin
nvcc --version
echo "[INFO] CUDA PATH 已添加到 /etc/profile"
echo "[ACTION] 当前终端请执行 source /etc/profile，或重新登录"

# 4.0 离线安装 NVLSM
##############################################

cd "$DRIVER_DIR"

NVLSM_DEB="$DRIVER_DIR/nvlsm_2025.12.211-1_amd64.deb"
test -f "$NVLSM_DEB"

# 禁止下载，先检查本地包和当前系统能否满足依赖
apt-get --simulate --no-download --no-remove \
    install "$NVLSM_DEB"

# 依赖满足后安装；缺少依赖则停止
# 直接用 dpkg 安装本地文件，避免 APT --no-download 的本地路径错误。
# dpkg 不联网；缺依赖时退出，不强制忽略依赖。
dpkg -i "$NVLSM_DEB"

dpkg-query -W -f='${Package}\t${Version}\t${Status}\n' nvlsm

test -x /opt/nvidia/nvlsm/sbin/nvlsm
test -f /usr/share/nvidia/nvlsm/nvlsm.conf

echo "[INFO] NVLSM 软件包安装完成，后续由 Fabric Manager 服务启动"
echo -e "\e[32m$(date +%Y-%m-%d_%H-%M-%S) [INFO]: install nvlsm_2025.12.211-1_amd64.deb  it·s OK \e[0m"


###############################################
# 5.0 install nvidia-fabricmanager_610.57.04
##############################################
cd "$DRIVER_DIR"
dpkg -i \
    ./nvidia-fabricmanager_610.57.04-1ubuntu1_amd64.deb \
    ./nvidia-fabricmanager-dev_610.57.04-1ubuntu1_amd64.deb

modprobe mlx5_ib
modprobe ib_umad

test -x /opt/nvidia/nvlsm/sbin/nvlsm
test -f /usr/share/nvidia/nvlsm/nvlsm.conf
command -v ibstat >/dev/null

systemctl daemon-reload
systemctl enable nvidia-fabricmanager

if ! systemctl restart nvidia-fabricmanager; then
    journalctl -u nvidia-fabricmanager -b -n 100 --no-pager
    exit 1
fi

systemctl is-active --quiet nvidia-fabricmanager

nvidia-smi --query-gpu=name,driver_version --format=csv,noheader

nvidia-smi topo -m

echo "[CHECK] 请确认全部 GPU 驱动为 610.57.04"
echo "[CHECK] 请确认全部 GPU 的 Fabric State=Completed、Status=Success"
echo -e "\e[32m$(date +%Y-%m-%d_%H-%M-%S) [INFO]: install NVIDIA Driver-610.57.04 it·s OK \e[0m"


###############################################
# 6.0 install NCCL 2.30.7
##############################################
cd "$DRIVER_DIR"
dpkg -i ./nccl-local-repo-ubuntu2404-2.30.7-cuda13.3_1.0-1_amd64.deb

NCCL_REPO="/var/nccl-local-repo-ubuntu2404-2.30.7-cuda13.3"

apt-get --simulate --no-download --no-remove install \
    "$NCCL_REPO/libnccl2_2.30.7-1+cuda13.3_amd64.deb" \
    "$NCCL_REPO/libnccl-dev_2.30.7-1+cuda13.3_amd64.deb"

dpkg -i \
    "$NCCL_REPO/libnccl2_2.30.7-1+cuda13.3_amd64.deb" \
    "$NCCL_REPO/libnccl-dev_2.30.7-1+cuda13.3_amd64.deb"

ldconfig

dpkg-query -W -f='${Package}\t${Version}\t${Status}\n' \
    libnccl2 libnccl-dev

# 系统登录配置不保证兼容 nounset；只在加载 profile 时暂时关闭 -u。
set +u
source /etc/profile
set -u

echo "[INFO] 第二阶段脚本已执行完成；请继续检查 GPU Fabric 并执行 CUDA/NCCL 实测"


