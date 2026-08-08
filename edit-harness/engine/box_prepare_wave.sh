#!/usr/bin/env bash
# Prepare and verify one 2026-07-26 GPU wave on a fresh AutoDL box.
# Usage: bash engine/box_prepare_wave.sh WAVE {deps|download|check}
set -u

WAVE="${1:-}"
ACTION="${2:-}"
H="${HARNESS:-/root/edit-harness}"
PY="${CLOUD_PY:-python3}"
DATA_DISK="${DATA_DISK:-/root/autodl-tmp}"
MODEL_ROOT="$H/data/models"
DATA="$H/data/counterfact.json"
EXPECTED_DATA_SHA="d017056125178a13728594e66a801357a8db9ed7973a7425554bb4271de9fc6f"
FAILED=0

usage(){
  echo "usage: $0 {deletion-wave1|deletion-wave2|paperb-curve|d2-prospective} {deps|download|check}" >&2
  exit 2
}
[ -n "$WAVE" ] && [ -n "$ACTION" ] || usage

log(){ echo "[prepare:$WAVE] $*"; }
fail(){ log "FAIL $*"; FAILED=1; }
need_file(){ [ -f "$1" ] || fail "missing file $1"; }
need_dir(){ [ -d "$1" ] || fail "missing directory $1"; }

wave_spec(){
  case "$WAVE" in
    deletion-wave1)
      echo "2 23000 55"
      echo "mistralai/Mistral-7B-v0.3|Mistral-7B-v0.3|7.248e9"
      echo "Qwen/Qwen2.5-7B|Qwen2.5-7B|7.616e9"
      echo "meta-llama/Llama-3.1-8B|Llama-3.1-8B|8.03e9"
      ;;
    deletion-wave2)
      echo "1 80000 75"
      echo "meta-llama/Llama-2-13b-hf|Llama-2-13b-hf|13.016e9"
      echo "Qwen/Qwen2.5-14B|Qwen2.5-14B|14.77e9"
      ;;
    paperb-curve)
      echo "1 80000 25"
      echo "meta-llama/Llama-3.1-8B|Llama-3.1-8B|8.03e9"
      ;;
    d2-prospective)
      echo "1 23000 20"
      echo "mistralai/Mistral-7B-v0.3|Mistral-7B-v0.3|7.248e9"
      ;;
    *) usage ;;
  esac
}

model_lines(){ wave_spec | tail -n +2; }

phase_deps(){
  command -v "$PY" >/dev/null 2>&1 || { fail "$PY not found"; return; }
  "$PY" - <<'PY' || fail "CUDA-compatible torch is absent"
import torch
print("torch", torch.__version__, "cuda_available", torch.cuda.is_available())
PY
  local missing
  missing=$($PY - <<'PY'
import importlib.util
mods={"numpy":"numpy","scipy":"scipy","transformers":"transformers","huggingface_hub":"huggingface_hub","bitsandbytes":"bitsandbytes"}
print(" ".join(pkg for pkg,mod in mods.items() if importlib.util.find_spec(mod) is None))
PY
)
  if [ -n "$missing" ]; then
    log "installing tested non-torch dependency set because these are missing: $missing"
    "$PY" -m pip install -r "$H/requirements-box-waves.txt" || fail "dependency installation failed"
  fi
  "$PY" - <<'PY' || fail "runtime dependency import failed"
import numpy, scipy, transformers, huggingface_hub, bitsandbytes
print("dependency imports PASS")
PY
  [ "$FAILED" -eq 0 ] && log "DEPS READY"
}

