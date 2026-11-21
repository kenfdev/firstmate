#!/usr/bin/env bash
# tests/fm-backend-hc-smoke.test.sh - real herdr-core smoke test for the hc
# session-provider adapter (bin/backends/hc.sh, docs/hc-backend.md).
# Every other hc suite fakes the CLI; this one drives the REAL hc binary, but
# only inside a lab session provisioned by bin/fm-hc-lab.sh: a unique
# fm-hclab-* HC_SESSION, scratch XDG roots, a pinned FM_HC_SOCKET, a
# real-fleet tripwire, and a teardown that sweeps the session's serve/hold
# daemons by their HC_SESSION env marker. tests/hc-test-safety.sh owns the
# only sanctioned teardown path and teardown failures propagate through the
# EXIT trap.
#
# Covers one task lifecycle through the bin/fm-backend.sh dispatcher: binary
# and generation gates, container ensure, create, submitted input, cwd
# tracking, capture, agent state for a shell and for an agent-named process,
# and a proven close.
#
# Skips cleanly (exit 0, "skip: hc not found ...") when no herdr-core binary
# is installed (optional-binary gate); to pin a specific binary run
# `FM_HC_BIN=/path/to/hc bash tests/fm-backend-hc-smoke.test.sh`. Once the
# binary is present, a provisioning or teardown failure is a FAIL, not a
# skip.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

# Binary resolution identical to the adapter, installer, and lab: FM_HC_BIN
# wins, then herdr-core, then the hc alias.
HC_BIN=${FM_HC_BIN:-}
[ -n "$HC_BIN" ] || HC_BIN=$(command -v herdr-core 2>/dev/null || true)
[ -n "$HC_BIN" ] || HC_BIN=$(command -v hc 2>/dev/null || true)
if [ -z "$HC_BIN" ] || [ ! -x "$HC_BIN" ]; then
  echo "skip: hc not found (install via bin/fm-install-hc.sh or set FM_HC_BIN)"
  exit 0
fi
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the hc adapter)"; exit 0; }
export FM_HC_BIN=$HC_BIN

# shellcheck source=tests/hc-test-safety.sh
. "$ROOT/tests/hc-test-safety.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-hc-smoke)

# Keep the core's login shells independent of the operator's shell startup.
mkdir -p "$TMP_ROOT/bin"
cat > "$TMP_ROOT/bin/lab-shell" <<'SH'
#!/bin/sh
exec /bin/bash --noprofile --norc -i
SH
chmod +x "$TMP_ROOT/bin/lab-shell"
export SHELL="$TMP_ROOT/bin/lab-shell"
export PATH="$TMP_ROOT/bin:/usr/bin:/bin:$PATH"
export FM_HC_MATE_TEST_LOG="$TMP_ROOT/mate-launch.log"

HC_TEST_SES=$("$ROOT/bin/fm-hc-lab.sh" name smoke)

# The teardown's own result propagates: a fleet-tripwire failure or surviving
# session processes keep this run nonzero even on an otherwise-clean pass.
# Armed before provision so a half-provisioned session is still swept when
# the lab helper left a tripwire behind.
cleanup_lab() {
  local rc=$?
  trap - EXIT
  hc_test_safe_teardown "$ROOT" "$HC_TEST_SES" || rc=1
  fm_test_cleanup
  exit "$rc"
}
trap cleanup_lab EXIT

"$ROOT/bin/fm-hc-lab.sh" provision "$HC_TEST_SES" \
  || fail "hc lab could not provision with $HC_BIN"
HC_TEST_SOCK=$("$ROOT/bin/fm-hc-lab.sh" socket "$HC_TEST_SES")
[ -n "$HC_TEST_SOCK" ] || fail "hc lab provisioned without a socket"

hc_test_refuse_if_unsafe "$HC_TEST_SES" \
  || fail "provisioned session '$HC_TEST_SES' does not satisfy the lab safety contract"

HC_LAB_DIR=$(hc_test_lab_dir)/$HC_TEST_SES
export HC_SESSION=$HC_TEST_SES FM_HC_SOCKET=$HC_TEST_SOCK
export XDG_STATE_HOME="$HC_LAB_DIR/env/xdg-state" \
  XDG_CONFIG_HOME="$HC_LAB_DIR/env/xdg-config" \
  XDG_DATA_HOME="$HC_LAB_DIR/env/xdg-data"
unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE HC_SOCKET

