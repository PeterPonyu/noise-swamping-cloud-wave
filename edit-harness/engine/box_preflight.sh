#!/usr/bin/env bash
# Run on every newly rented GPU box before downloading models or launching a driver.
# Blocking image/dependency defects exit immediately. Hugging Face authentication is
# advisory because public-model waves can run without a token.
set -Eeuo pipefail

WAVE="${1:-generic}"
PY="${CLOUD_PY:-${PY:-python3}}"
DATA_DISK="${DATA_DISK:-/root/autodl-tmp}"
NVIDIA_SMI="${NVIDIA_SMI:-nvidia-smi}"

case "$WAVE" in
  generic|deletion-wave1|deletion-wave2|paperb-curve|d2-prospective) ;;
  *)
    echo "usage: $0 [generic|deletion-wave1|deletion-wave2|paperb-curve|d2-prospective]" >&2
    exit 2
    ;;
esac

ok() { printf 'OK   %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*" >&2; }
die() {
  printf 'FAIL %s\n' "$*" >&2
  printf 'PREFLIGHT_BLOCKED wave=%s host=%s\n' "$WAVE" "$(hostname)" >&2
  exit 3
}
need_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}
trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

# The rented image must already contain a CUDA-capable torch build. Installing torch
# after rental is slow and can silently select an incompatible CUDA wheel.
need_command "$PY"
if ! torch_report="$("$PY" - "$WAVE" 2>&1 <<'PY'
import sys

required = 2 if sys.argv[1] == "deletion-wave1" else 1
try:
    import torch
except Exception as exc:
    raise SystemExit(f"torch import failed: {exc}") from exc
if not torch.cuda.is_available():
    raise SystemExit("torch is installed but CUDA is unavailable")
count = torch.cuda.device_count()
if count < required:
    raise SystemExit(f"torch sees {count} CUDA card(s), need at least {required}")
print(f"torch={torch.__version__} cuda={torch.version.cuda} devices={count}")
PY
)"; then
  die "torch/CUDA probe failed: $torch_report"
fi
ok "$torch_report"

if ! dependency_report="$($PY - <<'PY' 2>&1
import importlib

required = ("numpy", "scipy", "transformers", "huggingface_hub", "bitsandbytes")
missing = []
versions = []
for name in required:
    try:
        module = importlib.import_module(name)
    except Exception as exc:
        missing.append(f"{name}: {exc}")
        continue
    versions.append(f"{name}={getattr(module, '__version__', '?')}")
if missing:
    raise SystemExit("; ".join(missing))
print(" ".join(versions))
PY
)"; then
  die "runtime dependency probe failed: $dependency_report"
fi
ok "runtime dependencies: $dependency_report"

# Models must go to the large data volume, never the small system disk.
[ -d "$DATA_DISK" ] || die "DATA_DISK does not exist: $DATA_DISK"
[ -r "$DATA_DISK" ] || die "DATA_DISK is not readable: $DATA_DISK"
[ -w "$DATA_DISK" ] || die "DATA_DISK is not writable: $DATA_DISK"
avail_gb="$(df --output=avail -BG "$DATA_DISK" 2>/dev/null | tail -n 1 | tr -dc '0-9')"
[ -n "$avail_gb" ] || die "cannot determine free space on DATA_DISK: $DATA_DISK"
ok "DATA_DISK=$DATA_DISK available=${avail_gb}GB"

# nvidia-smi is the authoritative physical-card view. For deletion-wave1, cards 0 and 1
# are used concurrently, so both product name and VRAM must match.
need_command "$NVIDIA_SMI"
if ! gpu_inventory="$($NVIDIA_SMI --query-gpu=index,name,memory.total --format=csv,noheader,nounits 2>/dev/null)"; then
  die "nvidia-smi GPU inventory query failed"
fi
[ -n "$gpu_inventory" ] || die "nvidia-smi sees no GPUs"
mapfile -t gpu_rows <<< "$gpu_inventory"
ok "nvidia-smi sees ${#gpu_rows[@]} card(s)"

if [ "$WAVE" = "deletion-wave1" ]; then
  [ "${#gpu_rows[@]}" -ge 2 ] || die "deletion-wave1 needs 2 cards, found ${#gpu_rows[@]}"
  IFS=',' read -r gpu0_index gpu0_name gpu0_mem <<< "${gpu_rows[0]}"
  IFS=',' read -r gpu1_index gpu1_name gpu1_mem <<< "${gpu_rows[1]}"
  gpu0_index="$(trim "$gpu0_index")"
  gpu1_index="$(trim "$gpu1_index")"
  [ "$gpu0_index" = "0" ] || die "deletion-wave1 GPU0 inventory row has physical index $gpu0_index"
  [ "$gpu1_index" = "1" ] || die "deletion-wave1 GPU1 inventory row has physical index $gpu1_index"
  gpu0_name="$(trim "$gpu0_name")"
  gpu1_name="$(trim "$gpu1_name")"
  gpu0_mem="$(trim "$gpu0_mem")"
  gpu1_mem="$(trim "$gpu1_mem")"
  [ "$gpu0_name" = "$gpu1_name" ] || \
    die "deletion-wave1 cards are not uniform: GPU0=$gpu0_name GPU1=$gpu1_name"
  [ "$gpu0_mem" = "$gpu1_mem" ] || \
    die "deletion-wave1 cards are not uniform: GPU0=${gpu0_mem}MiB GPU1=${gpu1_mem}MiB"
  ok "deletion-wave1 cards 0/1 uniform: $gpu0_name ${gpu0_mem}MiB"
fi

# Verify token validity when one is present. Absence, invalid credentials, and transient
# network failures are WARN-only; the per-wave download step decides whether a gated
# repository actually requires authentication. This advisory network probe deliberately
# runs after every fatal image check.
hf_token="${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}"
hf_token_source="environment"
if [ -z "$hf_token" ]; then
  hf_token_source=""
  for token_file in \
    "${HF_HOME:-$HOME/.cache/huggingface}/token" \
    "$HOME/.cache/huggingface/token" \
    "$HOME/.huggingface/token"; do
    if [ -s "$token_file" ]; then
      IFS= read -r hf_token < "$token_file" || true
      hf_token_source="$token_file"
      break
    fi
  done
fi
if [ -z "$hf_token" ]; then
  warn "no Hugging Face token found; gated repositories may return 401/403"
else
  if hf_identity="$(HF_PREFLIGHT_TOKEN="$hf_token" "$PY" - <<'PY' 2>&1
import json
import os
import urllib.error
import urllib.request

request = urllib.request.Request(
    "https://huggingface.co/api/whoami-v2",
    headers={"Authorization": f"Bearer {os.environ['HF_PREFLIGHT_TOKEN']}"},
)
try:
    with urllib.request.urlopen(request, timeout=8) as response:
        payload = json.load(response)
except urllib.error.HTTPError as exc:
    raise SystemExit(f"HTTP {exc.code}") from None
except urllib.error.URLError as exc:
    raise SystemExit(f"network error: {exc.reason}") from None
except TimeoutError:
    raise SystemExit("network timeout") from None
name = payload.get("name") or payload.get("fullname")
if not name:
    raise SystemExit("authentication response has no account name")
print(name)
PY
  )"; then
    ok "HF token authenticated as $hf_identity (source=$hf_token_source)"
  else
    hf_error="${hf_identity%%$'\n'*}"
    warn "HF token could not be authenticated (source=$hf_token_source): $hf_error"
  fi
fi

printf 'PREFLIGHT_GREEN wave=%s host=%s\n' "$WAVE" "$(hostname)"
