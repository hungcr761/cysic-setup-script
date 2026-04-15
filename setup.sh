#!/bin/bash

# ===== INPUT =====
if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <claim_reward_address>"
  exit 1
fi
CLAIM_REWARD_ADDRESS=$1

# ===== CONFIG =====
BASE_DIR="$HOME/cysic-prover"
VENUS_DIR="$HOME/venus_v0_1_6"

ZISK_URL_1="https://public.prover.xyz/vadcop_final/venus_v0_1_6_backend_with_runtime.tar.zst"
ZISK_URL_2="https://cys.atl1.cdn.digitaloceanspaces.com/cys/venus_v0_1_6_backend_with_runtime.tar.zst"
BACKEND_SM89="https://public.prover.xyz/vadcop_final/venus_backend_sm_89.tar.zst"
BACKEND_SM120="https://public.prover.xyz/vadcop_final/venus_backend_sm_120.tar.zst"

# ===== ENSURE DEPENDENCIES =====
if ! command -v aria2c >/dev/null 2>&1; then
  sudo apt update && sudo apt install -y aria2
fi

apt-get update -y
apt-get install -y \
  ca-certificates curl wget tar zstd \
  libssl3 libstdc++6 libgmp10 libgmp-dev libsodium23 libomp5 \
  openmpi-bin libopenmpi3 libopenmpi-dev libhwloc15 \
  libz1 libevent-2.1-7 libevent-pthreads-2.1-7 libudev1 libcap2 \
  ripgrep build-essential binutils

# ===== CUDA (install once) =====


# ===== DOWNLOAD FUNCTION =====
download_file() {
  local url="$1"
  local dst="$2"

  if [ -s "$dst" ]; then
    echo "[SKIP] $dst already exists"
    return
  fi

  echo "[DOWNLOAD] $url"

  if [[ "$url" == *"github.com"* ]]; then
    # Use curl for GitHub (more stable with redirects/releases)
    curl -L --fail \
      --retry 10 \
      --retry-delay 5 \
      --connect-timeout 30 \
      -C - \
      -o "$dst" \
      "$url"
  else
    # Use aria2c with 4 parallel connections for others
    aria2c -x 4 -s 4 -k 1M \
      --file-allocation=none \
      --continue=true \
      --max-tries=10 \
      --retry-wait=3 \
      -o "$(basename "$dst")" \
      -d "$(dirname "$dst")" \
      "$url"
  fi
}

# ===== GPU CHECK =====
if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "[INFO] Installing NVIDIA driver..."
  sudo apt install -y linux-headers-$(uname -r)
  sudo apt install -y nvidia-driver-535
  echo "Reboot required: sudo reboot"
  exit 0
fi

if ! nvidia-smi >/dev/null 2>&1; then
  echo "[ERROR] GPU not accessible"
  exit 1
fi

GPU_MODEL=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1 || echo "")
if [[ "$GPU_MODEL" == *"50"* ]]; then
  BACKEND_URL="$BACKEND_SM120"
else
  BACKEND_URL="$BACKEND_SM89"
fi

echo "GPU: $GPU_MODEL"
echo "Backend: $BACKEND_URL"

# ===== PREPARE DIRS =====
mkdir -p "$BASE_DIR"
mkdir -p "$VENUS_DIR"
cd "$BASE_DIR"

# ===== PART 1: PROVER FILES =====
download_file "https://github.com/cysic-labs/cysic-mainnet-scripts/releases/download/v2.0.1/prover_linux" "./prover"
download_file "https://github.com/cysic-labs/cysic-mainnet-scripts/releases/download/v2.0.1/libdarwin_prover.so" "./libzkp.so"
download_file "https://github.com/cysic-labs/cysic-mainnet-scripts/releases/download/v2.0.1/libcysnet_monitor.so" "./libcysnet_monitor.so"
download_file "https://github.com/cysic-labs/cysic-mainnet-scripts/releases/download/v2.0.1/librsp_prover.so" "./librsp.so"
download_file "https://github.com/cysic-labs/cysic-mainnet-scripts/releases/download/v2.0.1/imetadata.bin" "./imetadata.bin"

chmod +x prover

# ===== CONFIG =====
if [ ! -f config.yaml ]; then
cat <<EOF > config.yaml
chain:
  endpoint: "grpc01.prover.xyz:9090"
  chain_id: "cysicmint_4399-1"
  gas_coin: "CYS"
  gas_price: 3000000000
  gas_limit: 300000

