#!/bin/bash
# save as: network_benchmark_ubuntu.sh
# Run on UBUNTU VM
# Before starting: run  iperf3 -s  on bare metal host
#
# Usage: bash network_benchmark_ubuntu.sh <HOST_IP> <LOOPBACK_IP>
# Example: bash network_benchmark_ubuntu.sh 10.0.2.2 127.0.0.1
#
# VirtualBox NAT default gateway: 10.0.2.2
# If using Bridged mode: use host's actual LAN IP instead

HOST_IP=${1:-"10.0.2.2"}
LO_IP=${2:-"127.0.0.1"}
OUTDIR="./results_network_ubuntu"
DURATION=30
RUNS=5
PARALLEL_STREAMS=(1 2 4 8)

mkdir -p "$OUTDIR"

echo "===== Network Benchmarks — Ubuntu VM (VirtualBox) ====="
echo "Host IP    : $HOST_IP  (iperf3 server)"
echo "Loopback   : $LO_IP   (guest kernel baseline)"
echo "Duration   : ${DURATION}s per run"
echo "Runs       : $RUNS"
echo ""

# ── pre-flight ────────────────────────────────────────────
echo "Pre-check: confirming host reachability..."
ping -c 2 -W 2 "$HOST_IP" &>/dev/null
if [ $? -ne 0 ]; then
    echo "ERROR: Cannot ping host at $HOST_IP"
    echo "Check VirtualBox network mode and host firewall."
    exit 1
fi

echo "Pre-check: confirming iperf3 server on host..."
iperf3 -c "$HOST_IP" -t 2 --connect-timeout 3000 &>/dev/null
if [ $? -ne 0 ]; then
    echo "ERROR: Cannot reach iperf3 server at $HOST_IP"
    echo "On bare metal host, run: iperf3 -s"
    echo "Also check: sudo ufw allow 5201"
    exit 1
fi
echo "  Server reachable. Starting benchmarks."
echo ""

run_iperf() {
    local TARGET=$1
    local OUTFILE=$2
    shift 2
    iperf3 -c "$TARGET" \
        --time $DURATION \
        --json \
        "$@" \
        > "$OUTFILE" 2>/dev/null
}

# ─────────────────────────────────────────────────────────
# BENCHMARK 1: VM loopback TCP (guest kernel baseline)
# Pure Linux kernel networking — no virtio, no NAT
# Establishes ceiling: what the VM TCP stack can do alone
# Uses port 5202 to avoid conflict with host iperf3 server
# ─────────────────────────────────────────────────────────
echo "=== [1/8] VM loopback TCP throughput (guest baseline) ==="
iperf3 -s -D -p 5202 --pidfile /tmp/iperf3_lo.pid
sleep 1
for i in $(seq 1 $RUNS); do
    echo -n "  Run $i/$RUNS ... "
    run_iperf "$LO_IP" "$OUTDIR/loopback_tcp_${i}.json" -p 5202
    echo "done"
done
kill $(cat /tmp/iperf3_lo.pid 2>/dev/null) 2>/dev/null
sleep 1
echo "  Done."

# ─────────────────────────────────────────────────────────
# BENCHMARK 2: VM→Host TCP throughput (single stream)
# Full path: virtio-net → VirtualBox NAT engine → host TCP
# VirtualBox NAT runs in ring-3 userspace (like UTM NAT)
# ─────────────────────────────────────────────────────────
echo ""
echo "=== [2/8] VM→Host TCP throughput (single stream) ==="
for i in $(seq 1 $RUNS); do
    echo -n "  Run $i/$RUNS ... "
    run_iperf "$HOST_IP" "$OUTDIR/vm_tcp_send_${i}.json"
    echo "done"
done
echo "  Done."

# ─────────────────────────────────────────────────────────
# BENCHMARK 3: Host→VM TCP (reverse direction)
# --reverse: server sends, client (VM) receives
# Tests NAT inbound path — connection tracking + DNAT
# ─────────────────────────────────────────────────────────
echo ""
echo "=== [3/8] Host→VM TCP throughput (reverse) ==="
for i in $(seq 1 $RUNS); do
    echo -n "  Run $i/$RUNS ... "
    run_iperf "$HOST_IP" "$OUTDIR/vm_tcp_recv_${i}.json" --reverse
    echo "done"
done
echo "  Done."

# ─────────────────────────────────────────────────────────
# BENCHMARK 4: VM→Host UDP throughput + packet loss
# --bandwidth 0 = no rate cap (blast mode)
# VirtualBox NAT may drop UDP differently than UTM
# Records: throughput, jitter (ms), lost_percent
# ─────────────────────────────────────────────────────────
echo ""
echo "=== [4/8] VM→Host UDP throughput + loss ==="
for i in $(seq 1 $RUNS); do
    echo -n "  Run $i/$RUNS ... "
    run_iperf "$HOST_IP" "$OUTDIR/vm_udp_send_${i}.json" \
        --udp --bandwidth 0
    echo "done"
