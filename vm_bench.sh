#!/usr/bin/env bash
# ============================================================
# vm_bench.sh
# Virtualization Overhead Study — VirtualBox Guest Benchmarks
# Guest: Ubuntu 24.04, 3 vCPUs, 2 GB RAM
# Run as: sudo bash vm_bench.sh
# NOTE: perf PMU counters may be limited inside VirtualBox.
#       Script degrades gracefully if perf fails.
# ============================================================

set -euo pipefail

RESULTS_DIR="$HOME/virt_study/vm"
mkdir -p "$RESULTS_DIR"
THREADS=3       # Use all 3 vCPUs
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
LOG="$RESULTS_DIR/run_$TIMESTAMP.log"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

# ── Preflight checks ────────────────────────────────────────
for tool in sysbench fio iperf3 vmstat iostat; do
    if ! command -v "$tool" &>/dev/null; then
        echo "Missing: $tool"
        echo "  sudo apt install sysbench fio iperf3 sysstat"
        exit 1
    fi
done

log "=== VM BENCHMARK START ==="
log "Threads: $THREADS | Environment: VirtualBox guest"

# ── System snapshot ─────────────────────────────────────────
log "--- System Snapshot ---"
lscpu >> "$LOG"
free -h >> "$LOG"
lsblk -d -o NAME,SIZE,ROTA,TYPE >> "$LOG"
cat /proc/cpuinfo | grep "model name" | head -1 >> "$LOG"
uname -r >> "$LOG"

# Confirm we're inside a VM
log "Hypervisor detection:"
systemd-detect-virt >> "$LOG" 2>&1 || true
cat /sys/class/dmi/id/product_name >> "$LOG" 2>&1 || true

# ── 1. CPU Benchmark (sysbench) ─────────────────────────────
log "--- [1/5] CPU: sysbench prime number test ---"
sysbench cpu \
    --cpu-max-prime=20000 \
    --threads=$THREADS \
    --time=60 \
    run > "$RESULTS_DIR/cpu_sysbench.txt" 2>&1
log "CPU sysbench done."

# ── 2. CPU Benchmark (perf stat) ────────────────────────────
log "--- [2/5] CPU: perf stat (best-effort inside VM) ---"
if command -v perf &>/dev/null; then
    perf stat \
        -e cycles,instructions,cache-references,cache-misses,branch-misses,context-switches,cpu-migrations \
        --output "$RESULTS_DIR/cpu_perf_stat.txt" \
        sysbench cpu --cpu-max-prime=20000 --threads=$THREADS --time=30 run >> "$LOG" 2>&1 \
        || log "WARNING: perf stat partially failed inside VM — limited PMU access expected."
else
    log "perf not available in VM, skipping."
    echo "perf not available" > "$RESULTS_DIR/cpu_perf_stat.txt"
fi

# ── 3. Memory Benchmark (sysbench) ──────────────────────────
log "--- [3/5] Memory: sysbench memory ---"
# Use 5G total to stay safe within 2 GB RAM (sysbench streams, doesn't pre-alloc all)
sysbench memory \
    --memory-block-size=1M \
    --memory-total-size=5G \
    --memory-oper=write \
    --threads=$THREADS \
    run > "$RESULTS_DIR/mem_write.txt" 2>&1

sysbench memory \
    --memory-block-size=1M \
    --memory-total-size=5G \
    --memory-oper=read \
    --threads=$THREADS \
    run > "$RESULTS_DIR/mem_read.txt" 2>&1
log "Memory sysbench done."

# ── 4. Disk I/O Benchmark (fio) ─────────────────────────────
log "--- [4/5] Disk I/O: fio ---"
FIO_DIR="$RESULTS_DIR/fio_testdir"
mkdir -p "$FIO_DIR"

# Reduce size to 1G to fit comfortably in VM disk allocation
for rw_mode in write read randwrite randread; do
    case "$rw_mode" in
        write|read)     BS=1M; IODEPTH=8;  NAME="seq_${rw_mode/write/write}"  ;;
        randwrite)      BS=4K; IODEPTH=32; NAME="rand_write" ;;
        randread)       BS=4K; IODEPTH=32; NAME="rand_read"  ;;
    esac

    fio --name="$NAME" \
        --directory="$FIO_DIR" \
        --rw="$rw_mode" \
        --bs="$BS" \
        --size=1G \
        --numjobs=1 \
        --iodepth="$IODEPTH" \
        --ioengine=libaio \
        --direct=1 \
        --runtime=60 \
        --time_based \
        --output="$RESULTS_DIR/fio_${NAME}.txt" \
        --output-format=json
done

rm -f "$FIO_DIR"/*.* 2>/dev/null || true
log "fio done."

# ── 5. Network Benchmark (iperf3 loopback + host) ───────────
log "--- [5/5] Network: iperf3 ---"

# Loopback within VM
iperf3 -s -D --logfile "$RESULTS_DIR/iperf3_server.log"
sleep 2

iperf3 -c 127.0.0.1 -t 30 -P 3 --json > "$RESULTS_DIR/iperf3_tcp_loopback.json" 2>&1
iperf3 -c 127.0.0.1 -t 30 -u -b 10G --json > "$RESULTS_DIR/iperf3_udp_loopback.json" 2>&1
iperf3 -c 127.0.0.1 -t 20 --length 1 --json > "$RESULTS_DIR/iperf3_latency.json" 2>&1

pkill iperf3 || true

# VM → Host direction (requires iperf3 server running on host at 192.168.56.1)
# Start on host first: iperf3 -s
# Uncomment once host IP confirmed:
# HOST_IP="192.168.56.1"
# iperf3 -c "$HOST_IP" -t 30 -P 3 --json > "$RESULTS_DIR/iperf3_tcp_vm_to_host.json" 2>&1
# log "VM->Host iperf3 done (if host server was running)."

log "iperf3 done."

# ── vmstat snapshot ──────────────────────────────────────────
log "--- Bonus: vmstat 30-second tail ---"
vmstat 1 30 > "$RESULTS_DIR/vmstat_idle.txt" 2>&1 &
wait

log "=== VM BENCHMARK COMPLETE ==="
log "Results in: $RESULTS_DIR"
echo ""
echo "Copy results back to host:"
echo "  tar czf vm_results.tar.gz -C \$HOME/virt_study vm/"
echo "  Then: scp or VirtualBox shared folder transfer"
