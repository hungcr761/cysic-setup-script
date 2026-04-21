#!/usr/bin/env bash

main() {
set -euo pipefail

CLAIM_REWARD_ADDRESS="0xaf8fbf566b8d9fb04a983327f2a10f57d1f729ef"

CYSIC_DIR="$HOME/cysic-prover"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENUS_DIR="${VENUS_DIR:-$HOME/venus_v0_1_6}"
BACKEND_BUNDLE_SM75_URL="${BACKEND_BUNDLE_SM75_URL:-https://public.prover.xyz/vadcop_final/venus_backend_sm_75.tar.zst}"
BACKEND_BUNDLE_SM86_URL="${BACKEND_BUNDLE_SM86_URL:-https://public.prover.xyz/vadcop_final/venus_backend_sm_86.tar.zst}"
BACKEND_BUNDLE_SM89_URL="${BACKEND_BUNDLE_SM89_URL:-https://public.prover.xyz/vadcop_final/venus_backend_sm_89.tar.zst}"
BACKEND_BUNDLE_SM120_URL="${BACKEND_BUNDLE_SM120_URL:-https://public.prover.xyz/vadcop_final/venus_backend_sm_120.tar.zst}"
DOWNLOAD_TOOL="${DOWNLOAD_TOOL:-curl}"
PORT="${PORT:-7000}"
GPU="${GPU:-}"
CYSIC_RELEASE_BASE_URL="https://github.com/cysic-labs/cysic-mainnet-scripts/releases/download/v2.0.1"
PROVER_RELEASE_BASE_URL="${PROVER_RELEASE_BASE_URL:-https://github.com/cysic-labs/cysic-mainnet-scripts/releases/download/venus-prover-community-v0.1.16}"
PROVER_SERVER_BIN="${PROVER_SERVER_BIN:-$SCRIPT_DIR/venus_prover_server}"
PROVER_DEMO_BIN="${PROVER_DEMO_BIN:-$SCRIPT_DIR/venus_prover_demo}"

if ! command -v apt-get >/dev/null 2>&1; then
  echo "apt-get not found. This script expects Ubuntu/Debian." >&2
  exit 1
fi

if [[ "$(id -u)" -eq 0 ]]; then
  SUDO=()
else
  if ! command -v sudo >/dev/null 2>&1; then
    echo "sudo not found." >&2
    exit 1
  fi
  SUDO=(sudo)
fi

is_github_url() {
  [[ "$1" == https://github.com/* || "$1" == https://raw.githubusercontent.com/* ]]
}

download_file() {
  local url="$1"
  local dst="$2"

  if is_github_url "$url"; then
    if [[ "$DOWNLOAD_TOOL" == "wget" ]]; then
      wget -O "$dst" "$url"
    else
      curl -L --fail --output "$dst" "$url"
    fi
  else
    if ! command -v aria2c >/dev/null 2>&1; then
      "${SUDO[@]}" apt-get install -y aria2
    fi
    aria2c --split=4 --max-connection-per-server=4 --min-split-size=10M \
           --out="$(basename "$dst")" --dir="$(dirname "$dst")" \
           --allow-overwrite=true "$url"
  fi
}

download_or_copy_file() {
  local src="$1"
  local dst="$2"
  case "$src" in
    http://*|https://*) download_file "$src" "$dst" ;;
    file://*) cp "${src#file://}" "$dst" ;;
    *) cp "$src" "$dst" ;;
  esac
}

link_zisk_runtime() {
  mkdir -p "$HOME/.zisk/zisk" "$HOME/.zisk/bin"
  rm -rf "$HOME/.zisk/zisk/emulator-asm"
  rm -f "$HOME/.zisk/bin/libziskclib.a"
  ln -sfn "$VENUS_DIR/emulator-asm" "$HOME/.zisk/zisk/emulator-asm"
  ln -sfn "$VENUS_DIR/target/release/libziskclib.a" "$HOME/.zisk/bin/libziskclib.a"
  
}

checksum_value() {
  awk '{print $1}' "$1" | head -n 1
}

verify_cached_bundle() {
  local bundle_file="$1" sha_file="$2" label="$3"
  local expected_sha actual_sha
  expected_sha="$(checksum_value "$sha_file")"
  actual_sha="$(sha256sum "$bundle_file" | awk '{print $1}')"
  [[ "$expected_sha" == "$actual_sha" ]]
}

prepare_cached_bundle() {
  local bundle_url="$1" sha_url="$2" bundle_file="$3" sha_file="$4" label="$5"

  download_or_copy_file "$sha_url" "$sha_file"

  if [[ -f "$bundle_file" ]] && verify_cached_bundle "$bundle_file" "$sha_file" "$label"; then
    return
  fi

  download_or_copy_file "$bundle_url" "$bundle_file"
}

has_nvidia_driver() {
  command -v nvidia-smi >/dev/null 2>&1
}

detect_gpu_model() {
  nvidia-smi --query-gpu=name --format=csv,noheader | head -n 1
}

select_backend_bundle() {
  local gpu_model="$1"
  case "$gpu_model" in
    *"RTX 20"*|*"T4"*) printf '%s\n' "$BACKEND_BUNDLE_SM75_URL" ;;
    *"RTX 30"*|*"A10"*|*"A40"*|*"A30"*) printf '%s\n' "$BACKEND_BUNDLE_SM86_URL" ;;
    *"RTX 40"*|*"L4"*|*"L40"*) printf '%s\n' "$BACKEND_BUNDLE_SM89_URL" ;;
    *"RTX 50"*) printf '%s\n' "$BACKEND_BUNDLE_SM120_URL" ;;
    *) echo "Unsupported GPU: $gpu_model" >&2; exit 2 ;;
  esac
}