phase_download(){
  need_dir "$DATA_DISK"
  need_dir "$H"
  [ "$FAILED" -eq 0 ] || return
  read -r _ _ need_gb < <(wave_spec | head -1)
  avail=$(df --output=avail -BG "$DATA_DISK" 2>/dev/null | tail -1 | tr -dc 0-9)
  [ -n "$avail" ] && [ "$avail" -ge "$need_gb" ] || {
    fail "$DATA_DISK has ${avail:-?}GB free; wave needs at least ${need_gb}GB before download"
    return
  }
  mkdir -p "$DATA_DISK/models" "$H/data"
  if [ -d "$MODEL_ROOT" ] && [ ! -L "$MODEL_ROOT" ]; then
    if [ -z "$(find "$MODEL_ROOT" -mindepth 1 -maxdepth 1 2>/dev/null)" ]; then
      rmdir "$MODEL_ROOT"
    else
      fail "$MODEL_ROOT is a non-empty real directory; move it to $DATA_DISK/models before downloading"
      return
    fi
  fi
  ln -sfn "$DATA_DISK/models" "$MODEL_ROOT"
  export HF_HOME="$DATA_DISK/hf_cache"
  unset HF_ENDPOINT ALL_PROXY all_proxy
  [ -f /etc/network_turbo ] && source /etc/network_turbo
  while IFS='|' read -r repo name expected; do
    target="$MODEL_ROOT/$name"
    if [ -d "$target" ] && "$PY" "$H/experiments/tools/integrity_check.py" "$target" --expect_params "$expected" >/dev/null 2>&1; then
      log "skip $repo: integrity check already passes at $target"
      continue
    fi
    if [ -d "$target" ]; then
      log "$target exists but integrity is incomplete/invalid; snapshot_download will resume it"
    fi
    log "downloading $repo -> $target"
    REPO_ID="$repo" TARGET_DIR="$target" "$PY" - <<'PY' || { fail "download failed: $repo"; break; }
import os
from huggingface_hub import snapshot_download
snapshot_download(
    repo_id=os.environ["REPO_ID"],
    local_dir=os.environ["TARGET_DIR"],
    ignore_patterns=["*.bin", "*.pth", "*.h5", "*.msgpack"],
)
PY
  done < <(model_lines)
  [ "$FAILED" -eq 0 ] && log "DOWNLOAD READY"
}

check_gpu(){
  command -v nvidia-smi >/dev/null 2>&1 || { fail "nvidia-smi unavailable; switch from no-card to GPU mode"; return; }
  read -r need_cards need_mib _ < <(wave_spec | head -1)
  mapfile -t mems < <(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | tr -dc '0-9\n')
  [ "${#mems[@]}" -ge "$need_cards" ] || fail "need $need_cards GPU(s), found ${#mems[@]}"
  for ((i=0; i<need_cards && i<${#mems[@]}; i++)); do
    [ "${mems[$i]}" -ge "$need_mib" ] || fail "GPU $i has ${mems[$i]}MiB, need >=${need_mib}MiB"
  done
  "$PY" - <<'PY' || fail "torch does not see CUDA"
import torch
assert torch.cuda.is_available()
print("torch CUDA devices", torch.cuda.device_count())
PY
}

check_prereg(){
  case "$WAVE" in
    deletion-wave1|deletion-wave2) prereg="$H/docs/plans/PREREG-DELETION-PREDICTOR-2026-07-26.md" ;;
    paperb-curve) prereg="$H/docs/plans/PREREG-PAPERB-CURVE-2026-07-26.md" ;;
    d2-prospective) prereg="$H/docs/plans/PREREG-D2-PROSPECTIVE-2026-07-26.md" ;;
  esac
  need_file "$prereg"
  [ -f "$prereg" ] && grep -qx 'STATUS: RATIFIED' "$prereg" || fail "prereg is not ratified: $prereg"
}

check_receipts(){
  case "$WAVE" in
    deletion-wave1)
      need_file "$H/engine/DELETION_PHASEL_GD1_PASS.ok"
      need_file "$H/engine/DELETION_PHASEL_GD2_PASS.ok"
      need_file "$H/engine/DELETION_PHASEL_TEXT_PASS.ok"
      ;;
    deletion-wave2) need_file "$H/engine/DELETION_WAVE1_GD3_PASS.ok" ;;
    paperb-curve) need_file "$H/engine/PAPERB_CURVE_GS3_PASS.ok" ;;
  esac
}

check_models(){
  while IFS='|' read -r repo name expected; do
    dir="$MODEL_ROOT/$name"
    need_dir "$dir"
    [ -d "$dir" ] || continue
    "$PY" "$H/experiments/tools/integrity_check.py" "$dir" --expect_params "$expected" \
      || fail "model integrity failed: $name"
  done < <(model_lines)
}

