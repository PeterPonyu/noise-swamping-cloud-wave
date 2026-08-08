# Frame-A 恢复状态报告 (2026-07-29)

> **历史状态提示（2026-08-08）**：本文件记录 2026-07-29 的恢复现场，不能作为当前 deletion、D2 或 Frame-A 门控依据。当前权威状态见 [`docs/reports/CURRENT-STATE-RECONCILIATION-2026-08-08.md`](../docs/reports/CURRENT-STATE-RECONCILIATION-2026-08-08.md) 及其中链接的 JSON receipts。H8 现为 `PREREG_MIXED_RESULT`；H11 已以 G-S3 PASS 完成；Frame-A provenance 为 99/99 PASS 但 substantive router verdict 仍为 KILL；H4/H17 measurement 完成但 `TEXT_PASS=false`，Wave 1 继续取消。历史正文保留仅用于故障恢复审计。

## 执行摘要

**状态**: 🟢 **恢复流程已启动并自动化**

07-26 晚上的 Frame-A 实验波在完成 31/33 MIX_B 细胞后卡住，wrapper 进程死亡，后续链被手动终止。现已启动完整的自动化恢复流程。

---

## 发现的问题

### 1. Frame-A MIX_B/C 波未完成
- **MIX_B**: 31/33 ❌ 缺失 `ft_merge_s2`, `random_s2`
- **MIX_C**: 0/33 ❌ 完全未开始
- **wrapper 进程** (pid 758651): 死亡于 2026-07-26 23:26
- **根本原因**: 进程在 22:36 完成 `always_reject_s2` 后卡住，最后两个细胞未运行

### 2. 后续链（chain_after_bc_drain）未执行
4 个阶段全部未完成：
- ❌ **S1**: runner_stamp 补丁未应用
- ❌ **S2**: 3 个 MIX_A 污染细胞未重跑（`cost_only_s2`, `ft_merge_s2`, `random_s2`）
- ❌ **S3**: Gate v2 未运行
- ❌ **S4**: B6 保险队列未运行

### 3. 历史失败原因
- 07-21 20:05: MIX_B failed rc=143 (SIGTERM - 被用户手动终止)
- 07-22 08:31/08:38: 相同问题重现

---

## 执行的恢复方案

### 自动化恢复流程（已启动）

**Master 监控进程**: `monitor_and_chain.sh` (pid 73627)

#### Stage 1: MIX_B 恢复 ✅ 进行中
- **脚本**: `resume_mixb_missing.sh` (pid 69300)
- **任务**: 重跑 `ft_merge_s2` 和 `random_s2`
- **状态**: 运行中，已加载模型
- **预计时间**: ~30-60分钟（每个细胞 15-30分钟）

#### Stage 2: GPU 空闲等待
- 等待 GPU 利用率 < 25% 且内存 < 1500 MiB（连续 3 次检查）

#### Stage 3: MIX_C 运行 ⏳ 待启动
- **脚本**: `run_mixc.sh`
- **任务**: 运行完整的 MIX_C（33 细胞 + p2 结构文件）
- **预计时间**: ~2-3 GPU小时

#### Stage 4: 等待 MIX_C 完成
- 每 5 分钟检查一次进度

#### Stage 5: 再次 GPU 空闲等待

#### Stage 6: 后续链 ⏳ 待启动
- **脚本**: `chain_after_bc_drain_20260726.sh`
- **任务**:
  - S1: 应用 runner_stamp 补丁 + 重新 smoke 测试
  - S2: 重跑 3 个 MIX_A 污染细胞
  - S3: 运行 provenance gate v2（强制 stamp 验证）
  - S4: B6 保险队列（alphaHO L10/L14 × 3 seeds）
- **预计时间**: ~3-5 GPU小时

---

## 监控与控制

### 快速检查进度
```bash
cd /home/zeyufu/Desktop/idea-feasibility-analysis/edit-harness
./engine/check_progress.sh
```

### 关键日志文件
- **总监控**: `engine/monitor_and_chain.log`
- **MIX_B 恢复**: `engine/resume_mixb_missing.log`
- **MIX_C**: `engine/run_mixc.log`
- **后续链**: `engine/chain_after_bc_drain.log`

### 停止任务（如需要）
```bash
# 停止整个流程
kill $(cat engine/monitor_and_chain.pid)

# 停止单个阶段（按 PID）
kill $(cat engine/resume_mixb_missing.pid)
kill $(cat engine/run_mixc.pid)
kill $(cat engine/chain_after_bc_drain_20260726.pid)
```

### 验证点
```bash
# MIX_B 完整性
ls results/frame_a/cells/cell_*_MIX_B_*.json | wc -l  # 应为 33

# MIX_C 完整性
ls results/frame_a/cells/cell_*_MIX_C_*.json | wc -l  # 应为 33

# Gate v2 通过
cat engine/FRAME_A_GATE_V2_PASS.ok  # 应显示 "PASS ..."
```

---

## 预计完成时间线

| 阶段 | 预计耗时 | 累计时间 |
|-----|---------|---------|
| MIX_B 恢复（2 cells） | 30-60 min | 0.5-1 h |
| MIX_C（33 cells） | 2-3 h | 2.5-4 h |
| 后续链（patch + 3 cells + gate + B6） | 3-5 h | 5.5-9 h |
| **总计** | **~5.5-9 GPU小时** | |

**保守估计完成时间**: 2026-07-29 12:00-15:00（假设 04:00 启动）

---

## 其他发现

### D2 Prospective
- **状态**: 多次启动失败
- **原因**: prereg 未 RATIFIED
- **文件**: `docs/plans/PREREG-D2-PROSPECTIVE-2026-07-26.md` **不存在**
- **行动**: 需要用户确认是否需要此任务

### Deletion Phase L
- ✅ **完成**: GD1/GD2 gates PASS (2026-07-28)
- 本地前置条件已满足，可以启动云端 deletion wave 1

---

## 下一步建议

### 立即（自动化中）
1. ✅ 等待恢复流程自动完成（已启动）
2. 监控日志确保无错误

### 恢复完成后
1. **运行 Frame-A 分析**
   ```bash
   cd edit-harness
   python experiments/frame_a/scorer/analyze_frame_a.py --verify_gate
   ```

2. **验证 Gate v2 通过**
   - 检查 `engine/FRAME_A_GATE_V2_PASS.ok`
   - 检查 `engine/gate_v2_report_20260726.json`

3. **Paper B / Deletion waves** (根据用户优先级)
   - Paper B curve: 需要 ratify `PREREG-PAPERB-CURVE-2026-07-26.md`
   - Deletion wave 1: 本地前置条件已满足

---

## 风险与缓解

### 已知风险
1. **nvidia_uvm wedge**: 需要保持笔记本盖子打开
2. **进程可能再次卡住**: 监控脚本每 5-60 分钟检查一次
3. **磁盘空间**: 当前未检查

### 缓解措施
- ✅ 自动化监控链已部署
- ✅ 所有进程使用 PID 文件管理
- ✅ 详细日志记录
- ⚠️ **需要手动**: 保持笔记本盖子打开

---

## 联系 & 支持

如果遇到问题：
1. 运行 `./engine/check_progress.sh` 获取当前状态
2. 检查相关日志文件（见上方"关键日志文件"）
3. 如需终止：使用 PID 文件中的进程号（never pgrep/pkill）

---

**生成时间**: 2026-07-29 03:53 EDT
**执行者**: Claude (Opus)
**会话 ID**: 当前会话
