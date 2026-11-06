#!/bin/bash

#!/bin/bash
set -Ee -o pipefail

trap 'rc=$?; echo "[ERROR] 第 $LINENO 行失败，退出码 $rc" >&2; exit "$rc"' ERR

if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] 请使用 sudo bash 执行此脚本"
    exit 1
fi

DRIVER_DIR=/opt/ubuntu/workspace/drivers
WORK_DIR=/opt/ubuntu

if [ ! -d "$DRIVER_DIR" ]; then
    echo "[ERROR] 驱动目录不存在：$DRIVER_DIR"
    exit 1
fi

tar -xzf $DRIVER_DIR/argparse-3.2.tar.gz -C /opt/ubuntu/

################################################
# 准备源码目录，支持重复执行
################################################

for name in nccl-tests nvbandwidth; do
    if [ -d "$WORK_DIR/$name" ]; then
        echo "[INFO] 使用已有源码目录：$WORK_DIR/$name"
    elif [ -d "$DRIVER_DIR/$name" ]; then
        mv -T -- "$DRIVER_DIR/$name" "$WORK_DIR/$name"
    else
        echo "[ERROR] 找不到源码目录：$name"
        echo "[ERROR] 请放到 $DRIVER_DIR 或 $WORK_DIR"
        exit 1
    fi
done

################################################
# 准备 argparse 本地源码
################################################

if [ -f "$WORK_DIR/argparse-3.2/CMakeLists.txt" ] &&
   [ -f "$WORK_DIR/argparse-3.2/include/argparse/argparse.hpp" ]; then
    echo "[INFO] 使用已有 argparse-3.2 源码"
else
    if [ -f "$WORK_DIR/argparse-3.2.tar.gz" ]; then
        ARGPARSE_ARCHIVE="$WORK_DIR/argparse-3.2.tar.gz"
    elif [ -f "$DRIVER_DIR/argparse-3.2.tar.gz" ]; then
        ARGPARSE_ARCHIVE="$DRIVER_DIR/argparse-3.2.tar.gz"
    else
        echo "[ERROR] 找不到 argparse-3.2.tar.gz"
        exit 1
    fi

    tar -xzf "$ARGPARSE_ARCHIVE" -C "$WORK_DIR"

    test -f "$WORK_DIR/argparse-3.2/CMakeLists.txt"
    test -f "$WORK_DIR/argparse-3.2/include/argparse/argparse.hpp"
fi

################################################
# 从本地离线仓库安装 CMake
# 暂不安装 libpci-dev，避免 libudev 版本冲突
################################################

install_cmake_offline() (
    set -Ee -o pipefail

    BUNDLE_DIR="$DRIVER_DIR/b300-cmake-pci-offline-ubuntu2404"
    BUNDLE_ARCHIVE="$DRIVER_DIR/b300-cmake-pci-offline-ubuntu2404.tar.gz"

    if [ ! -f "$BUNDLE_DIR/debs/Packages" ]; then
        if [ ! -f "$BUNDLE_ARCHIVE" ]; then
            echo "[ERROR] 找不到 CMake 离线包：$BUNDLE_ARCHIVE"
            exit 1
        fi

        tar -xzf "$BUNDLE_ARCHIVE" -C "$DRIVER_DIR"
    fi

    REPO="$BUNDLE_DIR/debs"

    if [ ! -f "$REPO/Packages" ]; then
        echo "[ERROR] 找不到离线仓库索引：$REPO/Packages"
        exit 1
    fi

    STATE="$(mktemp -d /var/tmp/b300-cmake-only.XXXXXX)"
    trap 'rm -rf -- "$STATE"' EXIT

    mkdir -p "$STATE/lists/partial" "$STATE/archives/partial"

    printf 'deb [trusted=yes] file:%s ./\n' "$REPO" \
        > "$STATE/local.list"

    OPTS=(
        -o "Dir::Etc::sourcelist=$STATE/local.list"
        -o "Dir::Etc::sourceparts=-"
        -o "Dir::State::lists=$STATE/lists"
        -o "Dir::Cache::archives=$STATE/archives/"
        -o "Dir::Cache::pkgcache=$STATE/pkgcache.bin"
        -o "Dir::Cache::srcpkgcache=$STATE/srcpkgcache.bin"
        -o "APT::Sandbox::User=root"
    )

    export DEBIAN_FRONTEND=noninteractive

    echo "[INFO] 刷新 CMake 本地仓库索引"
    apt-get "${OPTS[@]}" \
        -o APT::Update::Error-Mode=any update

    echo "[INFO] 模拟安装 CMake"
    apt-get "${OPTS[@]}" \
        --simulate --no-install-recommends --no-remove \
        install cmake

    echo "[INFO] 正式安装 CMake"
    apt-get "${OPTS[@]}" \
        -y --no-install-recommends --no-remove \
        install cmake

    /usr/bin/cmake --version

    dpkg-query -W \
        -f='${Package}\t${Version}\t${Status}\n' \
        cmake cmake-data

    echo "[INFO] CMake 离线安装完成"
)

