# Usage: bash diskio_benchmark_ubuntu.sh baremetal   OR   vm
#
# Requires: sudo access (for cache flush), fio installed
# WARNING: creates and deletes a ~4GB test file in $TESTDIR


LABEL=${1:-"unknown"}
OUTDIR="./results_diskio_ubuntu_${LABEL}"
TESTDIR="$HOME/fio_test"
TESTFILE="$TESTDIR/fio_testfile"
FILESIZE="2g"
RUNTIME=60
IODEPTH=32
NUMJOBS=1

mkdir -p "$OUTDIR" "$TESTDIR"

# Confirm free space (need ~4GB)
FREE_GB=$(df -BG "$TESTDIR" | awk 'NR==2{gsub("G","",$4); print $4}')
if [ "$FREE_GB" -lt 4 ]; then
    echo "ERROR: Need at least 4GB free in $TESTDIR, only ${FREE_GB}GB available."
    exit 1
fi

echo "===== Disk I/O Benchmarks — Ubuntu $LABEL ====="
echo "Test file : $TESTFILE ($FILESIZE)"
echo "Output dir: $OUTDIR"
echo "fio engine: libaio (Linux native async I/O)"
echo "Runtime   : ${RUNTIME}s per job"
echo ""

# ── cache flush helper ────────────────────────────────────
# Linux equivalent of macOS 'sudo purge'
# Flushes page cache, dentries, and inodes
flush_cache() {
    echo "  [cache flush] Dropping page cache..."
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
    sleep 2
}

# ── verify libaio is available ────────────────────────────
fio --enghelp libaio &>/dev/null
if [ $? -ne 0 ]; then
    echo "WARNING: libaio not available, falling back to posixaio"
    ENGINE="posixaio"
else
    ENGINE="libaio"
fi
echo "I/O engine: $ENGINE"
echo ""

# -------------------------------------------------------
# BENCHMARK 1: Sequential Write throughput
# bs=1M, direct I/O bypasses page cache
# libaio: Linux kernel async I/O — lower overhead than posixaio
# On VirtualBox VM: virtio-blk driver handles the I/O queue
# -------------------------------------------------------
echo "=== [1/7] Sequential write (1M blocks, direct I/O) ==="
flush_cache
fio \
    --name=seq_write \
    --filename="$TESTFILE" \
    --rw=write \
    --bs=1m \
    --size=$FILESIZE \
    --numjobs=$NUMJOBS \
    --iodepth=$IODEPTH \
    --ioengine=$ENGINE \
    --direct=1 \
    --runtime=$RUNTIME \
    --time_based \
    --group_reporting \
    --output-format=json \
    --output="$OUTDIR/seq_write.json"
echo "  Done."

# -------------------------------------------------------
# BENCHMARK 2: Sequential Read throughput
# -------------------------------------------------------
echo ""
echo "=== [2/7] Sequential read (1M blocks, direct I/O) ==="
flush_cache
fio \
    --name=seq_read \
    --filename="$TESTFILE" \
    --rw=read \
    --bs=1m \
    --size=$FILESIZE \
    --numjobs=$NUMJOBS \
    --iodepth=$IODEPTH \
    --ioengine=$ENGINE \
    --direct=1 \
    --runtime=$RUNTIME \
    --time_based \
    --group_reporting \
    --output-format=json \
    --output="$OUTDIR/seq_read.json"
echo "  Done."

# -------------------------------------------------------
# BENCHMARK 3: Random Write IOPS
# bs=4k: matches Linux filesystem block size
# On VM: each 4K write crosses virtio-blk ring buffer
# then VirtualBox translates to host VDI/VMDK write
# -------------------------------------------------------
echo ""
echo "=== [3/7] Random write IOPS (4K blocks, direct I/O) ==="
flush_cache
fio \
    --name=rand_write \
    --filename="$TESTFILE" \
    --rw=randwrite \
    --bs=4k \
    --size=$FILESIZE \
    --numjobs=$NUMJOBS \
    --iodepth=$IODEPTH \
    --ioengine=$ENGINE \
    --direct=1 \
    --runtime=$RUNTIME \
    --time_based \
    --group_reporting \
    --output-format=json \
    --output="$OUTDIR/rand_write.json"
echo "  Done."

# -------------------------------------------------------
# BENCHMARK 4: Random Read IOPS
# -------------------------------------------------------
echo ""
echo "=== [4/7] Random read IOPS (4K blocks, direct I/O) ==="
flush_cache
fio \
    --name=rand_read \
    --filename="$TESTFILE" \
    --rw=randread \
    --bs=4k \
    --size=$FILESIZE \
    --numjobs=$NUMJOBS \
    --iodepth=$IODEPTH \
    --ioengine=$ENGINE \
    --direct=1 \
    --runtime=$RUNTIME \
    --time_based \
    --group_reporting \
    --output-format=json \
    --output="$OUTDIR/rand_read.json"