FM_HOME_DIR=$TMP_ROOT/home
WORK_DIR=$TMP_ROOT/work
mkdir -p "$FM_HOME_DIR" "$WORK_DIR"
WORK_DIR=$(cd "$WORK_DIR" && pwd -P)
export FM_HOME=$FM_HOME_DIR FM_ROOT_OVERRIDE=$FM_HOME_DIR

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source hc || fail "could not source the hc adapter"

# wait_for <seconds> <cmd...>: poll a condition without a fixed sleep budget.
wait_for() {
  local tries=$(( $1 * 10 ))
  shift
  while [ "$tries" -gt 0 ]; do
    "$@" && return 0
    tries=$((tries - 1))
    sleep 0.1
  done
  return 1
}

LABEL=fm-smoke1
SES=$(fm_backend_hc_container_ensure) || fail "container_ensure failed"
assert_equals "$SES" "$HC_TEST_SES" "container_ensure names the lab session"
ADDR=$(fm_backend_hc_create_task "$SES" "$LABEL" "$WORK_DIR") || fail "create_task failed"
T="$SES:$ADDR"
fm_backend_target_exists hc "$T" "$LABEL" || fail "the new terminal must exist under its label"
pass "hc smoke: create_task started $T"

TAG=$(fm_backend_hometag)
labels=$("$ROOT/bin/fm-hc-lab.sh" run "$HC_TEST_SES" get "$ADDR" --json) || fail "get task labels"
assert_equals "$(printf '%s' "$labels" | jq -r '.labels["herdr.space"]')" "fm-$TAG-$LABEL" "default task space"
assert_equals "$(printf '%s' "$labels" | jq -r '.labels["herdr.tab"]')" "$TAG-$LABEL" "task tab"
mkdir -p "$FM_HOME_DIR/config"
printf 'off\n' > "$FM_HOME_DIR/config/herdr-presentation-spaces"
printf 'Project task:group\nOther *\n' > "$FM_HOME_DIR/config/herdr-project-groups"
GROUP_ADDR=$(fm_backend_hc_create_task "$SES" fm-group-one "$WORK_DIR") || fail "create grouped task"
labels=$("$ROOT/bin/fm-hc-lab.sh" run "$HC_TEST_SES" get "$GROUP_ADDR" --json) || fail "get grouped task labels"
assert_equals "$(printf '%s' "$labels" | jq -r '.labels["herdr.space"]')" "fm-$TAG" "off selects home space"
assert_equals "$(printf '%s' "$labels" | jq -r '.labels["herdr.tab"]')" "$TAG-fm-group-one" "grouped task tab"
assert_equals "$(printf '%s' "$labels" | jq -r '.labels["firstmate.group"]')" Project "group rule"
assert_equals "$(printf '%s' "$labels" | jq -r '.labels["firstmate.group-order"]')" 001.Project "group order"
fm_backend_kill hc "$SES:$GROUP_ADDR" fm-group-one || fail "close grouped task"
printf 'on\n' > "$FM_HOME_DIR/config/herdr-presentation-spaces"
PROJECTED_ADDR=$(fm_backend_hc_create_task "$SES" fm-group-two "$WORK_DIR") || fail "create projected grouped task"
labels=$("$ROOT/bin/fm-hc-lab.sh" run "$HC_TEST_SES" get "$PROJECTED_ADDR" --json) || fail "get projected group labels"
assert_equals "$(printf '%s' "$labels" | jq -r '.labels["herdr.space"]')" "fm-$TAG-fm-group-two" "projected group has its own space"
assert_equals "$(printf '%s' "$labels" | jq -r '.labels["firstmate.group"]')" Project "projected group rule"
fm_backend_kill hc "$SES:$PROJECTED_ADDR" fm-group-two || fail "close projected grouped task"
printf 'off\n' > "$FM_HOME_DIR/config/herdr-presentation-spaces"
pass "hc smoke: task spaces, tabs, flat opt-out and group labels read back"