asset_path: ./data/assets
claim_reward_address: "$CLAIM_REWARD_ADDRESS"

bid: "0.1"

server:
  cysic_endpoint: "https://api.prover.xyz"

available_task_type:
  - venus
EOF
fi

echo "LD_LIBRARY_PATH=. CHAIN_ID=534352 ./prover" > start.sh
chmod +x start.sh
# ========
pick_fastest_url() {
  local url1="$1"
  local url2="$2"

  test_speed() {
    local url="$1"
    local s

    s=$(curl -L --fail --range 0-5242879 -o /dev/null -s -w '%{speed_download}' "$url" 2>/dev/null || true)

    # Make sure we always get a numeric value
    [[ "$s" =~ ^[0-9]+([.][0-9]+)?$ ]] || s=0
    printf '%s' "$s"
  }

  local speed1 speed2
  speed1=$(test_speed "$url1")
  speed2=$(test_speed "$url2")

  echo "[TEST] mirror1=$speed1 mirror2=$speed2" >&2

  if awk -v a="$speed1" -v b="$speed2" 'BEGIN { exit !(a > b) }'; then
    printf '%s\n' "$url1"
  elif awk -v a="$speed2" -v b="$speed1" 'BEGIN { exit !(a > b) }'; then
    printf '%s\n' "$url2"
  else
    # Fallback so it never returns empty
    printf '%s\n' "$url1"
  fi
}

ZISK_URL="$(pick_fastest_url "$ZISK_URL_1" "$ZISK_URL_2")"
if [ -z "$ZISK_URL" ]; then
  ZISK_URL="$ZISK_URL_1"
fi
echo "[SELECTED MIRROR] $ZISK_URL"

# ===== PART 2: DOWNLOAD BACKEND =====
download_file "$BACKEND_URL" "$HOME/backend.tar.zst"
download_file "$ZISK_URL" "$HOME/zisk.tar.zst"

# ===== EXTRACT BACKEND =====
if [ ! -d "$VENUS_DIR/target" ]; then
  echo "[EXTRACT] backend"
  tar --zstd -xf "$HOME/backend.tar.zst" -C "$VENUS_DIR"
else
  echo "[SKIP] backend already extracted"
fi

# ===== EXTRACT PROVING KEY =====
if [ ! -d "$VENUS_DIR/build/provingKey" ]; then
  echo "[EXTRACT] provingKey"
  tar --zstd -xf "$HOME/zisk.tar.zst" -C "$VENUS_DIR" build/provingKey
else
  echo "[SKIP] provingKey exists"
fi

# ===== ENSURE RUNTIME BINARY =====
if [ ! -f "$VENUS_DIR/target/release/cargo-zisk" ]; then
  echo "[EXTRACT] cargo-zisk"
  tar --zstd -xf "$HOME/zisk.tar.zst" -C "$VENUS_DIR" target/release/cargo-zisk || true

  if [ ! -f "$VENUS_DIR/target/release/cargo-zisk" ]; then
    FOUND_CARGO=$(find "$VENUS_DIR" -type f -name cargo-zisk | head -n 1)
    if [ -n "$FOUND_CARGO" ]; then
      mkdir -p "$VENUS_DIR/target/release"
      cp -f "$FOUND_CARGO" "$VENUS_DIR/target/release/cargo-zisk"
    fi
  fi

  chmod +x "$VENUS_DIR/target/release/cargo-zisk" 2>/dev/null || true
else
  echo "[SKIP] cargo-zisk exists"
fi

# ===== FIX STRUCTURE =====
if [ ! -d "$VENUS_DIR/build/provingKey" ]; then
  FOUND=$(find "$VENUS_DIR" -type d -path '*/build/provingKey' | head -n 1)
  [ -n "$FOUND" ] && mv "$FOUND" "$VENUS_DIR/build/provingKey"
fi

# ===== LINK =====
mkdir -p "$HOME/.zisk/zisk" "$HOME/.zisk/bin"
ln -sfn "$VENUS_DIR/emulator-asm" "$HOME/.zisk/zisk/emulator-asm"
ln -sfn "$VENUS_DIR/target/release/libziskclib.a" "$HOME/.zisk/bin/libziskclib.a"

# ===== PART 3 =====
download_file "https://github.com/cysic-labs/cysic-mainnet-scripts/releases/download/venus-prover-community-v0.1.16/venus_prover_server" "$HOME/venus_prover_server"
chmod +x "$HOME/venus_prover_server"

"$HOME/venus_prover_server"