# 直接调用：失败后由脚本顶部的错误处理立即退出
install_cmake_offline

cd "$WORK_DIR"


###########################
# install nccl-test
##########################
cd /opt/ubuntu/

export CUDA_HOME=/usr/local/cuda-13.3
export MPI_HOME=/usr/mpi/gcc/openmpi-5.0.10rc2.2608140153

# CUDA 和 MPI 都优先使用指定版本
export PATH="$CUDA_HOME/bin:$MPI_HOME/bin:$PATH"

export LD_LIBRARY_PATH="$CUDA_HOME/lib64:$MPI_HOME/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# 清除之前人为添加的库和链接参数
unset LIBRARIES
unset NVLDFLAGS

# 检查指定的编译环境
test -x "$CUDA_HOME/bin/nvcc" || {
    echo "[ERROR] 找不到 CUDA nvcc"
    exit 1
}

test -x "$MPI_HOME/bin/mpicxx" || {
    echo "[ERROR] 找不到 DOCA MPI 的 mpicxx"
    exit 1
}

"$CUDA_HOME/bin/nvcc" --version
"$MPI_HOME/bin/mpicxx" --showme:version
"$MPI_HOME/bin/mpirun" --version

cd /opt/ubuntu/nccl-tests || exit 1

make clean

make -j"$(nproc)" \
    MPI=1 \
    NAME_SUFFIX= \
    MPI_HOME="$MPI_HOME" \
    CUDA_HOME="$CUDA_HOME" \
    CXX="$MPI_HOME/bin/mpicxx"


# 检查编译结果
NCCL_TEST_BIN=/opt/ubuntu/nccl-tests/build/all_reduce_perf

if [ ! -x "$NCCL_TEST_BIN" ]; then
    echo "[ERROR] 未生成 NCCL Tests 程序：$NCCL_TEST_BIN"
    exit 1
fi

NCCL_LDD_OUTPUT="$(ldd "$NCCL_TEST_BIN")"
printf '%s\n' "$NCCL_LDD_OUTPUT"

if grep -q 'not found' <<< "$NCCL_LDD_OUTPUT"; then
    echo "[ERROR] NCCL Tests 存在缺失的动态库"
    exit 1
fi

ls -lh /opt/ubuntu/nccl-tests/build/
echo "[INFO] NCCL Tests 编译完成，动态库检查通过"


# =========================================================
# 编译 nvbandwidth：B300 本机、CUDA 13.3、单机、离线
# 使用子 Shell，避免改变安装脚本后续部分的 Shell 设置
# =========================================================
(
    set -euo pipefail

    echo -e "\033[32m[INFO]: Build nvbandwidth \033[0m"

    export CUDA_HOME=/usr/local/cuda-13.3
    export PATH="$CUDA_HOME/bin:/usr/bin:$PATH"
    export LD_LIBRARY_PATH="$CUDA_HOME/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

    NVBANDWIDTH_SRC=/opt/ubuntu/nvbandwidth
    NVBANDWIDTH_BUILD="$NVBANDWIDTH_SRC/build"
    ARGPARSE_SRC=/opt/ubuntu/argparse-3.2

    # 检查编译工具
    for tool in cmake make g++; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "[ERROR] 缺少编译工具：$tool"
            exit 1
        fi
    done

    if [ ! -x "$CUDA_HOME/bin/nvcc" ]; then
        echo "[ERROR] 找不到 CUDA 编译器：$CUDA_HOME/bin/nvcc"
        exit 1
    fi

    if [ ! -f "$NVBANDWIDTH_SRC/CMakeLists.txt" ]; then
        echo "[ERROR] 找不到 nvbandwidth 源码：$NVBANDWIDTH_SRC"
        exit 1
    fi

    if [ ! -f "$ARGPARSE_SRC/CMakeLists.txt" ] ||
       [ ! -f "$ARGPARSE_SRC/include/argparse/argparse.hpp" ]; then
        echo "[ERROR] 缺少完整的 argparse v3.2 本地源码：$ARGPARSE_SRC"
        exit 1
    fi

    # native 架构检测需要当前 GPU 和驱动可用
    nvidia-smi
    "$CUDA_HOME/bin/nvcc" --version
    cmake --version

    # --fresh 重建 CMake 配置，避免沿用之前的架构、编译器等缓存
    cmake --fresh \
        -S "$NVBANDWIDTH_SRC" \
        -B "$NVBANDWIDTH_BUILD" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CUDA_COMPILER="$CUDA_HOME/bin/nvcc" \
        -DCMAKE_CXX_COMPILER=/usr/bin/g++ \
        -DCMAKE_CUDA_ARCHITECTURES=native \
        -DMULTINODE=OFF \
        -DFETCHCONTENT_SOURCE_DIR_ARGPARSE="$ARGPARSE_SRC" \
        -DARGPARSE_BUILD_TESTS=OFF \
        -DARGPARSE_BUILD_SAMPLES=OFF

    cmake --build "$NVBANDWIDTH_BUILD" \
        --parallel "$(nproc)"

    NVBANDWIDTH_BIN="$NVBANDWIDTH_BUILD/nvbandwidth"

    if [ ! -x "$NVBANDWIDTH_BIN" ]; then
        echo "[ERROR] 未找到可执行程序：$NVBANDWIDTH_BIN"
        exit 1
    fi

    "$NVBANDWIDTH_BIN" --help
    "$NVBANDWIDTH_BIN" -l

    echo "[INFO] nvbandwidth 编译完成：$NVBANDWIDTH_BIN"
)