ADDR2=$(fm_backend_hc_create_task "$SES" fm-smoke2 "$WORK_DIR") || fail "second create_task failed"
ADDR3=$(FM_HC_SPACE=custom-space fm_backend_hc_create_task "$SES" fm-smoke3 "$WORK_DIR") || fail "custom-space create_task failed"
HOMETAG=$(fm_backend_hometag)
labels1=$("$ROOT/bin/fm-hc-lab.sh" run "$SES" get --json "$ADDR") || fail "first task labels unavailable"
labels2=$("$ROOT/bin/fm-hc-lab.sh" run "$SES" get --json "$ADDR2") || fail "second task labels unavailable"
labels3=$("$ROOT/bin/fm-hc-lab.sh" run "$SES" get --json "$ADDR3") || fail "custom-space task labels unavailable"
printf '%s\n%s\n' "$labels1" "$labels2" | jq -se --arg space "fm-$HOMETAG" --arg tag "$HOMETAG" '
  length == 2 and all(.[]; .labels["herdr.seen"] == "0")
  and .[0].labels["herdr.space"] == ($space + "-fm-smoke1")
  and .[1].labels["herdr.space"] == $space
  and .[0].labels["herdr.tab"] == ($tag + "-fm-smoke1")
  and .[1].labels["herdr.tab"] == ($tag + "-fm-smoke2")' >/dev/null \
  || fail "tasks must use their selected spaces, have distinct tabs, and start seen at turn zero"
printf '%s' "$labels3" | jq -e '.labels["herdr.space"] == "custom-space" and .labels["herdr.seen"] == "0"' >/dev/null \
  || fail "the space override must place the task in its selected space"
"$ROOT/bin/fm-hc-lab.sh" run "$SES" label "$ADDR" herdr.pinned=1 herdr.seen=3 >/dev/null \
  || fail "could not set shared client labels"
fm_backend_capture hc "$T" 10 "$LABEL" >/dev/null || fail "capture failed after shared label change"
labels1=$("$ROOT/bin/fm-hc-lab.sh" run "$SES" get --json "$ADDR") || fail "updated labels unavailable"
printf '%s' "$labels1" | jq -e '.labels["herdr.pinned"] == "1" and .labels["herdr.seen"] == "3"' >/dev/null \
  || fail "capture must preserve shared pinned and seen labels"
pass "hc smoke: task spaces and tabs preserve shared client labels"

mkdir -p "$WORK_DIR/sub"
fm_backend_hc_send_text_line "$T" "cd sub" "$LABEL" || fail "send_text_line failed"
path_is_sub() { [ "$(fm_backend_hc_current_path "$T" "$LABEL")" = "$WORK_DIR/sub" ]; }
wait_for 10 path_is_sub || fail "current_path did not follow cd (got $(fm_backend_hc_current_path "$T" "$LABEL"))"
pass "hc smoke: current_path follows the shell's cwd"

fm_backend_hc_send_text_line "$T" "echo Smoke-Line-42" "$LABEL" || fail "send_text_line failed"
captured() { fm_backend_capture hc "$T" 50 "$LABEL" | grep -qx 'Smoke-Line-42'; }
wait_for 10 captured || fail "capture did not show the submitted command's output"
pass "hc smoke: send_text_line ran the command and capture shows its output"

verdict=$(fm_backend_hc_send_text_submit "$T" "echo Sub-Line-7" 1 0.4 0 "$LABEL" 2>/dev/null)
[ "$verdict" != send-failed ] || fail "a terminal without native status must accept text"
sub_captured() { fm_backend_capture hc "$T" 50 "$LABEL" | grep -qx 'Sub-Line-7'; }
wait_for 10 sub_captured || fail "text was not delivered to the terminal without native status"
pass "hc smoke: a terminal without native status receives text"

fixture_out="$TMP_ROOT/supervisor-received"
# shellcheck disable=SC2016 # The fixture shell expands its own positional arguments.
fixture_json=$("$ROOT/bin/fm-hc-lab.sh" run "$SES" run --json --bg --no-parent --no-notify \
  /bin/bash -c 'printf "\033]7501;state=idle:app=fixture\033\\❯ "; IFS= read -r line; printf "%s" "$line" > "$1"; printf "\033]7501;state=working:app=fixture\033\\"; sleep 1; printf "\033]7501;state=idle:app=fixture\033\\\n❯ "; sleep 30' _ "$fixture_out") \
  || fail "could not start the supervisor fixture"
fixture_addr=$(printf '%s' "$fixture_json" | jq -r '.address // empty')
[ -n "$fixture_addr" ] || fail "supervisor fixture has no address"
fixture_idle() {
  [ "$("$ROOT/bin/fm-hc-lab.sh" run "$SES" get --json "$fixture_addr" | jq -r '.status.state // empty')" = idle ]
}
wait_for 10 fixture_idle || fail "supervisor fixture did not report idle"
fixture_inject() (
  export FM_SUPERVISOR_BACKEND=hc FM_SUPERVISOR_TARGET="$SES:$fixture_addr" FM_DAEMON_PRIMARY_HARNESS=codex
  . "$ROOT/bin/fm-supervise-daemon.sh"
  inject_msg 'hc smoke escalation' "$FM_HOME/state"
)
mkdir -p "$FM_HOME/state"
printf 'away\n' > "$FM_HOME/state/.afk"
"$ROOT/bin/fm-hc-lab.sh" run "$SES" keys --json "$fixture_addr" -- d r a f t >/dev/null \
  || fail "could not type the fixture draft"
