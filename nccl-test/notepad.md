### all_reduce

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
  -b 32G -e 32G -f 0 -i 0 -g 1 \
  -w 8 -n 20 -c 1 -T 600 -R 2
```
