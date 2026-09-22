#!/bin/bash
cd "$(dirname "$0")"

if [ "$(id -u)" != "0" ]; then echo "Error:please use sudo" &&  exit 1 ;fi

if type uname >/dev/null 2>&1; then
    case "$(uname)" in
        Linux)
        ;;
        *)
            echo "[ERROR]: OS $(uname) is not supported"
            exit 1
        ;;
    esac
fi

if type uname >/dev/null 2>&1; then
    case "$(uname -m)" in
        x86_64) ;;
        *)
            echo "[ERROR]: Processor $(uname -m) is not supported"
            exit 1
        ;;
    esac
fi

if ! type lsb_release >/dev/null 2>&1; then
    . /etc/os-release
    OS_Description=$(echo "$PRETTY_NAME" )
else
    OS_Description=$(lsb_release -d -s 2>/dev/null || echo "" )
fi

if [ "$OS_Description" != "Ubuntu 24.04.4 LTS" ]; then
    echo "[ERROR]: This script is only supported on Ubuntu 24.04.4 LTS"
    exit 1
fi

if [[ "$(uname -r)" != "6.8.0-100-generic" ]]; then
    echo "[ERROR]: This script is only supported on kernel 6.8.0-100-generic"
    exit 1
fi

if [ ! -d "workspace/log" ]; then mkdir -p workspace/log; fi

enable_nvidia_persistenced() {
    local file="/etc/systemd/system/nvidia-persistenced.service"
    if [ ! -f "${file}" ]; then
        touch ${file}
        echo "[Unit]" >>${file}
        echo "Description=NVIDIA Persistence Daemon" >>${file}
        echo "After=local-fs.target" >>${file}
        echo "" >>${file}
        echo '[Service]' >>${file}
        echo "Type=forking" >>${file}
        echo 'ExecStart=/usr/bin/nvidia-persistenced --persistence-mode --verbose' >>${file}
        echo "Restart=always" >>${file}
        echo "" >>${file}
        echo '[Install]' >>${file}
        echo 'WantedBy=multi-user.target' >>${file}
    else
        echo -e  "\033[32m[WARN]: nvidia-persistenced.service exist!\033[0m"
    fi

    systemctl daemon-reload
    systemctl enable nvidia-persistenced.service
    systemctl reset-failed nvidia-persistenced.service
    systemctl restart nvidia-persistenced.service
}

hostname=$(hostname)
timestamp=$(date +%Y-%m-%d_%H-%M-%S)
install_log="./workspace/log/${hostname}_install_${timestamp}.log"

# install common deb
echo -e "\033[32m[INFO]: Install deb\033[0m"
if command -v pigz > /dev/null 2>&1; then
    echo "[INFO]: Use pigz"
    tar --use-compress-program=pigz -xf workspace/drivers/common.tgz >/dev/null &
else
    tar -xzf workspace/drivers/common.tgz > /dev/null &
fi
pid=$!
while ps -p $pid >/dev/null; do
    echo -n "*"
    sleep 2
done