before=$("$ROOT/bin/fm-hc-lab.sh" run "$SES" read --lines 0 "$fixture_addr")
assert_contains "$before" draft "the fixture draft must be visible"
if fixture_inject; then fail "drafted supervisor must defer injection"; fi
after=$("$ROOT/bin/fm-hc-lab.sh" run "$SES" read --lines 0 "$fixture_addr")
assert_equals "$after" "$before" "deferred injection must leave the draft unchanged"
[ ! -e "$fixture_out" ] || fail "deferred injection must not submit the draft"
"$ROOT/bin/fm-hc-lab.sh" run "$SES" keys --json "$fixture_addr" -- ctrl+u >/dev/null \
  || fail "could not clear the fixture draft"
fixture_inject || fail "marked supervisor injection failed"
expected=$(printf '\342\201\243FIRSTMATE_OP: v1 away-supervisor: hc smoke escalation')
assert_equals "$(cat "$fixture_out")" "$expected" "the supervisor must receive the complete marked escalation"
rm -f "$FM_HOME/state/.afk"
pass "hc smoke: idle supervisor receives a marked escalation"

assert_equals "$(fm_backend_agent_state hc "$T")" dead "an idle shell is dead"
STANDIN=$(fm_agent_standin "$TMP_ROOT/standin") || fail "no agent stand-in survives a foreign name here"
mkdir -p "$TMP_ROOT/bin/claude"
cp "$STANDIN" "$TMP_ROOT/bin/claude/claude"
fm_backend_hc_send_text_line "$T" "exec $TMP_ROOT/bin/claude/claude 600" "$LABEL" || fail "agent launch send failed"
is_alive() { [ "$(fm_backend_agent_state hc "$T")" = alive ]; }
wait_for 10 is_alive || fail "agent_state did not report the agent-named foreground (got $(fm_backend_agent_state hc "$T"))"
pass "hc smoke: agent_state reads dead for a shell and alive for an agent-named foreground"

fm_backend_kill hc "$T" || fail "kill failed"
assert_equals "$(fm_backend_agent_state hc "$T")" missing "a closed terminal is missing"
fm_backend_kill hc "$T" || fail "closing an already-closed terminal must be a silent success"
pass "hc smoke: kill closes and removes the terminal"

# Drive native status changes in the private core without a user shell startup.
STATE=$TMP_ROOT/event-state
mkdir -p "$STATE" "$TMP_ROOT/event-work"
TAG=$(fm_backend_hometag)
fm_backend_events_capable hc "$SES" || fail "real hc must support the events capability"
LAB="$ROOT/bin/fm-hc-lab.sh"
event_shell() {  # <home-label> <task-label>
  bash "$LAB" run "$SES" run --bg --json --no-parent --no-notify \
    --cwd "$TMP_ROOT/event-work" --label "firstmate.home=$1" --label "firstmate.task=$2" \
    /bin/bash --noprofile --norc -i | jq -r .address
}
event_status() {  # <address> <status>
  bash "$LAB" run "$SES" send --json "$1" -- "printf '\\033]7501;state=$2:app=fm-test\\033\\\\'" >/dev/null
}
PANE=$(event_shell "$TAG" fm-events) || fail "could not create event shell"
FOREIGN=$(event_shell other fm-foreign) || fail "could not create foreign shell"
EVENT_TARGET="$SES:$PANE"
( fm_backend_wait_transition hc "$SES" 10 "$STATE" "$EVENT_TARGET" > "$TMP_ROOT/event-record"; echo $? > "$TMP_ROOT/event-rc" ) &
EVENT_PID=$!
sleep 1
event_status "$FOREIGN" blocked || fail "could not report foreign blocked status"
sleep 1
kill -0 "$EVENT_PID" 2>/dev/null || fail "foreign status ended the event wait"
event_status "$PANE" blocked || fail "could not report blocked status"
wait "$EVENT_PID"
[ "$(cat "$TMP_ROOT/event-rc")" = 0 ] || fail "blocked event did not wake the adapter"
REC=$(cat "$TMP_ROOT/event-record")
[ "$(fm_transition_pane_id "$REC")" = "$PANE" ] || fail "event names the wrong terminal"
[ "$(fm_transition_to_status "$REC")" = blocked ] || fail "event is not blocked"
fm_backend_commit_transition hc "$STATE" "$SES" "$REC" || fail "could not commit event"
RC=0
fm_backend_wait_transition hc "$SES" 1 "$STATE" "$EVENT_TARGET" >/dev/null || RC=$?
[ "$RC" = 1 ] || fail "a committed blocked event must not repeat"
( fm_backend_wait_transition hc "$SES" 10 "$STATE" "$EVENT_TARGET" > "$TMP_ROOT/event-record-2"; echo $? > "$TMP_ROOT/event-rc-2" ) &
EVENT_PID=$!
sleep 1
event_status "$PANE" working || fail "could not report working status"
sleep 1
event_status "$PANE" blocked || fail "could not report a second blocked status"
wait "$EVENT_PID"
[ "$(cat "$TMP_ROOT/event-rc-2")" = 0 ] || fail "working then blocked did not wake again"
fm_backend_commit_transition hc "$STATE" "$SES" "$(cat "$TMP_ROOT/event-record-2")" || fail "could not commit second event"
pass "hc smoke: scoped blocked events wake, deduplicate, and wake again after working"

