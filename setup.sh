#!/bin/bash
set -euo pipefail

# ===== INPUT =====
if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <claim_reward_address>"
  exit 1
fi
CLAIM_REWARD_ADDRESS=$1

# ===== ENSURE aria2 =====
if ! command -v aria2c >/dev/null 2>&1; then
  sudo apt update && sudo apt install -y aria2
fi

apt-get install -y \
  ca-certificates curl wget tar zstd \
  libssl3 libstdc++6 libgmp10 libgmp-dev libsodium23 libomp5 \
  openmpi-bin libopenmpi3 libopenmpi-dev libhwloc15 \
  libz1 libevent-2.1-7 libevent-pthreads-2.1-7 libudev1 libcap2 ripgrep build-essential binutils

wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i cuda-keyring_1.1-1_all.deb
sudo apt update
sudo apt install -y cuda-toolkit-13-0
# ===== SMART DOWNLOAD FUNCTION =====
download_file() {
  local url="$1"
  local dst="$2"

  if [[ "$url" == *"prover.xyz"* ]]; then
    echo "[curl] Downloading $url"

    # remove broken partials (important)
    rm -f "$dst"

    curl -L --fail \
  	--retry 10 \
  	--retry-delay 5 \
  	--connect-timeout 30 \
  	-C - \
  	-o "$dst" \
  	"$url"
  else
    echo "[aria2] Downloading $url"

    aria2c -x 4 -s 4 -k 1M \
      --file-allocation=none \
      --continue=true \
      --allow-overwrite=true \
      --max-tries=10 \
      --retry-wait=3 \
      -o "$(basename "$dst")" \
      -d "$(dirname "$dst")" \
      "$url"
  fi
}

# ===== PART 1: PROVER SETUP =====
rm -rf ~/cysic-prover
mkdir -p ~/cysic-prover
cd ~/cysic-prover

download_file "https://github.com/cysic-labs/cysic-mainnet-scripts/releases/download/v2.0.1/prover_linux" "./prover"
download_file "https://github.com/cysic-labs/cysic-mainnet-scripts/releases/download/v2.0.1/libdarwin_prover.so" "./libzkp.so"
download_file "https://github.com/cysic-labs/cysic-mainnet-scripts/releases/download/v2.0.1/libcysnet_monitor.so" "./libcysnet_monitor.so"
download_file "https://github.com/cysic-labs/cysic-mainnet-scripts/releases/download/v2.0.1/librsp_prover.so" "./librsp.so"
download_file "https://github.com/cysic-labs/cysic-mainnet-scripts/releases/download/v2.0.1/imetadata.bin" "./imetadata.bin"

chmod +x prover

# config
cat <<EOF > config.yaml
chain:
  endpoint: "grpc01.prover.xyz:9090"
  chain_id: "cysicmint_4399-1"
  gas_coin: "CYS"
  gas_price: 250000000000
  gas_limit: 300000

asset_path: ./data/assets
claim_reward_address: "$CLAIM_REWARD_ADDRESS"

bid: "0.1"

server:
  cysic_endpoint: "https://api.prover.xyz"

available_task_type:
  - venus
EOF

echo "LD_LIBRARY_PATH=. CHAIN_ID=534352 ./prover" > start.sh
chmod +x start.sh

# ===== PART 2: VENUS BACKEND SETUP =====

VENUS_DIR="$HOME/venus_v0_1_6"

ZISK_URL="https://public.prover.xyz/vadcop_final/venus_v0_1_6_backend_with_runtime.tar.zst"

BACKEND_SM89="https://public.prover.xyz/vadcop_final/venus_backend_sm_89.tar.zst"
BACKEND_SM120="https://public.prover.xyz/vadcop_final/venus_backend_sm_120.tar.zst"

mkdir -p "$HOME"

# ===== NVIDIA DRIVER + CUDA SETUP =====
if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "[INFO] NVIDIA driver not found. Installing..."

  sudo apt update

  # install kernel headers (important for driver build)
  sudo apt install -y linux-headers-$(uname -r)

  # install NVIDIA driver (535 is stable for most GPUs)
  sudo apt install -y nvidia-driver-535

  echo "[INFO] Driver installed. Reboot is REQUIRED."
  echo "Please run: sudo reboot"
  exit 0
fi

# verify driver actually works
if ! nvidia-smi >/dev/null 2>&1; then
  echo "[ERROR] nvidia-smi exists but GPU not accessible"
  exit 1
fi

echo "[OK] NVIDIA driver detected:"
nvidia-smi

# Detect GPU
GPU_MODEL=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1 || echo "")

if [[ "$GPU_MODEL" == *"50"* ]]; then
  BACKEND_URL="$BACKEND_SM120"
else
  BACKEND_URL="$BACKEND_SM89"
fi

echo "GPU: $GPU_MODEL"
echo "Using backend: $BACKEND_URL"

# Download (sequential but reliable)
download_file "$BACKEND_URL" "$HOME/backend.tar.zst"
download_file "$ZISK_URL" "$HOME/zisk.tar.zst"

# ===== SAFETY CHECK =====

# Extract backend
rm -rf "$VENUS_DIR"
mkdir -p "$VENUS_DIR"
tar --zstd -xf "$HOME/backend.tar.zst" -C "$VENUS_DIR"

# ===== Extract provingKey safely (correct path) =====

mkdir -p "$VENUS_DIR"

tar --zstd -xf "$HOME/zisk.tar.zst" \
  -C "$VENUS_DIR" \
  build/provingKey

# Ensure correct final structure
if [ ! -d "$VENUS_DIR/build/provingKey" ]; then
  FOUND_DIR=$(find "$VENUS_DIR" -type d -path '*/build/provingKey' | head -n 1)
  mv "$FOUND_DIR" "$VENUS_DIR/build/provingKey"
fi

# Link runtime
mkdir -p "$HOME/.zisk/zisk" "$HOME/.zisk/bin"
ln -sfn "$VENUS_DIR/emulator-asm" "$HOME/.zisk/zisk/emulator-asm"
ln -sfn "$VENUS_DIR/target/release/libziskclib.a" "$HOME/.zisk/bin/libziskclib.a"

# ===== PART 3 =====
download_file "https://github.com/cysic-labs/cysic-mainnet-scripts/releases/download/venus-prover-community-v0.1.16/venus_prover_server" "$HOME/venus_prover_server"
chmod +x "$HOME/venus_prover_server"

# ===== START =====
echo "Starting Venus prover..."
VENUS_PROVER_GRPC_PORT=7000 \
VENUS_DIR="$HOME/venus_v0_1_6" \
VENUS_OUT_DIR="$VENUS_DIR/tmp" \
RUST_LOG=info \
"$HOME/venus_prover_server"