echo "  Done."

# -------------------------------------------------------
# BENCHMARK 5: Mixed 70R/30W
# Models real workload: databases, application servers
# -------------------------------------------------------
echo ""
echo "=== [5/7] Mixed 70R/30W random (4K blocks, direct I/O) ==="
flush_cache
fio \
    --name=mixed_rw \
    --filename="$TESTFILE" \
    --rw=randrw \
    --rwmixread=70 \
    --bs=4k \
    --size=$FILESIZE \
    --numjobs=$NUMJOBS \
    --iodepth=$IODEPTH \
    --ioengine=$ENGINE \
    --direct=1 \
    --runtime=$RUNTIME \
    --time_based \
    --group_reporting \
    --output-format=json \
    --output="$OUTDIR/mixed_rw.json"
echo "  Done."

# -------------------------------------------------------
# BENCHMARK 6: fsync latency
# iodepth=1, sync engine, fsync=1 per write
# On VM: guest fsync → virtio-blk → VirtualBox VDI layer
# → host ext4/xfs → physical disk
# Unlike macOS (which may shortcut fsync),
# Linux+VirtualBox typically honours full flush semantics
# -------------------------------------------------------
echo ""
echo "=== [6/7] fsync latency (4K, iodepth=1, sync) ==="
flush_cache
fio \
    --name=fsync_lat \
    --filename="$TESTFILE" \
    --rw=write \
    --bs=4k \
    --size=$FILESIZE \
    --numjobs=1 \
    --iodepth=1 \
    --ioengine=sync \
    --fsync=1 \
    --direct=0 \
    --runtime=$RUNTIME \
    --time_based \
    --group_reporting \
    --output-format=json \
    --output="$OUTDIR/fsync_lat.json"
echo "  Done."

# -------------------------------------------------------
# BENCHMARK 7: Block size scaling curve (4K → 1M)
# Builds throughput-vs-blocksize curve for both read/write
# Shows where virtio-blk overhead becomes negligible
# -------------------------------------------------------
echo ""
echo "=== [7/7] Block size scaling (seq read+write, 4K to 1M) ==="
for BS in 4k 64k 512k 1m; do
    echo "  Block size: $BS"

    flush_cache
    fio \
        --name="bsscale_read_${BS}" \
        --filename="$TESTFILE" \
        --rw=read \
        --bs=$BS \
        --size=$FILESIZE \
        --numjobs=1 \
        --iodepth=$IODEPTH \
        --ioengine=$ENGINE \
        --direct=1 \
        --runtime=30 \
        --time_based \
        --group_reporting \
        --output-format=json \
        --output="$OUTDIR/bsscale_read_${BS}.json"

    flush_cache
    fio \
        --name="bsscale_write_${BS}" \
        --filename="$TESTFILE" \
        --rw=write \
        --bs=$BS \
        --size=$FILESIZE \
        --numjobs=1 \
        --iodepth=$IODEPTH \
        --ioengine=$ENGINE \
        --direct=1 \
        --runtime=30 \
        --time_based \
        --group_reporting \
        --output-format=json \
        --output="$OUTDIR/bsscale_write_${BS}.json"
done
echo "  Done."

# -------------------------------------------------------
# BONUS: Linux-only — iostat during random read
# Captures: device utilisation %, await (ms), r/s, w/s
# No macOS equivalent — gives device-level I/O breakdown
# -------------------------------------------------------
echo ""
echo "=== [BONUS] iostat device stats under random read load ==="
# Detect the primary block device
PRIMARY_DEV=$(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print $1; exit}')
echo "  Monitoring: /dev/$PRIMARY_DEV"

fio \
    --name=iostat_load \
    --filename="$TESTFILE" \
    --rw=randread \
    --bs=4k \
    --size=$FILESIZE \
    --numjobs=1 \
    --iodepth=$IODEPTH \
    --ioengine=$ENGINE \
    --direct=1 \
    --runtime=30 \
    --time_based \
    --group_reporting \
    --output-format=json \
    --output="$OUTDIR/iostat_load.json" &
FIOPID=$!

# Sample iostat while fio runs
iostat -x /dev/$PRIMARY_DEV 1 28 > "$OUTDIR/iostat_during_load.txt" 2>&1 &
IOSTPID=$!

wait $FIOPID
wait $IOSTPID
echo "  Done."

# Cleanup
echo ""
echo "Cleaning up test file..."
rm -f "$TESTFILE"
rmdir "$TESTDIR" 2>/dev/null

echo ""
echo "===== All disk I/O benchmarks complete ====="
echo "Results saved in: $OUTDIR"
echo ""
echo "Transfer to host (if running on VM):"
echo "  python3 -m http.server 8080"
echo "  Then on host: wget -r -np -nH http://<VM_IP>:8080/$OUTDIR/"