( fm_backend_wait_transition hc "$SES" 10 "$STATE" "$EVENT_TARGET" > /dev/null; echo $? > "$TMP_ROOT/drop-rc" ) &
EVENT_PID=$!
sleep 1
bash "$LAB" stop "$SES" >/dev/null || fail "could not stop the isolated lab core"
wait "$EVENT_PID"
[ "$(cat "$TMP_ROOT/drop-rc")" = 2 ] || fail "a dropped stream must fall back to polling"
bash "$LAB" run "$SES" ls --json >/dev/null || fail "could not reconnect the lab core"
cat > "$TMP_ROOT/event-work/blocked.sh" <<'SH'
printf '\033]7501;state=blocked:app=fm-test\033\\'
read -r -t 30 answer
SH
PANE=$(bash "$LAB" run "$SES" run --bg --json --no-parent --no-notify \
  --cwd "$TMP_ROOT/event-work" --label "firstmate.home=$TAG" --label firstmate.task=fm-snapshot \
  /bin/bash --noprofile --norc "$TMP_ROOT/event-work/blocked.sh" | jq -r .address) || fail "could not create reconnect fixture"
snapshot_blocked() { [ "$(bash "$LAB" run "$SES" get --json "$PANE" | jq -r '.status.state // empty')" = blocked ]; }
wait_for 10 snapshot_blocked || fail "fixture never reported blocked"
REC=$(fm_backend_wait_transition hc "$SES" 5 "$STATE" "$SES:$PANE") || fail "reconnected snapshot missed blocked state"
[ "$(fm_transition_pane_id "$REC")" = "$PANE" ] || fail "reconnected snapshot names the wrong terminal"
[ "$(fm_transition_to_status "$REC")" = blocked ] || fail "reconnected snapshot is not blocked"
pass "hc smoke: dropped stream falls back and reconnect snapshot finds blocked state"

# A real core plus a token-free stand-in exercises the secondmate path, its
# control plane, and the same liveness recovery used by the supervisor.
if command -v cc >/dev/null 2>&1; then
  cat > "$TMP_ROOT/stub.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>
