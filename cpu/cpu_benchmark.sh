# Usage: bash cpu_benchmark_ubuntu.sh baremetal   OR   vm
#
# Runs identically on both bare metal and VM

LABEL=${1:-"unknown"}
OUTDIR="./results_cpu_ubuntu_${LABEL}"
DURATION=30
RUNS=5

# Use 1 thread for single, match core count for multi
THREADS_SINGLE=1
# THREADS_MULTI=$(nproc)
THREADS_MULTI=3

mkdir -p "$OUTDIR"

echo "===== CPU Benchmarks — Ubuntu $LABEL ====="
echo "Logical cores : $THREADS_MULTI"
echo "Duration      : ${DURATION}s per run"
echo "Runs          : $RUNS"
echo "Output        : $OUTDIR"
echo ""

# -------------------------------------------------------
# BENCHMARK 1: sysbench single-thread
# Integer throughput via prime number sieve
# Identical to macOS benchmark for cross-platform comparison
# -------------------------------------------------------
echo "=== [1/8] sysbench single-thread prime sieve ==="
for i in $(seq 1 $RUNS); do
    echo -n "  Run $i/$RUNS ... "
    sysbench cpu \
        --cpu-max-prime=20000 \
        --threads=$THREADS_SINGLE \
        --time=$DURATION \
        run 2>/dev/null | grep "events per second" | awk '{print $NF}' \
        >> "$OUTDIR/sysbench_single.txt"
    echo "done"
done
echo "  Done."

# -------------------------------------------------------
# BENCHMARK 2: sysbench multi-thread
# Uses all available logical cores
# For cross-platform comparison with macOS, also run
# a 5-thread version to match the macOS VM's vCPU count
# -------------------------------------------------------
echo ""
echo "=== [2/8] sysbench multi-thread ($THREADS_MULTI threads) ==="
for i in $(seq 1 $RUNS); do
    echo -n "  Run $i/$RUNS ... "
    sysbench cpu \
        --cpu-max-prime=20000 \
        --threads=$THREADS_MULTI \
        --time=$DURATION \
        run 2>/dev/null | grep "events per second" | awk '{print $NF}' \
        >> "$OUTDIR/sysbench_multi.txt"
    echo "done"
done
echo "  Done."

# -------------------------------------------------------
# BENCHMARK 3: sysbench latency distribution
# Captures per-event min/avg/max/p95 latency
# -------------------------------------------------------
echo ""
echo "=== [3/8] sysbench latency distribution (single-thread) ==="
sysbench cpu \
    --cpu-max-prime=20000 \
    --threads=$THREADS_SINGLE \
    --time=$DURATION \
    --histogram=on \
    run 2>/dev/null > "$OUTDIR/sysbench_latency_raw.txt"
echo "  Done."

# -------------------------------------------------------
# BENCHMARK 4: Clock stability — 20 x 3s bursts
# Detects vCPU preemption jitter and thermal throttling
# On VirtualBox VM: jitter reveals host scheduler
# preempting vCPUs between bursts
# -------------------------------------------------------
echo ""
echo "=== [4/8] Clock stability (20 x 3s bursts) ==="
for i in $(seq 1 20); do
    sysbench cpu \
        --cpu-max-prime=20000 \
        --threads=$THREADS_SINGLE \
        --time=3 \
        run 2>/dev/null | grep "events per second" | awk '{print $NF}' \
        >> "$OUTDIR/clock_stability.txt"
done
echo "  Done."

# -------------------------------------------------------
# BENCHMARK 5: stress-ng multi-stressor suite
# Tests: ackermann, bitops, double, euler, explog,
# fft, fibonacci, matrixprod, trig — comprehensive
# --metrics outputs ops/sec per stressor
# -------------------------------------------------------
echo ""
echo "=== [5/8] stress-ng multi-stressor suite ==="
stress-ng \
    --cpu $THREADS_MULTI \
    --cpu-method all \
    --metrics \
    --timeout ${DURATION}s \
    --log-file "$OUTDIR/stressng_raw.txt" \
    2>&1 | tee -a "$OUTDIR/stressng_raw.txt"
