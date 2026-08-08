#!/usr/bin/env bash
# Launch a prepared wave on-box after box_prepare_wave.sh check writes BOX_READY.
set -u
WAVE="${1:-}"; DRYRUN="${DRYRUN:-0}"; H="${HARNESS:-/root/edit-harness}"
cd "$H" || exit 1
[ -f engine/box_env.sh ] && source engine/box_env.sh
host=$(hostname)
require_current_ready(){
  wave="$1"; driver="$2"; ready="engine/BOX_READY_${wave}.ok"
  [ -f "$ready" ] || { echo "ABORT: wave not READY" >&2; exit 8; }
  recorded=$(sed -n 's/^driver_sha256=//p' "$ready" | tail -1)
  current=$(sha256sum "$driver" | cut -d' ' -f1)
  [ -n "$recorded" ] && [ "$recorded" = "$current" ] || {
    echo "ABORT: READY receipt is stale for $driver; rerun box_prepare_wave.sh $wave check" >&2
    exit 9
  }
  recorded_host=$(sed -n 's/^host=//p' "$ready" | tail -1)
  [ "$recorded_host" = "$host" ] || {
    echo "ABORT: READY receipt belongs to host ${recorded_host:-unknown}, not $host" >&2
    exit 10
  }
  "$H/engine/box_preflight.sh" "$wave" || {
    echo "ABORT: fresh-box preflight failed; do not spend" >&2
    exit 11
  }
}
launch(){
  name="$1"; pidfile="$2"; shift 2
  monitor_pidfile="${pidfile}.monitor"
  checkpoint="${pidfile}.checkpoint"
  if [ -f "$pidfile" ]; then
    old=$(tr -dc 0-9 < "$pidfile")
    if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
      echo "ABORT: $name already running as PID $old" >&2; return 3
    fi
  fi
  if [ -f "$monitor_pidfile" ]; then
    old_monitor=$(tr -dc 0-9 < "$monitor_pidfile")
    if [ -n "$old_monitor" ] && kill -0 "$old_monitor" 2>/dev/null; then
      echo "ABORT: $name monitor already running as PID $old_monitor" >&2; return 3
    fi
    rm -f "$monitor_pidfile"
  fi
  echo "LAUNCH $name: $*"
  [ "$DRYRUN" = 1 ] && return 0

  # H18: keep the launcher monitor and the driver in separate sessions. A TERM
  # sent to the monitor records a checkpoint and exits, while the driver keeps
  # running under its canonical .pid contract and remains resumable. The inner
  # setsid --wait also preserves the driver's real exit status for normal drains.
  setsid -f bash -c '
    set -u
    pidfile=$1
    monitor_pidfile=$2
    checkpoint=$3
    shift 3
    printf "%s\n" "$$" > "$monitor_pidfile"
    cleanup_monitor_pidfile(){
      recorded=""
      [ -f "$monitor_pidfile" ] && recorded=$(tr -dc 0-9 < "$monitor_pidfile")
      [ "$recorded" = "$$" ] && rm -f "$monitor_pidfile"
    }
    checkpoint_signal(){
      signal=$1
      driver_pid=""
      driver_alive=no
      if [ -f "$pidfile" ]; then
        driver_pid=$(tr -dc 0-9 < "$pidfile")
        if [ -n "$driver_pid" ] && kill -0 "$driver_pid" 2>/dev/null; then
          driver_alive=yes
        fi
      fi
      printf "event=signal signal=%s time=%s monitor_pid=%s driver_pid=%s driver_alive=%s pidfile=%s\n" "$signal" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" "${driver_pid:-unknown}" "$driver_alive" "$pidfile" >> "$checkpoint"
    }
    on_signal(){
      signal=$1
      trap - TERM INT HUP
      checkpoint_signal "$signal"
      exit 143
    }
    trap cleanup_monitor_pidfile EXIT
    trap "on_signal TERM" TERM
    trap "on_signal INT" INT
    trap "on_signal HUP" HUP
    setsid --wait env "$@" &
    driver_waiter=$!
    wait "$driver_waiter"
    rc=$?
    trap - TERM INT HUP
    exit "$rc"
  ' h18-wave-monitor "$pidfile" "$monitor_pidfile" "$checkpoint" "$@" </dev/null

  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if [ -f "$pidfile" ]; then
      p=$(tr -dc 0-9 < "$pidfile")
      if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
        echo "STARTED $name PID=$p monitor=$(tr -dc 0-9 < "$monitor_pidfile" 2>/dev/null)"; return 0
      fi
    fi
    sleep 2
  done
  echo "ABORT: $name did not create a live pidfile: $pidfile" >&2
  return 4
}
case "$WAVE" in
  deletion-wave1)
    require_current_ready deletion-wave1 "$H/run_deletion_wave1.sh"
    launch_fail=0
    launch deletion-card0 engine/run_deletion_wave1_card0.pid \
      H="$H" WAVE_BOX="$host" SHARD=card0 GPU_ID=0 BUDGET_MIN="${BUDGET_MIN:-540}" JOB_CAP_MIN="${JOB_CAP_MIN:-100}" \
      bash -c './run_deletion_wave1.sh >engine/deletion_wave1_card0.nohup.log 2>&1' || launch_fail=1
    launch deletion-card1 engine/run_deletion_wave1_card1.pid \
      H="$H" WAVE_BOX="$host" SHARD=card1 GPU_ID=1 BUDGET_MIN="${BUDGET_MIN:-540}" JOB_CAP_MIN="${JOB_CAP_MIN:-100}" \
      bash -c './run_deletion_wave1.sh >engine/deletion_wave1_card1.nohup.log 2>&1' || launch_fail=1
    [ "$launch_fail" -eq 0 ] || exit 4
    ;;
  deletion-wave2)
    require_current_ready deletion-wave2 "$H/run_deletion_wave2.sh"
    launch deletion-wave2 engine/run_deletion_wave2.pid \
      H="$H" WAVE_BOX="$host" GPU_ID=0 BUDGET_MIN="${BUDGET_MIN:-1260}" JOB_CAP_MIN="${JOB_CAP_MIN:-150}" \
      bash -c './run_deletion_wave2.sh >engine/deletion_wave2.nohup.log 2>&1'
    ;;
  paperb-curve)
    require_current_ready paperb-curve "$H/run_paperb_curve_cloud.sh"
    launch paperb-curve engine/run_paperb_curve_cloud.pid \
      H="$H" WAVE_BOX="$host" GPU_ID=0 BUDGET_MIN="${BUDGET_MIN:-300}" JOB_CAP_MIN="${JOB_CAP_MIN:-150}" \
      bash -c './run_paperb_curve_cloud.sh >engine/paperb_curve_cloud.nohup.log 2>&1'
    ;;
  d2-prospective)
    require_current_ready d2-prospective "$H/run_d2_prospective_cloud.sh"
    launch d2-prospective engine/run_d2_prospective_cloud.pid \
      H="$H" WAVE_BOX="$host" BUDGET_MIN="${BUDGET_MIN:-240}" \
      bash -c './run_d2_prospective_cloud.sh >engine/d2_prospective_cloud.nohup.log 2>&1'
    ;;
  *) echo "usage: $0 {deletion-wave1|deletion-wave2|paperb-curve|d2-prospective}" >&2; exit 2 ;;
esac
