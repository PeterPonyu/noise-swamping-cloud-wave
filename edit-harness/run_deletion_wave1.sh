#!/usr/bin/env bash
# Dual-4090D deletion Wave 1. Launch once per card with SHARD=card0/card1.
set -u
H=${H:-/root/edit-harness}; cd "$H" || exit 1
PY=${CLOUD_PY:-python3}; SHARD=${SHARD:-}; GPU_ID=${GPU_ID:-}; WAVE_BOX=${WAVE_BOX:-}
BUDGET_MIN=${BUDGET_MIN:-480}; JOB_CAP_MIN=${JOB_CAP_MIN:-90}; DRYRUN=${DRYRUN:-0}
PREREG=${PREREG:-$H/docs/plans/PREREG-DELETION-PREDICTOR-2026-07-26.md}
[ "$SHARD" = card0 ] || [ "$SHARD" = card1 ] || { echo "ABORT: SHARD must be card0 or card1" >&2; exit 2; }
[ -n "$GPU_ID" ] || { echo "ABORT: GPU_ID is required" >&2; exit 2; }
[ -n "$WAVE_BOX" ] && [ "$WAVE_BOX" = "$(hostname)" ] || { echo "ABORT: WAVE_BOX must equal $(hostname)" >&2; exit 6; }
[ -f "$PREREG" ] && grep -qx 'STATUS: RATIFIED' "$PREREG" || { echo "ABORT: prereg not ratified" >&2; exit 5; }
READY="$H/engine/BOX_READY_deletion-wave1.ok"
[ -f "$READY" ] || { echo "ABORT: run box_prepare_wave.sh deletion-wave1 check first" >&2; exit 8; }
expected_sha=$(sha256sum "$0" | cut -d' ' -f1)
prepare_sha=$(sha256sum "$H/engine/box_prepare_wave.sh" | cut -d' ' -f1)
grep -qx "driver_sha256=$expected_sha" "$READY" || { echo "ABORT: stale BOX_READY receipt for a different driver hash" >&2; exit 8; }
grep -qx "prepare_sha256=$prepare_sha" "$READY" || { echo "ABORT: stale BOX_READY receipt for a different prepare hash" >&2; exit 8; }
"$H/engine/box_preflight.sh" deletion-wave1 || { echo "ABORT: fresh-box preflight failed; do not spend" >&2; exit 8; }
for gate in engine/DELETION_PHASEL_GD1_PASS.ok engine/DELETION_PHASEL_GD2_PASS.ok engine/DELETION_PHASEL_TEXT_PASS.ok; do
  [ -f "$gate" ] || { echo "ABORT: missing Phase-L receipt $gate" >&2; exit 7; }
done
mkdir -p engine results/matrices results/smoke_deletion_wave1
PIDFILE="engine/run_deletion_wave1_${SHARD}.pid"; LOG="engine/run_deletion_wave1_${SHARD}.log"
echo "$BASHPID" > "$PIDFILE"; trap 'rm -f "$PIDFILE"' EXIT
log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }
KG=experiments/killgate_keygeom.py; DATA=data/counterfact.json
COMMON="--dataset counterfact --data $DATA --n_edits 200 --n_probes 500 --steps 20 --lr 0.1 --model_dtype bf16 --save_matrices --matrix_dir results/matrices"
for f in "$KG" experiments/u1_deletion_gate.py "$DATA"; do [ -f "$f" ] || { log "ABORT missing $f"; exit 3; }; done
case "$SHARD" in
 card0) GRID="mistral7b:data/models/Mistral-7B-v0.3:24 qwen7b:data/models/Qwen2.5-7B:21" ;;
 card1) GRID="llama8b:data/models/Llama-3.1-8B:24" ;;
