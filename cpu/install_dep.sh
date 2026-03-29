# Run on both bare metal Ubuntu and VM

echo "Installing CPU benchmark dependencies..."
sudo apt-get update -qq
sudo apt-get install -y \
    sysbench \
    stress-ng \
    sysstat \
    linux-tools-common \
    linux-tools-$(uname -r) \
    cpufrequtils \
    python3-pip \
    bc \
    dmidecode

pip3 install matplotlib pandas numpy scipy --break-system-packages 2>/dev/null || \
pip3 install matplotlib pandas numpy scipy

echo ""
echo "Verifying:"
sysbench --version
stress-ng --version | head -1
perf --version 2>/dev/null || echo "perf: may need kernel headers"
python3 -c "import matplotlib; print('matplotlib ok')"
echo "Done."
