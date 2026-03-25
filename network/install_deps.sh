#!/bin/bash
# save as: install_deps.sh
# Run on both bare metal Ubuntu and VM

echo "Installing network benchmark dependencies..."

sudo apt-get update -qq
sudo apt-get install -y \
    iperf3 \
    iputils-ping \
    iproute2 \
    net-tools \
    python3 \
    python3-pip \
    bc

pip3 install matplotlib pandas numpy scipy --break-system-packages 2>/dev/null || \
pip3 install matplotlib pandas numpy scipy

echo ""
echo "Verifying installations:"
iperf3 --version | head -1
python3 -c "import matplotlib; print('matplotlib', matplotlib.__version__)"
echo "Done."
