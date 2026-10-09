### all_reduce

同leaf <br>
测试条件：all_reduce_perf -b 32G  -e 32G -f 0 -i 0 -g 1 <br>
测试结果：busbw 4小时稳定不低于900GB/s <br>
跨leaf<br>
测试条件：all_reduce_perf -b 32G  -e 32G -f 0 -i 0 -g 1<br>
测试结果：busbw 4小时稳定不低于890GB/s<br>

```text
export LD_LIBRARY_PATH=/usr/local/cuda-13.1/lib64:/usr/lib/x86_64-linux-gnu/openmpi/lib:/usr/lib/x86_64-linux-gnu

/usr/bin/mpirun --bind-to none \
  --launch-agent "env LD_LIBRARY_PATH=$LD_LIBRARY_PATH /usr/bin/orted" \
  --mca pml ob1 \
  --mca btl self,vader,tcp \
  --mca btl_tcp_if_include bond4 \
  --mca oob_tcp_if_include bond4 \
  --mca plm_rsh_args '-o BatchMode=yes -o StrictHostKeyChecking=yes' \
  -x LD_LIBRARY_PATH \
  -x NCCL_DEBUG=WARN \
  -x NCCL_ALGO=NVLSTree \
  -x NCCL_NVLS_NCHANNELS=64 \
  -x NCCL_IB_DISABLE=0 \
  -x NCCL_SOCKET_IFNAME=bond4 \
  -x NCCL_IB_HCA=mlx5_0:1,mlx5_1:1,mlx5_12:1,mlx5_15:1,mlx5_16:1,mlx5_5:1,mlx5_6:1,mlx5_7:1 \
  -x NCCL_P2P_NET_CHUNKSIZE=2097152 \
  -x NCCL_BUFFSIZE=16777216 \
  --wdir /opt/ubuntu/nccl-tests/build \
  -np 16 -N 8 \
  -H 192.168.161.202:8,192.168.161.203:8 \
  ./all_reduce_perf_mpi \
  -b 32G -e 32G -f 2 -i 0 -g 1 \
  -w 2 -n 5 -c 1 -T 60 -R 0
```

### sendrecv_perf_mpi

同leaf<br>
测试条件：sendrecv_perf -b 32G  -e 32G -f 0 -i 0 -g 1<br>
测试结果：busbw 4小时稳定不低于98GB/s<br>
跨leaf<br>
测试条件：sendrecv_perf -b 32G  -e 32G -f 0 -i 0 -g 1<br>
测试结果：busbw 4小时稳定不低于90GB/s<br>

```text
/usr/bin/mpirun --bind-to none \
  --launch-agent "env LD_LIBRARY_PATH=$LD_LIBRARY_PATH /usr/bin/orted" \
  --mca pml ob1 \
  --mca btl self,vader,tcp \
  --mca btl_tcp_if_include bond4 \
  --mca oob_tcp_if_include bond4 \
  --mca plm_rsh_args '-o BatchMode=yes -o StrictHostKeyChecking=yes' \
  -x LD_LIBRARY_PATH \
  -x NCCL_DEBUG=WARN \
  -x NCCL_IB_DISABLE=0 \
  -x NCCL_SOCKET_IFNAME=bond4 \
  -x NCCL_IB_HCA=mlx5_0:1,mlx5_1:1,mlx5_12:1,mlx5_15:1,mlx5_16:1,mlx5_5:1,mlx5_6:1,mlx5_7:1 \
  -x NCCL_P2P_NET_CHUNKSIZE=2097152 \
  -x NCCL_BUFFSIZE=16777216 \
  -x NCCL_NCHANNELS_PER_NET_PEER=4 \
  --wdir /opt/ubuntu/nccl-tests/build \
  -np 16 -N 8 \
  -H 192.168.161.202:8,192.168.161.203:8 \
  ./sendrecv_perf_mpi \
  -b 32G -e 32G -f 2 -i 0 -g 1 \
  -w 8 -n 20 -c 1 -T 600 -R 2
```

### alltoall

同leaf<br>
测试条件：alltoall_perf -b 32G  -e 32G -f 0 -i 0 -g 1<br>
测试结果：busbw 4小时稳定不低于165GB/s<br>
跨leaf<br>
测试条件：alltoall_perf -b 32G  -e 32G -f 0 -i 0 -g 1<br>
测试结果：busbw 4小时稳定不低于160GB/s<br>