int main(void) {
  struct termios old, raw;
  char c, line[1024], cwd[4096];
  size_t n = 0;
  FILE *log;
  if (!isatty(0)) return 0;
  if (!getcwd(cwd, sizeof cwd)) return 1;
  log = fopen(getenv("FM_HC_MATE_TEST_LOG"), "a");
  if (!log) return 1;
  fprintf(log, "%s\t%s\n", getenv("FM_HOME"), cwd);
  fclose(log);
  if (tcgetattr(0, &old)) return 1;
  raw = old;
  raw.c_lflag &= ~(ICANON | ECHO);
  tcsetattr(0, TCSANOW, &raw);
  puts("›");
  fflush(stdout);
  while (read(0, &c, 1) == 1) {
    if (c == 27) continue;
    if (c == 13 || c == 10) {
      line[n] = 0;
      if (!strcmp(line, "/quit")) break;
      n = 0;
      puts("›");
      fflush(stdout);
    } else if (n < sizeof(line) - 1) line[n++] = c;
  }
  tcsetattr(0, TCSANOW, &old);
  return 0;
}
C
  cc -o "$TMP_ROOT/bin/codex" "$TMP_ROOT/stub.c" || fail "could not build the token-free harness stand-in"
  cp "$TMP_ROOT/bin/codex" "$TMP_ROOT/bin/claude"
  MATE_PARENT="$TMP_ROOT/mate-parent"
  MATE_HOME="$TMP_ROOT/mate-home"
  mkdir -p "$MATE_PARENT/state" "$MATE_PARENT/data" "$MATE_PARENT/config" "$MATE_HOME/bin" "$MATE_HOME/data" "$MATE_HOME/state"
  printf 'mate\n' > "$MATE_HOME/.fm-secondmate-home"
  printf '# fixture\n' > "$MATE_HOME/AGENTS.md"
  printf 'charter\n' > "$MATE_HOME/data/charter.md"
  git -C "$MATE_HOME" init -q
  git -C "$MATE_HOME" add AGENTS.md
  git -C "$MATE_HOME" -c user.name=Test -c user.email=test@example.invalid commit -qm initial
  printf 'codex\n' > "$MATE_PARENT/config/secondmate-harness"
  export FM_HOME="$MATE_PARENT" FM_ROOT="$ROOT" FM_ROOT_OVERRIDE="$ROOT" FM_BACKEND=hc
  export FM_SKIP_SECONDMATE_SYNC=1 FM_SKIP_SECONDMATE_INHERIT=1 FM_SPAWN_NO_GUARD=1
  "$ROOT/bin/fm-spawn.sh" mate "$MATE_HOME" "$TMP_ROOT/bin/codex stub" --secondmate || fail "hc secondmate spawn failed"
  MATE_META="$MATE_PARENT/state/mate.meta"
  MATE_TARGET=$(fm_backend_target_of_meta "$MATE_META")
  mate_alive() { [ "$(fm_backend_agent_state hc "$MATE_TARGET")" = alive ]; }
  wait_for 20 mate_alive || fail "secondmate did not start in its recorded hc terminal"
  assert_equals "$(fm_backend_hc_endpoint_state "$MATE_TARGET" fm-mate)" ready "secondmate endpoint belongs to the launching home"
  grep -Fx "$(printf '%s\t%s' "$MATE_HOME" "$MATE_HOME")" "$FM_HC_MATE_TEST_LOG" >/dev/null || fail "secondmate did not run in its own home"
  grep -qx 'kind=secondmate' "$MATE_META" || fail "secondmate kind was not recorded"
  grep -qx "home=$MATE_HOME" "$MATE_META" || fail "secondmate home was not recorded"
  "$ROOT/bin/fm-control.sh" mate interrupt || fail "hc secondmate interrupt failed"
  "$ROOT/bin/fm-control.sh" mate exit || fail "hc secondmate exit failed"
  assert_equals "$(fm_backend_agent_state hc "$MATE_TARGET")" dead "exit leaves the terminal and stops the agent"
  "$ROOT/bin/fm-control.sh" mate relaunch || fail "hc secondmate relaunch failed"
  wait_for 20 mate_alive || fail "relaunch did not start a replacement"
  assert_equals "$(fm_backend_target_of_meta "$MATE_META")" "$MATE_TARGET" "relaunch preserves the endpoint"

  fm_backend_hc_parse_target "$MATE_TARGET" || fail "invalid secondmate target"
  "$ROOT/bin/fm-hc-lab.sh" run "$HC_TEST_SES" kill "$FM_BACKEND_HC_ADDRESS" --json >/dev/null || fail "could not finish fixture terminal"
  out=$("$ROOT/bin/fm-control.sh" mate exit) || fail "control did not recognize a finished secondmate: $out"
  case "$out" in *endpoint-gone*) ;; *) fail "finished endpoint returned $out" ;; esac
  export FM_ROOT="$ROOT" STATE="$MATE_PARENT/state"
  # shellcheck source=bin/fm-secondmate-liveness-lib.sh
  . "$ROOT/bin/fm-secondmate-liveness-lib.sh"
  fm_sm_live_require_locks
  fm_secondmate_liveness_lock mate || fail "could not lock secondmate recovery"
  fm_secondmate_liveness_probe "$MATE_META" mate full
  assert_equals "$FM_SM_LIVE_STATUS:$FM_SM_LIVE_STATE" relaunchable:missing "finished terminal is recoverable"
  fm_secondmate_liveness_relaunch "$MATE_META" mate || fail "secondmate recovery failed: $FM_SM_LIVE_OUT"
  fm_secondmate_liveness_unlock mate
  OLD_TARGET=$MATE_TARGET
  MATE_TARGET=$(fm_backend_target_of_meta "$MATE_META")
  [ "$MATE_TARGET" != "$OLD_TARGET" ] || fail "recovery did not publish a replacement endpoint"
  wait_for 20 mate_alive || fail "recovered secondmate did not start"
  "$ROOT/bin/fm-control.sh" mate exit || fail "could not stop recovered fixture agent"
  fm_secondmate_liveness_lock mate || fail "could not lock dead-shell recovery"
  fm_secondmate_liveness_probe "$MATE_META" mate full
  assert_equals "$FM_SM_LIVE_STATUS:$FM_SM_LIVE_STATE:$FM_SM_LIVE_KILL" relaunchable:dead:1 "dead shell needs replacement"
  fm_secondmate_liveness_relaunch "$MATE_META" mate || fail "dead-shell recovery failed: $FM_SM_LIVE_OUT"
  fm_secondmate_liveness_unlock mate
  OLD_TARGET=$MATE_TARGET
  MATE_TARGET=$(fm_backend_target_of_meta "$MATE_META")
  [ "$MATE_TARGET" != "$OLD_TARGET" ] || fail "dead-shell recovery did not replace the endpoint"
  wait_for 20 mate_alive || fail "dead-shell recovery did not start an agent"
  assert_equals "$(fm_backend_hc_endpoint_state "$OLD_TARGET")" absent "dead-shell recovery removed the old terminal"
  pass "hc smoke: secondmate spawn, control, relaunch and recovery"

  SHIP_HOME="$TMP_ROOT/ship-home"
  SHIP_PROJECT="$TMP_ROOT/ship-project"
  SHIP_WORKTREE="$TMP_ROOT/ship-worktree"
  mkdir -p "$SHIP_HOME/state" "$SHIP_HOME/data/hcproof" "$SHIP_HOME/config"
  fm_git_init_commit "$SHIP_PROJECT"
  git clone -q "$SHIP_PROJECT" "$SHIP_WORKTREE" || fail "could not clone fixture project"
  git -C "$SHIP_WORKTREE" checkout -qb fm/hcproof || fail "could not create fixture branch"
  printf 'uncommitted fixture\n' > "$SHIP_WORKTREE/uncommitted"
  printf '# Task\n\n## Captain\047s intent\nKeep the fixture.\n\n## Firstmate spec\nKeep the worktree.\n' > "$SHIP_HOME/data/hcproof/brief.md"
  export FM_HOME="$SHIP_HOME"
  SHIP_ADDR=$(fm_backend_hc_create_task "$SES" fm-hcproof "$SHIP_WORKTREE" ship) || fail "could not create ship fixture"
  SHIP_TARGET="$SES:$SHIP_ADDR"
  fm_backend_hc_send_text_line "$SHIP_TARGET" "exec codex" fm-hcproof || fail "could not start ship fixture agent"
  ship_identity_ready() { SHIP_IDENTITY=$(fm_backend_hc_agent_identity "$SHIP_TARGET" 2>/dev/null); [ -n "$SHIP_IDENTITY" ]; }
  wait_for 20 ship_identity_ready || fail "could not identify ship fixture agent"
  IFS=$'\t' read -r SHIP_PID SHIP_START <<EOF