echo
echo -e "\e[32m$(date +%Y-%m-%d_%H-%M-%S) Start install deb------\e[0m"  >> $install_log
apt-get purge -y unattended-upgrades                    >> $install_log
dpkg -i ./common/lib/*.deb                              >> $install_log
dpkg -i ./common/tools/*.deb                            >> $install_log
dpkg -i ./common/docker/*.deb                           >> $install_log
dpkg -i ./common/nfs/*.deb                              >> $install_log
echo -e "\e[32m$(date +%Y-%m-%d_%H-%M-%S) Finish install deb------\e[0m"  >> $install_log
rm -rf common/ &

if command -v pigz > /dev/null 2>&1; then
    tar --use-compress-program=pigz -xf workspace/drivers/nvidia.tgz >/dev/null &
else
    tar -xzf workspace/drivers/nvidia.tgz > /dev/null &
fi
pid=$!
while ps -p $pid > /dev/null; do
    echo -n "*"
    sleep 2
done
echo

nvidia_driver_installer="./nvidia/NVIDIA-Linux-x86_64-580.173.02.run"
nvidia_driver_version="580.173.02"
cuda_installer="./nvidia/cuda_13.0.3_580.126.20_linux.run"

if [ ! -f "${nvidia_driver_installer}" ]; then
    echo "[ERROR]: NVIDIA driver installer not found: ${nvidia_driver_installer}"
    exit 1
fi

if [ ! -f "${cuda_installer}" ]; then
    echo "[ERROR]: CUDA installer not found: ${cuda_installer}"
    exit 1
fi

# The .run files in nvidia.tgz are archived without executable permissions.
if ! chmod +x "${nvidia_driver_installer}" "${cuda_installer}"; then
    echo "[ERROR]: Failed to make NVIDIA and CUDA installers executable"
    exit 1
fi

# install DOCA
if lspci | grep -i "Mellanox"; then
    echo -e  "\033[32m[INFO]: Install DOCA\033[0m"
    echo -e "\e[32m$(date +%Y-%m-%d_%H-%M-%S) Start install DOCA------\e[0m"  >> $install_log
    dpkg -i ./nvidia/doca/doca-host*.deb >> $install_log
    apt-get update >> $install_log
    echo "" >> $install_log
    echo "[INFO] finish update" >> $install_log
    apt-get install -y doca-extra >> $install_log
    apt-get install -y doca-all >> $install_log
    apt-get install -y mlnx-nfsrdma-dkms mlnx-nvme-dkms fwctl-dkms >> $install_log
    echo "REMOVE DOCA-HOST" >> $install_log
    apt-get remove -y doca-host >> $install_log
    apt-get purge -y doca-host >> $install_log
    echo -e "\e[32m$(date +%Y-%m-%d_%H-%M-%S) Finish install DOCA------\e[0m"  >> $install_log
else
    echo -e "\033[31m\033[1mno Infiniband controller device\033[0m"  >> $install_log
fi

# Install NVIDIA Driver
if lspci | grep -i "3D controller: NVIDIA"; then

    # install GPU driver
    echo -e  "\033[32m[INFO]: Install NVIDIA 3D controller Driver\033[0m"
    echo -e "\e[32m$(date +%Y-%m-%d_%H-%M-%S) Start install NVIDIA 3D controller Driver------\e[0m"  >> $install_log
    if nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | grep -qx "${nvidia_driver_version}"; then
        echo "[INFO]: NVIDIA driver ${nvidia_driver_version} is already operational; skipping reinstall" | tee -a "${install_log}"
    else
        touch /etc/modprobe.d/nouveau-blacklist.conf
        echo "blacklist nouveau" |  tee /etc/modprobe.d/nouveau-blacklist.conf
        echo "options nouveau modeset=0" |  tee -a /etc/modprobe.d/nouveau-blacklist.conf
        update-initramfs -u >> $install_log
        if ! "${nvidia_driver_installer}" --dkms -q -s -m=kernel-open >> "${install_log}" 2>&1; then
            echo "[ERROR]: NVIDIA driver installation failed. See ${install_log}" >&2
            exit 1
        fi
    fi
    echo -e "\e[32m$(date +%Y-%m-%d_%H-%M-%S) Finish install NVIDIA 3D controller Driver------\e[0m"  >> $install_log

    # Load nvidia_peermem module
    echo -e  "\033[32m[INFO]: Load nvidia_peermem module\033[0m"
    echo -e "\e[32m$(date +%Y-%m-%d_%H-%M-%S) Load nvidia_peermem module------\e[0m"  >> $install_log
    if [ ! -f /etc/modules-load.d/nvidia_peermem.conf ]; then
        modprobe nvidia_peermem
        echo "nvidia_peermem" | tee /etc/modules-load.d/nvidia_peermem.conf
    else
        echo -e  "\033[32m[WARN]: /etc/modules-load.d/nvidia_peermem.conf exist!\033[0m"
    fi

    # Enable nvidia-persistenced
    echo -e  "\033[32m[INFO]: Enable nvidia-persistenced\033[0m"
    echo -e "\e[32m$(date +%Y-%m-%d_%H-%M-%S) Enable nvidia-persistenced------\e[0m"  >> $install_log
    enable_nvidia_persistenced

    # Install CUDA
    echo -e "\033[32m[INFO]: Install CUDA\033[0m"
    echo -e "\e[32m$(date +%Y-%m-%d_%H-%M-%S) Start install CUDA------\e[0m"  >> $install_log
    if ! "${cuda_installer}" --silent --toolkit >> "${install_log}" 2>&1; then
        echo "[ERROR]: CUDA Toolkit installation failed. See ${install_log}" >&2
        exit 1
    fi
    # add CUDA PATH to /etc/profile
    if ! grep -qF 'export PATH=$PATH:/usr/local/cuda/bin' /etc/profile; then
        echo 'export PATH=$PATH:/usr/local/cuda/bin' >> /etc/profile
    fi
    if ! grep -qF 'export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/usr/local/cuda/lib64' /etc/profile; then
        echo 'export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/usr/local/cuda/lib64' >> /etc/profile
    fi
    # add CUDA PATH to /root/.bashrc
    if ! grep -qF 'export PATH=$PATH:/usr/local/cuda/bin' /root/.bashrc; then
        echo 'export PATH=$PATH:/usr/local/cuda/bin' >> /root/.bashrc
    fi
    if ! grep -qF 'export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/usr/local/cuda/lib64' /root/.bashrc; then
        echo 'export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/usr/local/cuda/lib64' >> /root/.bashrc
    fi
    source  /etc/profile
    echo -e "\e[32m$(date +%Y-%m-%d_%H-%M-%S) Finish install CUDA------\e[0m"  >> $install_log

    # Install nv docker
    echo -e "\033[32m[INFO]: Install NVIDIA docker\033[0m"
    echo -e "\e[32m$(date +%Y-%m-%d_%H-%M-%S) Start Install nv docker------\e[0m"  >> $install_log
    dpkg -i ./nvidia/docker/*.deb >> $install_log
    nvidia-ctk runtime configure --runtime=docker >> $install_log
    systemctl restart docker >> $install_log
    echo -e "\e[32m$(date +%Y-%m-%d_%H-%M-%S) Finish Install nv docker------\e[0m"  >> $install_log

    # install nvlsm
    echo "休息 3秒"
    sleep 3
    echo -e "\033[32m[INFO]: Install nvlsm\033[0m"
    dpkg -i ./nvidia/nvlsm/*.deb
    if ! modprobe ib_umad; then
        echo "[ERROR]: Failed to load ib_umad. NVIDIA Fabric Manager cannot start." >&2
        exit 1
    fi
    echo "ib_umad" | tee /etc/modules-load.d/ib_umad.conf
    echo -e "\033[32m[INFO]: Finish nvlsm\033[0m"

    # Install NVIDIA fabricmanager
    echo -e "\033[32m[INFO]: Install NVIDIA fabricmanager\033[0m"
    echo -e "\e[32m$(date +%Y-%m-%d_%H-%M-%S) Install NVIDIA fabricmanager------\e[0m"  >> $install_log
    dpkg -i ./nvidia/nv-fm/*.deb >> $install_log
    systemctl enable nvidia-fabricmanager.service >> $install_log
    systemctl restart nvidia-fabricmanager.service  >> $install_log

    # Install DCGM
    echo -e "\033[32m[INFO]: Install NVIDIA DCGM\033[0m"
    echo -e "\e[32m$(date +%Y-%m-%d_%H-%M-%S) Install NVIDIA DCGM------\e[0m"  >> $install_log
    dpkg -i ./nvidia/dcgm/*.deb >> $install_log
    systemctl --now enable nvidia-dcgm >> $install_log

    # Install NCCL
    echo -e "\033[32m[INFO]: Install NVIDIA NCCL\033[0m"
    echo -e "\e[32m$(date +%Y-%m-%d_%H-%M-%S) Install NVIDIA NCCL------\e[0m"  >> $install_log
    dpkg -i ./nvidia/nccl/*.deb >> $install_log

    # Install cudnn
    echo -e "\033[32m[INFO]: Install NVIDIA cuDNN\033[0m"
    echo -e "\e[32m$(date +%Y-%m-%d_%H-%M-%S) Install NVIDIA cuDNN------\e[0m"  >> $install_log
    dpkg -i ./nvidia/cudnn/*.deb >> $install_log

    rm -rf nvidia/
else
    echo  "[INFO]: no nvidia 3D controller device" >> $install_log
fi

set_release() {
    current_datetime=$(date +%Y-%m-%d-%H-%M-%S)
    echo "PODsys_Version=\"2404-bxx\"" > /etc/podsys-release
    echo "PODsys_Deployment_DATE=\"$current_datetime\"" >> /etc/podsys-release
}

set_limit() {
    local pattern="$1"
    content=$(<"/etc/security/limits.conf")
    if ! echo "$content" | grep -qF "$pattern"; then
        echo "$pattern" >> /etc/security/limits.conf
    fi
}

# set_limits
set_limit "root soft nofile 65536"
set_limit "root hard nofile 65536"
set_limit "* soft nofile 65536"
set_limit "* hard nofile 65536"
set_limit "* soft stack unlimited"
set_limit "* soft nproc unlimited"
set_limit "* hard stack unlimited"
set_limit "* hard nproc unlimited"
set_limit "* soft core 1048576"
set_limit "* hard core 1048576"
set_limit "root soft core 1048576"
set_limit "root hard core 1048576"

# iommu_passthrough
CFG_FILE="/etc/default/grub.d/iommu_passthrough.cfg"
LINE='GRUB_CMDLINE_LINUX="$GRUB_CMDLINE_LINUX iommu.passthrough=1"'

# make sure the directory exists
mkdir -p /etc/default/grub.d

# check if the line exists
if [ ! -f "$CFG_FILE" ] || ! grep -qF "$LINE" "$CFG_FILE"; then
    echo "$LINE" >> "$CFG_FILE"
    update-grub
else
    echo -e "[WARN]: Configuration already exists. Skipping."
fi

# set release
set_release

# Check if user entered yes
read -p "Do you want to reboot now? Enter yes or no: " choice
if [ "$choice" = "yes" ]; then
    reboot
else
    echo -e "\033[32m[WARN]: Please restart to apply the drivers.\033[0m"
fi

# apt-get -s --fix-broken install
# apt-get --fix-broken install
# dpkg --configure -a
# apt-get check
# dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Version}\n' libibumad3 nvlsm
#