################################################
# Install perftest with CUDA GPUDirect support
################################################
#
## 编译、配置或安装失败时立即停止
#set -e
#
#echo -e "\033[32m[INFO]: Install perftest \033[0m"
#
#(
#    export CUDA_HOME=/usr/local/cuda-13.3
#    export PATH="$CUDA_HOME/bin:/usr/bin:$PATH"
#    export LD_LIBRARY_PATH="$CUDA_HOME/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
#
#    PERFTEST_SRC=/opt/ubuntu/perftest
#
#    if [ "$(id -u)" -ne 0 ]; then
#        echo "[ERROR] 请使用 sudo bash 执行安装脚本"
#        exit 1
#    fi
#
#    # 检查基础构建工具
#    for tool in gcc g++ make autoconf automake libtoolize pkg-config; do
#        if ! command -v "$tool" >/dev/null 2>&1; then
#            echo "[ERROR] 缺少构建工具：$tool，请先安装对应离线依赖"
#            exit 1
#        fi
#    done
#
#    if [ ! -f "$CUDA_HOME/include/cuda.h" ]; then
#        echo "[ERROR] 找不到 CUDA 头文件：$CUDA_HOME/include/cuda.h"
#        exit 1
#    fi
#
#    if [ ! -f "$PERFTEST_SRC/autogen.sh" ]; then
#        echo "[ERROR] 找不到 perftest 源码：$PERFTEST_SRC"
#        exit 1
#    fi
#
#    cd "$PERFTEST_SRC"
#
#    # 清理上一次构建，确保本次配置生效
#    if [ -f Makefile ]; then
#        make distclean
#    fi
#
#    chmod +x autogen.sh
#    ./autogen.sh
#
#    # 启用基本 CUDA GPUDirect 测试。
#    # 禁用可选 CUDA Runtime 功能，不影响基本 --use_cuda 测试。
#    ./configure \
#        --prefix=/usr/local \
#        CUDA_H_PATH="$CUDA_HOME/include/cuda.h" \
#        --disable-cudart
#
#    # 避免配置完成但实际未启用 CUDA
#    if ! grep -Eq \
#        '^#define[[:space:]]+HAVE_CUDA[[:space:]]+1' config.h; then
#        echo "[ERROR] perftest 未启用 CUDA 支持，请检查 config.log"
#        exit 1
#    fi
#
#    make -j"$(nproc)"
#    make install
#    ldconfig
#
#    # 使用绝对路径，避免误用 DOCA 已安装的其他版本
#    PERFTEST_BIN=/usr/local/bin/ib_write_bw
#
#    if [ ! -x "$PERFTEST_BIN" ]; then
#        echo "[ERROR] 未找到安装后的程序：$PERFTEST_BIN"
#        exit 1
#    fi
#
#    "$PERFTEST_BIN" --version
#
#    HELP_OUTPUT="$("$PERFTEST_BIN" --help)"
#    if ! grep -q -- '--use_cuda' <<< "$HELP_OUTPUT"; then
#        echo "[ERROR] 安装后的 ib_write_bw 未提供 --use_cuda 选项"
#        exit 1
#    fi
#
#    echo "[INFO] perftest 安装完成，已确认提供 --use_cuda 选项"
#    echo "[INFO] 程序路径：$PERFTEST_BIN"
#)
#
#cd /opt/ubuntu