check_wave_inputs(){
  need_file "$DATA"
  if [ -f "$DATA" ]; then
    got=$(sha256sum "$DATA" | cut -d' ' -f1)
    [ "$got" = "$EXPECTED_DATA_SHA" ] || fail "counterfact sha256 $got != expected $EXPECTED_DATA_SHA"
  fi
  case "$WAVE" in
    deletion-wave1)
      for tag in gate_mistral7b_rome_cf_L24 gate_llama8b_rome_cf_L24; do
        for seed in 0 1 2; do need_file "$H/results/matrices/${tag}_s${seed}.npz"; done
      done
      need_file "$H/run_deletion_wave1.sh"
      ;;
    deletion-wave2) need_file "$H/run_deletion_wave2.sh" ;;
    paperb-curve) need_file "$H/run_paperb_curve_cloud.sh" ;;
    d2-prospective) need_file "$H/run_d2_prospective_cloud.sh" ;;
  esac
}

check_cli(){
  "$PY" "$H/experiments/killgate_keygeom.py" --help >/dev/null || fail "killgate CLI broken"
  case "$WAVE" in
    paperb-curve) "$PY" "$H/experiments/quant_survival_phase1.py" --selftest >/tmp/paperb-selftest.log 2>&1 || fail "Paper B CPU selftest failed" ;;
    d2-prospective) "$PY" "$H/experiments/prospective_admission.py" --selftest >/tmp/d2-selftest.log 2>&1 || fail "D2 CPU selftest failed" ;;
  esac
}

# Regression lock for the 2026-07-30 Phi-3.5 first-token collision: every model a
# wave touches must map the actual wave targets to distinct first CONTENT tokens.
# Tokenizer-only, CPU, seconds per model — runs BEFORE any GPU spend. The deletion
# refusal target is included because it replaces target_new in deletion arms.
check_tokenizer_gate(){
  local -a extra_targets=()
  case "$WAVE" in
    deletion-wave1|deletion-wave2) extra_targets=(--extra-target "I cannot answer") ;;
  esac
  while IFS='|' read -r repo name expected; do
    dir="$MODEL_ROOT/$name"
    [ -d "$dir" ] || { fail "tokenizer gate: missing model dir $dir"; continue; }
    if ! "$PY" "$H/experiments/assert_targets_distinguishable.py" \
      --tokenizer "$dir" --data "$DATA" --label "$name" "${extra_targets[@]}"; then
      fail "tokenizer gate FAIL: $name (wave blocked; inspect TOKENIZER-GATE diagnostics above)"
    fi
  done < <(model_lines)
}

phase_check(){
  case "$WAVE" in
    deletion-wave1) driver="$H/run_deletion_wave1.sh" ;;
    deletion-wave2) driver="$H/run_deletion_wave2.sh" ;;
    paperb-curve) driver="$H/run_paperb_curve_cloud.sh" ;;
    d2-prospective) driver="$H/run_d2_prospective_cloud.sh" ;;
  esac
  ready="$H/engine/BOX_READY_${WAVE}.ok"
  rm -f "$ready"
  need_dir "$H"
  need_file "$H/requirements-box-waves.txt"
  need_file "$driver"
  "$H/engine/box_preflight.sh" "$WAVE" || { fail "box preflight blocked"; return; }
  check_gpu
  check_prereg
  check_receipts
  check_models
  check_wave_inputs
  check_cli
  check_tokenizer_gate
  if [ "$FAILED" -eq 0 ]; then
    {
      printf 'READY wave=%s host=%s at=%s\n' "$WAVE" "$(hostname)" "$(date -u '+%FT%TZ')"
      printf 'host=%s\n' "$(hostname)"
      printf 'driver_sha256=%s\n' "$(sha256sum "$driver" | cut -d' ' -f1)"
      printf 'prepare_sha256=%s\n' "$(sha256sum "$0" | cut -d' ' -f1)"
      printf 'counterfact_sha256=%s\n' "$EXPECTED_DATA_SHA"
    } > "$ready"
    log "READY receipt: $ready"
  else
    log "BLOCKED: fix every FAIL line before launching science"
  fi
  return "$FAILED"
}

case "$ACTION" in
  deps) phase_deps ;;
  download) phase_download ;;
  check) phase_check ;;
  *) usage ;;
esac
exit "$FAILED"
