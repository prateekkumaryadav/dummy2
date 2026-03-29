# Run on both bare metal Ubuntu and VM

echo "Installing disk I/O benchmark dependencies..."
sudo apt-get update -qq
sudo apt-get install -y \
    fio \
    sysstat \
    hdparm \
    smartmontools \
    python3-pip \
    lsblk \
    util-linux

pip3 install matplotlib pandas numpy scipy --break-system-packages 2>/dev/null || \
pip3 install matplotlib pandas numpy scipy

echo ""
echo "Verifying:"
fio --version
python3 -c "import matplotlib; print('matplotlib ok')"
echo "Done."
