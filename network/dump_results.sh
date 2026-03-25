#!/bin/bash
# save as: dump_results.sh
# Run from directory containing results_network_ubuntu/
# Paste the output into Claude for analysis and plotting

OUTDIR="./results_network_ubuntu"

echo "=== PING LOOPBACK ===" && cat "$OUTDIR/ping_loopback.txt"
echo ""
echo "=== PING HOST ===" && cat "$OUTDIR/ping_host.txt"

echo ""
echo "=== TCP THROUGHPUT ==="
for f in "$OUTDIR"/loopback_tcp_*.json \
          "$OUTDIR"/vm_tcp_send_*.json \
          "$OUTDIR"/vm_tcp_recv_*.json; do
    [ -f "$f" ] || continue
    python3 -c "
import json
with open('$f') as fh: d = json.load(fh)
s = d['end']['sum_received']
print('$(basename $f .json)  bw={:.4f} Gbps'.format(s['bits_per_second']/1e9))
" 2>/dev/null
done

echo ""
echo "=== UDP THROUGHPUT + LOSS ==="
for f in "$OUTDIR"/loopback_udp_*.json \
          "$OUTDIR"/vm_udp_send_*.json; do
    [ -f "$f" ] || continue
    python3 -c "
import json
with open('$f') as fh: d = json.load(fh)
s  = d['end']['sum']
r  = d['end'].get('sum_received', s)
loss    = r.get('lost_percent', 0)
jitter  = r.get('jitter_ms', 0)
print('$(basename $f .json)  bw={:.4f} Gbps  jitter={:.3f}ms  loss={:.2f}%'.format(
    s['bits_per_second']/1e9, jitter, loss))
" 2>/dev/null
done

echo ""
echo "=== PARALLEL STREAMS ==="
for N in 1 2 4 8; do
    for f in "$OUTDIR"/vm_tcp_p${N}_*.json; do
        [ -f "$f" ] || continue
        python3 -c "
import json
with open('$f') as fh: d = json.load(fh)
s = d['end']['sum_received']
print('$(basename $f .json)  bw={:.4f} Gbps'.format(s['bits_per_second']/1e9))
" 2>/dev/null
    done
done

echo ""
echo "=== SMALL MESSAGE ==="
for f in "$OUTDIR"/loopback_smallmsg_*.json \
          "$OUTDIR"/vm_smallmsg_*.json; do
    [ -f "$f" ] || continue
    python3 -c "
import json
with open('$f') as fh: d = json.load(fh)
s = d['end']['sum_received']
print('$(basename $f .json)  bw={:.6f} Gbps'.format(s['bits_per_second']/1e9))
" 2>/dev/null
done

echo ""
echo "=== VMSTAT UNDER LOAD (first 10 lines) ==="
head -12 "$OUTDIR/vmstat_under_load.txt" 2>/dev/null

echo ""
echo "=== SS SOCKET SUMMARY ==="
cat "$OUTDIR/ss_socket_summary.txt" 2>/dev/null