esac
for spec in $GRID; do model=${spec#*:}; model=${model%:*}; [ -d "$model" ] || { log "ABORT missing model $model"; exit 3; }; done
if [ "$DRYRUN" = 1 ]; then log "DRYRUN shard=$SHARD gpu=$GPU_ID grid=$GRID"; exit 0; fi
consec=0; start_gate=$(date +%s)
while [ "$consec" -lt 3 ]; do
  line=$(nvidia-smi -i "$GPU_ID" --query-gpu=utilization.gpu,memory.used --format=csv,noheader,nounits 2>/dev/null | head -1)
  util=$(printf '%s' "$line" | cut -d, -f1 | tr -dc 0-9); mem=$(printf '%s' "$line" | cut -d, -f2 | tr -dc 0-9)
  if [ -n "$util" ] && [ -n "$mem" ] && [ "$util" -lt 25 ] && [ "$mem" -lt 1500 ]; then consec=$((consec+1)); else consec=0; fi
  [ $(( $(date +%s)-start_gate )) -le 1800 ] || { log "ABORT GPU busy >30m"; exit 8; }
  [ "$consec" -eq 3 ] || sleep 30
done
T0=$(date +%s); failures=0; completed=0
case "$SHARD" in card0) expected=9 ;; card1) expected=6 ;; esac
validate(){
  "$PY" - "$1" "$2" <<'PY'
import json,sys,numpy as np
j,n=sys.argv[1:]; d=json.load(open(j)); a=np.load(n,allow_pickle=True)
s=d.get('runner_stamp') or {}; need={'code_sha256','pid','hostname','wall_start','wall_end','elapsed_s','nvidia_smi_sample'}
assert not (need-set(s)), need-set(s)
assert 'runner_stamp_json' in a.files and json.loads(str(a['runner_stamp_json'].item()))['code_sha256']==s['code_sha256']
assert a['COS'].shape==(200,500) and a['damage_logit'].shape==(200,500)
print('VALIDATE-OK')
PY
}
run_cell(){
  tag=$1; est=$2; shift 2; out="results/${tag}.json"; npz="results/matrices/${tag}.npz"
  if [ -f "$out" ] && [ -f "$npz" ] && validate "$out" "$npz" >/dev/null 2>&1; then log "SKIP $tag validated"; completed=$((completed+1)); return; fi
  elapsed=$(( ($(date +%s)-T0)/60 )); [ $((elapsed+est)) -le "$BUDGET_MIN" ] || { log "BUDGET-STOP before $tag"; return; }
  log "RUN $tag"; CUDA_VISIBLE_DEVICES="$GPU_ID" timeout --signal=TERM --kill-after=60 "$((JOB_CAP_MIN*60))s" "$@" --out "$out" >>"engine/${tag}.log" 2>&1
  rc=$?; if [ "$rc" -eq 0 ] && validate "$out" "$npz" >/dev/null 2>&1; then log "DONE $tag"; completed=$((completed+1)); else log "FAIL $tag rc=$rc"; failures=$((failures+1)); fi
  [ "$failures" -lt 2 ] || { log "ABORT after two failures"; exit 9; }
}
for spec in $GRID; do
  tag=${spec%%:*}; rest=${spec#*:}; model=${rest%:*}; layer=${spec##*:}
  smoke="results/smoke_deletion_wave1/${tag}.json"
  if [ ! -f "$smoke" ]; then
    CUDA_VISIBLE_DEVICES="$GPU_ID" timeout 1800 "$PY" "$KG" --model "$model" --editor rome --dataset counterfact --data "$DATA" --n_edits 3 --n_probes 8 --steps 2 --lr 0.1 --layer "$layer" --model_dtype bf16 --out "$smoke" >>"engine/smoke_${tag}.log" 2>&1 || { log "ABORT smoke $tag"; exit 10; }
  fi
  for seed in 0 1 2; do
    if [ "$tag" = qwen7b ]; then
      run_cell "gate_${tag}_rome_cf_L${layer}_s${seed}" 45 "$PY" "$KG" --model "$model" --editor rome $COMMON --layer "$layer" --seed "$seed"
    fi
    run_cell "u1e0_${tag}_delete_refusal_L${layer}_s${seed}" 45 "$PY" "$KG" --model "$model" --editor rome --edit_mode delete --delete_variant refusal $COMMON --layer "$layer" --seed "$seed"
  done
  if [ "$tag" = llama8b ]; then
    for seed in 0 1 2; do
      run_cell "u1e0_llama8b_alphaHO_delete_refusal_L24_s${seed}" 55 "$PY" "$KG" --model "$model" --editor alpha --alpha_proj_source holdout --holdout_frac 1.0 --edit_mode delete --delete_variant refusal $COMMON --layer 24 --seed "$seed"
    done
  fi
done
{
  echo "DELETION WAVE1 REPORT shard=$SHARD host=$(hostname) failures=$failures completed=$completed expected=$expected"
  grep -E 'RUN |DONE |FAIL |SKIP |BUDGET|ABORT|COMPLETE' "$LOG" | tail -120
} > "engine/run_deletion_wave1_${SHARD}.report"
log "COMPLETE shard=$SHARD failures=$failures completed=$completed/$expected"
[ "$failures" -eq 0 ] && [ "$completed" -eq "$expected" ]