done
echo "  Done."

# ─────────────────────────────────────────────────────────
# BENCHMARK 5: VM loopback UDP (guest UDP baseline)
# ─────────────────────────────────────────────────────────
echo ""
echo "=== [5/8] VM loopback UDP throughput (baseline) ==="
iperf3 -s -D -p 5202 --pidfile /tmp/iperf3_lo.pid
sleep 1
for i in $(seq 1 $RUNS); do
    echo -n "  Run $i/$RUNS ... "
    run_iperf "$LO_IP" "$OUTDIR/loopback_udp_${i}.json" \
        -p 5202 --udp --bandwidth 0
    echo "done"
done
kill $(cat /tmp/iperf3_lo.pid 2>/dev/null) 2>/dev/null
sleep 1
echo "  Done."

# ─────────────────────────────────────────────────────────
# BENCHMARK 6: Parallel TCP stream scaling (1/2/4/8)
# VirtualBox NAT is also single-threaded in its packet
# processing loop — expect same degradation pattern as UTM
# 3 runs per stream count for stability
# ─────────────────────────────────────────────────────────
echo ""
echo "=== [6/8] Parallel TCP stream scaling ==="
for N in "${PARALLEL_STREAMS[@]}"; do
    echo "  Testing $N parallel stream(s)..."
    for i in $(seq 1 3); do
        echo -n "    Run $i/3 ... "
        run_iperf "$HOST_IP" "$OUTDIR/vm_tcp_p${N}_${i}.json" \
            --parallel $N
        echo "done"
    done
done
echo "  Done."

# ─────────────────────────────────────────────────────────
# BENCHMARK 7: ICMP ping RTT — loopback vs host
# Linux ping: -i interval, -c count, -q quiet summary only
# Note: -i < 0.2 requires root on Linux (use sudo or 0.2)
# VM loopback RTT = guest kernel scheduling latency only
# VM→Host RTT    = virtio-net + VirtualBox NAT latency
# ─────────────────────────────────────────────────────────
echo ""
echo "=== [7/8] ICMP ping RTT ==="
echo "  Pinging VM loopback (200 packets, 0.2s interval)..."
ping -c 200 -i 0.2 -q "$LO_IP" > "$OUTDIR/ping_loopback.txt" 2>&1

echo "  Pinging host (200 packets, 0.2s interval)..."
ping -c 200 -i 0.2 -q "$HOST_IP" > "$OUTDIR/ping_host.txt" 2>&1
echo "  Done."

# ─────────────────────────────────────────────────────────
# BENCHMARK 8: TCP small-message throughput (1-byte)
# Isolates per-packet overhead of the virtio-net stack
# Low throughput = high per-packet NAT processing cost
# ─────────────────────────────────────────────────────────
echo ""
echo "=== [8/8] TCP small-message throughput (1-byte payload) ==="
iperf3 -s -D -p 5202 --pidfile /tmp/iperf3_lo.pid
sleep 1
for i in $(seq 1 $RUNS); do
    echo -n "  Loopback run $i/$RUNS ... "
    run_iperf "$LO_IP" "$OUTDIR/loopback_smallmsg_${i}.json" \
        -p 5202 --length 1
    echo "done"
done
kill $(cat /tmp/iperf3_lo.pid 2>/dev/null) 2>/dev/null
sleep 1

for i in $(seq 1 $RUNS); do
    echo -n "  Host run $i/$RUNS ... "
    run_iperf "$HOST_IP" "$OUTDIR/vm_smallmsg_${i}.json" \
        --length 1
    echo "done"
done
echo "  Done."

# ─────────────────────────────────────────────────────────
# BONUS: Linux-only — capture vmstat and ss stats during load
# vmstat 1 30: context switches, interrupts, cpu us/sy/id
# ss -s: socket summary (useful for NAT connection state)
# These have no macOS equivalent — gives deeper insight
# ─────────────────────────────────────────────────────────
echo ""
echo "=== [BONUS] vmstat + ss under load (Linux-only) ==="
iperf3 -c "$HOST_IP" -t 35 --json \
    --parallel 4 > /dev/null 2>&1 &
IPID=$!

vmstat 1 30 > "$OUTDIR/vmstat_under_load.txt" &
VMID=$!

ss -s > "$OUTDIR/ss_socket_summary.txt" 2>&1

wait $IPID
wait $VMID
echo "  Done."

echo ""
echo "===== All network benchmarks complete ====="
echo "Results saved in: $OUTDIR"
echo ""
echo "Transfer results to host:"
echo "  On VirtualBox with shared folder:"
echo "    cp -r $OUTDIR /media/sf_shared/"
echo "  Or start HTTP server on VM:"
echo "    python3 -m http.server 8080"
echo "  Then on host: wget -r -np -nH http://<VM_IP>:8080/results_network_ubuntu/"