echo "==> Setting up cysic-prover..."
rm -rf "$CYSIC_DIR"
mkdir -p "$CYSIC_DIR"

curl -L "$CYSIC_RELEASE_BASE_URL/prover_linux" > "$CYSIC_DIR/prover"
curl -L "$CYSIC_RELEASE_BASE_URL/libdarwin_prover.so" > "$CYSIC_DIR/libzkp.so"
curl -L "$CYSIC_RELEASE_BASE_URL/libcysnet_monitor.so" > "$CYSIC_DIR/libcysnet_monitor.so"
curl -L "$CYSIC_RELEASE_BASE_URL/librsp_prover.so" > "$CYSIC_DIR/librsp.so"

chmod +x "$CYSIC_DIR/prover"

echo "LD_LIBRARY_PATH=. CHAIN_ID=534352 ./prover" > "$CYSIC_DIR/start.sh"
chmod +x "$CYSIC_DIR/start.sh"
cat <<EOF >~/cysic-prover/config.yaml
chain:
  endpoint: "grpc01.prover.xyz:9090"
  chain_id: "cysicmint_4399-1"
  gas_coin: "CYS"
  gas_price: 3000000000
  gas_limit: 300000

######################
#   local  setting   #
######################
# asset file storage path
asset_path: ./data/assets
# reward claim address
claim_reward_address: "$CLAIM_REWARD_ADDRESS"

# prover index (optional)
# index: 0
# bid price: adjust your bid price according to your machine price and reward policy to maximize your earnings
bid: "0.1"

######################
#   server  setting   #
######################
server:
  # cysic server endpoint
  cysic_endpoint: "https://api.prover.xyz"

######################
#   task  setting   #
######################
# available task types: ethProof, scroll
available_task_type:
  - venus
EOF

echo "==> Installing dependencies..."
"${SUDO[@]}" apt-get update
"${SUDO[@]}" apt-get install -y \
  ca-certificates curl wget tar zstd aria2 \
  libssl3 libstdc++6 libgmp10 libsodium23 libomp5 \
  openmpi-bin libopenmpi3 libhwloc15 \
  libz1 libevent-2.1-7 libevent-pthreads-2.1-7 libudev1 libcap2 \
  ripgrep build-essential binutils

if [[ ! -x "$PROVER_SERVER_BIN" ]]; then
  download_file "$PROVER_RELEASE_BASE_URL/venus_prover_server" "$PROVER_SERVER_BIN"
  chmod +x "$PROVER_SERVER_BIN"
fi

if [[ ! -x "$PROVER_DEMO_BIN" ]]; then
  download_file "$PROVER_RELEASE_BASE_URL/venus_prover_demo" "$PROVER_DEMO_BIN"
  chmod +x "$PROVER_DEMO_BIN"
fi

if [[ ! -d "$VENUS_DIR" ]]; then
  gpu_model="$(detect_gpu_model)"
  bundle="$(select_backend_bundle "$gpu_model")"
  archive="$HOME/$(basename "$bundle")"

  download_file "$bundle" "$archive"

  mkdir -p "$VENUS_DIR"
  tar --zstd -xf "$archive" -C "$VENUS_DIR"
fi

mkdir -p "$VENUS_DIR/tmp"

link_zisk_runtime()

exec env \
  VENUS_PROVER_GRPC_PORT="$PORT" \
  VENUS_DIR="$VENUS_DIR" \
  VENUS_OUT_DIR="$VENUS_DIR/tmp" \
  ASM_UNLOCK=true \
  RUST_LOG=info \
  ${GPU:+CUDA_VISIBLE_DEVICES=$GPU} \
  "$PROVER_SERVER_BIN"

}

main "$@"