$SHIP_IDENTITY
EOF
  SHIP_CORE=$(fm_backend_hc_core_id "$SES") || fail "could not identify the lab core"
  cat > "$SHIP_HOME/state/hcproof.meta" <<EOF
window=$SHIP_TARGET
endpoint_task_id=hcproof
worktree=$SHIP_WORKTREE
project=$SHIP_PROJECT
harness=codex
kind=ship
mode=local-only
yolo=off
branch=fm/hcproof
backend=hc
hc_session=$SES
hc_terminal=$SHIP_ADDR
hc_core=$SHIP_CORE
hc_agent_pid=$SHIP_PID
hc_agent_start=$SHIP_START
EOF
  "$ROOT/bin/fm-hc-lab.sh" run "$SES" kill --json "$SHIP_ADDR" >/dev/null || fail "could not kill ship terminal"
  sed -i.bak 's/^hc_core=.*/hc_core=wrong-core/' "$SHIP_HOME/state/hcproof.meta"
  if "$ROOT/bin/fm-control.sh" hcproof exit > "$TMP_ROOT/wrong-core.out" 2>&1; then
    fail "a different core must refuse exit"
  fi
  grep -q 'core identity differs' "$TMP_ROOT/wrong-core.out" || fail "wrong-core refusal was not explained"
  if "$ROOT/bin/fm-control.sh" hcproof relaunch --note "wrong core" > "$TMP_ROOT/wrong-core-relaunch.out" 2>&1; then
    fail "a different core must refuse relaunch"
  fi
  grep -q 'core identity differs' "$TMP_ROOT/wrong-core-relaunch.out" || fail "wrong-core relaunch refusal was not explained"
  sed -i.bak "s/^hc_core=.*/hc_core=$SHIP_CORE/" "$SHIP_HOME/state/hcproof.meta"
  "$ROOT/bin/fm-control.sh" hcproof exit > "$TMP_ROOT/ship-exit.out" || fail "ship exit did not prove absence"
  "$ROOT/bin/fm-control.sh" hcproof relaunch --note "resume fixture" > "$TMP_ROOT/ship-relaunch.out" 2>&1 || {
    cat "$TMP_ROOT/ship-relaunch.out"
    fail "ship reclaim failed"
  }
  SHIP_NEW_TARGET=$(fm_backend_target_of_meta "$SHIP_HOME/state/hcproof.meta")
  [ "$SHIP_NEW_TARGET" != "$SHIP_TARGET" ] || fail "reclaim did not replace the endpoint"
  [ "$(fm_meta_get "$SHIP_HOME/state/hcproof.meta" hc_core)" = "$SHIP_CORE" ] || fail "relaunch did not record the core identity"
  [ -n "$(fm_meta_get "$SHIP_HOME/state/hcproof.meta" hc_agent_pid)" ] || fail "relaunch did not record the replacement agent PID"
  [ -n "$(fm_meta_get "$SHIP_HOME/state/hcproof.meta" hc_agent_start)" ] || fail "relaunch did not record the replacement agent start time"
  [ "$(fm_meta_get "$SHIP_HOME/state/hcproof.meta" worktree)" = "$SHIP_WORKTREE" ] || fail "reclaim changed the worktree"
  [ "$(cat "$SHIP_WORKTREE/uncommitted")" = 'uncommitted fixture' ] || fail "reclaim changed uncommitted work"
  SHIP_COUNT=$("$ROOT/bin/fm-hc-lab.sh" run "$SES" ls --json --label firstmate.task=fm-hcproof --label "firstmate.home=$(fm_backend_hometag)" | jq '.terminals | length')
  [ "$SHIP_COUNT" = 1 ] || fail "reclaim did not leave exactly one live fixture terminal"
  pass "hc smoke: missing ship reclaims one terminal in the same worktree and refuses a different core"

  export FM_HOME="$MATE_PARENT"
  CLAUDE_HOME="$TMP_ROOT/claude-home"
  mkdir -p "$CLAUDE_HOME/bin" "$CLAUDE_HOME/data" "$CLAUDE_HOME/state" "$TMP_ROOT/claude-config"
  printf 'hooks\n' > "$CLAUDE_HOME/.fm-secondmate-home"
  printf '# fixture\n' > "$CLAUDE_HOME/AGENTS.md"
  printf 'charter\n' > "$CLAUDE_HOME/data/charter.md"
  git -C "$CLAUDE_HOME" init -q
  git -C "$CLAUDE_HOME" add AGENTS.md
  git -C "$CLAUDE_HOME" -c user.name=Test -c user.email=test@example.invalid commit -qm initial
  export CLAUDE_CONFIG_DIR="$TMP_ROOT/claude-config"
  "$ROOT/bin/fm-spawn.sh" hooks "$CLAUDE_HOME" claude --secondmate || fail "Claude fixture spawn failed"
  # shellcheck source=bin/fm-busy-lib.sh
  . "$ROOT/bin/fm-busy-lib.sh"
  SETTINGS="$STATE/hooks.claude-settings.json"
  for hook in Stop UserPromptSubmit; do
    command=$(jq -r ".hooks.${hook}[0].hooks[0].command" "$SETTINGS")
    bash -c "$command" || fail "$hook fixture hook failed"
    verdict=$(fm_busy_classify_meta "$STATE/hooks.meta" hooks "$STATE")
    case "$hook:$verdict" in Stop:'idle claude-hook'|UserPromptSubmit:'busy claude-hook') ;; *) fail "$hook classified $verdict" ;; esac
  done
  pass "hc smoke: secondmate hooks update the parent busy state"
else
  echo "skip: cc not found (hc secondmate lifecycle stand-in)"
fi
echo FM_TEST_COMPLETE
