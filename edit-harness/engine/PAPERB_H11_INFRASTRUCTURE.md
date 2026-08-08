# Paper B H11 Missing Cells Infrastructure

## Overview
This infrastructure implements a remote box batch for the 5 missing Paper B H11 cells:
- `gemma2b_rome_L19_s2`
- `qwen3b_rome_L27_s2`
- `phi35_rome_L24_s0`
- `phi35_rome_L24_s1`
- `phi35_rome_L24_s2`

These cells complete the Paper B curve local readout gate (G-S3) by adding the final seeds needed for the 3-model × 3-seed grid.

## Key Features

### 1. **Independent Wave Name**
- Wave name: `paperb-h11-missing`
- Does not conflict with existing `paperb-curve` wave semantics
- H11 = "missing H11 cells" (Paper B gate hierarchy)

### 2. **Dual-Card Sharding**
The 5 cells are balanced across two GPUs:
- **card0** (3 cells): gemma2b s2, phi35 s0, phi35 s2
- **card1** (2 cells): qwen3b s2, phi35 s1

Both shards can run concurrently on a dual-GPU box (e.g., 2×4090D 24GB).

### 3. **Frozen Parameters**
All parameters match `run_paperb_curve_local.sh`:
- Editor: ROME
- n_edits=200, n_probes=200
- steps=20, lr=0.1
- schemes: nf4dq,int8
- codec: real (bitsandbytes kernels)
- n_perm=1000, n_boot=1000
- fp32 (prereg-bound)
- runner_stamp validation
- skip-if-valid logic

### 4. **No G-S3 Receipt Requirement**
The driver does NOT require `PAPERB_CURVE_GS3_PASS.ok` to run. After all cells complete, `paperb_curve_readout.py` automatically evaluates the aggregate and writes the receipt if G-S3 passes.

### 5. **Safety Gates**
- Prereg ratification check (reuses PREREG-PAPERB-CURVE-2026-07-26.md)
- Tokenizer gate (verifies all 3 models load with expected vocab sizes)
- Model integrity check (parameter counts via integrity_check.py)
- CounterFact SHA256 verification
- CPU selftest before GPU launch
- GPU idle gate (local only)
- Runner stamp validation on every result

## Files Created

### Main Driver
- `edit-harness/run_paperb_h11_missing.sh` - Main execution script with SHARD support

### Box Infrastructure
- `edit-harness/engine/box_paperb_h11_prepare.sh` - Prepare wave (deps/download/check)
- `edit-harness/engine/box_paperb_h11_launch.sh` - Launch dual-card shards on-box
- `edit-harness/engine/box_paperb_h11_pull.sh` - Pull results manifest after completion

### Testing
- `edit-harness/engine/test_paperb_h11_infrastructure.sh` - CPU-only validation suite

## Usage

### On Remote Box

```bash
# 1. Prepare dependencies
bash engine/box_paperb_h11_prepare.sh deps

# 2. Download models (gemma-2-2b, Qwen2.5-3B, Phi-3.5-mini)
bash engine/box_paperb_h11_prepare.sh download

# 3. Verify everything is ready
bash engine/box_paperb_h11_prepare.sh check
# Creates: engine/BOX_READY_paperb_h11_missing.ok

# 4. Launch both shards
bash engine/box_paperb_h11_launch.sh
# Launches:
#   - card0 shard → engine/run_paperb_h11_missing_card0.pid
#   - card1 shard → engine/run_paperb_h11_missing_card1.pid

# Monitor progress
tail -f engine/paperb_h11_missing_card0.nohup.log
tail -f engine/paperb_h11_missing_card1.nohup.log
```

### After Completion

```bash
# Pull results back to local machine. Defaults: port 36039 and remote harness
# /root/edit-harness-deploy-20260727; override with REMOTE_PORT or arg 2.
bash engine/box_paperb_h11_pull.sh root@connect.cqa1.seetacloud.com

# Results pulled:
# - 5 × QS_phase1_table.json
# - 5 × QS_phase1_raw.npz
# - results/quant_survival/aggregate/curve_local_readout.json
# - engine/PAPERB_CURVE_GS3_PASS.ok (if G-S3 passes)
# - All logs
```

## Result Aggregation

The driver calls `experiments/paperb_curve_readout.py` after all cells complete. This script:
1. Checks all 9 required curve cells (Qwen-3B, Gemma-2B and Phi-3.5, each at 3 seeds)
2. Computes aggregate statistics (qwen/llama monotonicity, family separation, NSR)
3. Writes `results/quant_survival/aggregate/curve_local_readout.json`
4. Creates `engine/PAPERB_CURVE_GS3_PASS.ok` if G-S3 passes

Exit codes:
- 0: G-S3 PASS
- 2: G-S3 not passed (cells complete but gate failed)
- 3: INCOMPLETE (some cells still missing)

## Resource Requirements

### Compute
- 2 GPUs with >=23GB VRAM each (e.g., 2×4090D 24GB)
- Dual-card execution parallelizes the 5 cells

### Storage
- ~16GB for models (gemma-2-2b, Qwen2.5-3B, Phi-3.5-mini)
- ~2GB for CounterFact data
- ~500MB for results (5 cells × ~100MB each)
- Total: ~20GB minimum

### Time Estimate
- ~60-90 minutes per cell (200 edits, 200 probes, 1000 permutations)
- card0: 3 cells → ~180-270 minutes
- card1: 2 cells → ~120-180 minutes
- Total wall time: ~180-270 minutes (shards run in parallel)

## Testing

Run the test suite before deployment:

```bash
cd edit-harness
bash engine/test_paperb_h11_infrastructure.sh
```

Tests verify:
- All files exist
- Prereg is ratified
- Shell script syntax
- Shard distribution (card0=3, card1=2)
- Frozen parameters match reference
- Python selftest passes
- Validation logic

## Integration with Existing Infrastructure

### Does NOT Modify
- `run_paperb_curve_local.sh` - unchanged
- `run_paperb_curve_cloud.sh` - unchanged
- `box_launch_wave.sh` - not modified (uses independent launcher)
- `box_prepare_wave.sh` - not modified (uses independent prepare script)

### Reuses
- `experiments/quant_survival_phase1.py` - same experiment code
- `experiments/paperb_curve_readout.py` - same readout logic
- `docs/plans/PREREG-PAPERB-CURVE-2026-07-26.md` - same prereg
- `experiments/tools/integrity_check.py` - same integrity checks

### New Wave Name
The `paperb-h11-missing` wave name is completely independent and does not interfere with the existing `paperb-curve` wave semantics (H12 in the gate hierarchy).

## Commit Summary

**New files (4 scripts + 1 test + 1 doc):**
```
edit-harness/run_paperb_h11_missing.sh
edit-harness/engine/box_paperb_h11_prepare.sh
edit-harness/engine/box_paperb_h11_launch.sh
edit-harness/engine/box_paperb_h11_pull.sh
edit-harness/engine/test_paperb_h11_infrastructure.sh
edit-harness/engine/PAPERB_H11_INFRASTRUCTURE.md
```

**All scripts are:**
- Executable
- Syntax-checked
- Tested with CPU-only validation suite
- PID-contract compliant
- setsid-isolated for clean backgrounding

**No modifications to:**
- Existing drivers
- Existing box infrastructure
- User dirty files in main worktree