```text
export LD_LIBRARY_PATH=/usr/local/cuda-13.1/lib64:/usr/lib/x86_64-linux-gnu/openmpi/lib:/usr/lib/x86_64-linux-gnu

/usr/bin/mpirun --bind-to none \
  --launch-agent "env LD_LIBRARY_PATH=$LD_LIBRARY_PATH /usr/bin/orted" \
  --mca pml ob1 \
  --mca btl self,vader,tcp \
  --mca btl_tcp_if_include bond4 \
  --mca oob_tcp_if_include bond4 \
  --mca plm_rsh_args '-o BatchMode=yes -o StrictHostKeyChecking=yes' \
  -x LD_LIBRARY_PATH \
  -x NCCL_DEBUG=WARN \
  -x NCCL_ALGO=NVLSTree \
  -x NCCL_NVLS_NCHANNELS=64 \
  -x NCCL_IB_DISABLE=0 \
  -x NCCL_SOCKET_IFNAME=bond4 \
  -x NCCL_IB_HCA=mlx5_0:1,mlx5_1:1,mlx5_12:1,mlx5_15:1,mlx5_16:1,mlx5_5:1,mlx5_6:1,mlx5_7:1 \
  -x NCCL_P2P_NET_CHUNKSIZE=2097152 \
  -x NCCL_BUFFSIZE=16777216 \
  --wdir /opt/ubuntu/nccl-tests/build \
  -np 16 -N 8 \
  -H 192.168.161.202:8,192.168.161.203:8 \
  ./all_reduce_perf_mpi \
  -b 32G -e 32G -f 2 -i 0 -g 1 \
  -w 2 -n 5 -c 1 -T 60 -R 0  -R 2  -D 4 -V 32
```

### reduce_scatter_perf

同leaf<br>
测试条件：reduce_scatter_perf -b 32G  -e 32G -f 0 -i 0 -g 1<br>
测试结果：busbw 4小时稳定不低于765GB/s<br>
跨leaf<br>
测试条件：reduce_scatter_perf -b 32G  -e 32G -f 0 -i 0 -g 1<br>
测试结果：busbw 4小时稳定不低于760GB/s<br>

```text
/usr/bin/mpirun --bind-to none \
  --launch-agent "env LD_LIBRARY_PATH=$LD_LIBRARY_PATH /usr/bin/orted" \
  --mca pml ob1 \
  --mca btl self,vader,tcp \
  --mca btl_tcp_if_include bond4 \
  --mca oob_tcp_if_include bond4 \
  --mca plm_rsh_args '-o BatchMode=yes -o StrictHostKeyChecking=yes' \
  -x LD_LIBRARY_PATH \
  -x NCCL_DEBUG=WARN \
  -x NCCL_ALGO=Ring \
  -x NCCL_IB_DISABLE=0 \
  -x NCCL_SOCKET_IFNAME=bond4 \
  -x 'NCCL_IB_HCA==mlx5_0:1,mlx5_1:1,mlx5_12:1,mlx5_15:1,mlx5_16:1,mlx5_5:1,mlx5_6:1,mlx5_7:1' \
  -x NCCL_P2P_NET_CHUNKSIZE=2097152 \
  -x NCCL_BUFFSIZE=16777216 \
  --wdir /opt/ubuntu/nccl-tests/build \
  -np 16 -N 8 \
  -H 192.168.161.202:8,192.168.161.203:8 \
  ./reduce_scatter_perf_mpi \
  -b 32G -e 32G -f 2 -i 0 -g 1 \
  -w 2 -n 5 -c 1 -T 60 -R 0 
```


| 类别 | 配置文件/位置 | 配置项 | 取值 | 说明 |
| --- | --- | --- | --- | --- |
| BIOS 设置 | | `P2P Order Write` | `disabled` | 禁用 PCIe P2P 写操作的严格排序，减少写事务间的顺序依赖，降低延迟 |
| BIOS 设置 | | `ACS Enable` | `disabled` | 禁用 PCIe ACS，解除设备间的 IOMMU 隔离，使 GPU 能够直接访问彼此地址空间 |
| BIOS 设置 | | `Re-Size Bar Support` | `enabled` | 启用 Resizable BAR，允许 CPU 一次性映射 GPU 全部显存，为 BAR1-based P2P 提供硬件基础 |
| NCCL环境变量 | | `NCCL_MIN_NCHANNELS` | `10` | 设置 NCCL 通信的最小通道数，增加通信并行度，提升多 GPU 集体通信的吞吐量 |
| NCCL环境变量 | | `NCCL_P2P_LEVEL` | `SYS` | 控制 NCCL P2P 通信允许的最远距离级别，设为 SYS 表示允许跨 PCIe 根复合体的系统级 P2P 通信 |
| 驱动 | `/etc/modprobe.d/nvidia-relaxed-ordering.conf` | `options nvidia NVreg_EnablePCIERelaxedOrderingMode=1` | | 启用 PCIe Relaxed Ordering 模式，允许 TLP 事务乱序传输，提升大批量 DMA 写入的吞吐性能，非通用设置项 |
| 驱动 | `/etc/modprobe.d/nvidia.conf` | `options nvidia NVreg_RegistryDwords="ForceP2P=0x111;RMForceP2PType=0x1;RMForceStaticBar1=0x1;RMPcieP2PType=0x1"` | | 强制启用 GPU 间 P2P 通信，指定使用 BAR1 作为 P2P 映射通道，绕过驱动默认限制，不建议生产阶段部署 |
| 驱动 | `/etc/default/grub` | `GRUB_CMDLINE_LINUX_DEFAULT="amd_iommu=on iommu=pt"` | | 设置 IOMMU 为 Pass-Through 模式，仅做地址转换不做设备隔离，配合 ACS 禁用实现 GPU 直通访问 |