echo "  Done."

# -------------------------------------------------------
# BENCHMARK 6: vmstat CPU split under load
# Linux equivalent of macOS 'top -l' for us/sy/id split
# Samples every 1s for 25s while sysbench runs in background
# sy% on VM includes some hypercall cost (unlike macOS
# where hypercalls are invisible to top)
# -------------------------------------------------------
echo ""
echo "=== [6/8] vmstat CPU split under load ==="
sysbench cpu \
    --cpu-max-prime=20000 \
    --threads=$THREADS_MULTI \
    --time=28 \
    run &>/dev/null &
SBPID=$!
sleep 2
# vmstat: 1s interval, 20 samples
# columns: r b swpd free buff cache si so bi bo in cs us sy id wa st
vmstat 1 20 > "$OUTDIR/vmstat_cpu_split.txt"
wait $SBPID
echo "  Done."

# -------------------------------------------------------
# BENCHMARK 7: mpstat per-core utilisation
# Linux-exclusive: shows per-CPU utilisation
# On VM: reveals uneven vCPU scheduling by hypervisor
# On BM: shows real core load distribution
# -------------------------------------------------------
echo ""
echo "=== [7/8] mpstat per-core utilisation under load ==="
sysbench cpu \
    --cpu-max-prime=20000 \
    --threads=$THREADS_MULTI \
    --time=28 \
    run &>/dev/null &
SBPID=$!
sleep 2
# mpstat -P ALL: per-CPU breakdown, 1s interval, 20 samples
mpstat -P ALL 1 20 > "$OUTDIR/mpstat_per_core.txt"
wait $SBPID
echo "  Done."

# -------------------------------------------------------
# BENCHMARK 8: perf stat — hardware performance counters
# Linux-exclusive — not available on macOS
# Captures: IPC, cache-miss rate, branch mispredict rate
# On VM: lower IPC vs BM reveals hidden overhead from
# VM-exit/entry disrupting CPU pipeline state
# Requires: perf installed + kernel.perf_event_paranoid <= 1
# Set with: sudo sysctl kernel.perf_event_paranoid=1
# -------------------------------------------------------
echo ""
echo "=== [8/8] perf stat hardware counters (Linux-exclusive) ==="

# Check perf availability and permissions
PERF_OK=0
perf stat echo "test" &>/dev/null && PERF_OK=1

if [ $PERF_OK -eq 1 ]; then
    # Run perf stat over a fixed sysbench workload
    # Use --count not --time for reproducible comparison
    perf stat \
        -e cycles,instructions,cache-misses,cache-references,\
branch-misses,branch-instructions,context-switches,cpu-migrations \
        sysbench cpu \
            --cpu-max-prime=20000 \
            --threads=$THREADS_SINGLE \
            --time=10 \
            run 2>&1 > "$OUTDIR/perf_stat.txt"
    echo "  perf stat saved."
else
    echo "  perf not available or insufficient permissions."
    echo "  Try: sudo sysctl kernel.perf_event_paranoid=1"
    echo "  Or:  sudo perf stat ..."
    # Fallback: capture /proc/stat delta manually
    echo "  Falling back to /proc/stat sampling..."
    cat /proc/stat | head -$(( THREADS_MULTI + 2 )) > "$OUTDIR/proc_stat_before.txt"
    sysbench cpu \
        --cpu-max-prime=20000 \
        --threads=$THREADS_SINGLE \
        --time=10 \
        run &>/dev/null
    cat /proc/stat | head -$(( THREADS_MULTI + 2 )) > "$OUTDIR/proc_stat_after.txt"
    echo "  /proc/stat delta saved."
fi

echo ""
echo "===== All CPU benchmarks complete ====="
echo "Results saved in: $OUTDIR"
echo ""
echo "Transfer to host (if running on VM):"
echo "  python3 -m http.server 8080"
echo "  Then on host: wget -r -np -nH http://<VM_IP>:8080/$OUTDIR/"
