#!/usr/bin/env bash
# =============================================================================
#  bifrost test suite
#
#  Runs against a mock `ssh` binary so the suite is hermetic: no VPS, no
#  network, no side effects on the real ~/.ssh/config.
#
#      ./tests/test_bifrost.sh
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
BIFROST="$ROOT/bin/bifrost"
MOCK_DIR="$(mktemp -d)"
LOG="$MOCK_DIR/calls.log"

C_GRN=$'\033[32m'; C_RED=$'\033[31m'; C_BLD=$'\033[1m'; C_OFF=$'\033[0m'
[[ -t 1 ]] || { C_GRN=''; C_RED=''; C_BLD=''; C_OFF=''; }

PASS=0; FAIL=0

cleanup() { rm -rf "$MOCK_DIR"; }
trap cleanup EXIT

# ------------------------------------------------------------- mock ssh ----
cat > "$MOCK_DIR/ssh" <<'MOCK'
#!/usr/bin/env bash
# Mock ssh used by the bifrost test suite.
case "${1:-}" in
    -G)
        if [[ "${MOCK_CFG:-minimal}" == "full" ]]; then
            cat <<EOF
host asgard
hostname 203.0.113.10
port 22
user deploy
identityfile ${HOME}/.ssh/id_ed25519
controlmaster auto
controlpath ${HOME}/.ssh/bifrost-deploy@203.0.113.10:22
controlpersist 10m
batchmode yes
stricthostkeychecking accept-new
serveraliveinterval 15
serveralivecountmax 3
connecttimeout 15
EOF
        else
            cat <<EOF
host asgard
hostname asgard
port 22
user ${USER}
identityfile ${HOME}/.ssh/id_ed25519
controlmaster no
controlpath none
controlpersist no
batchmode no
stricthostkeychecking ask
serveraliveinterval 0
serveralivecountmax 3
connecttimeout 0
EOF
        fi
        exit 0
        ;;
    -O)
        echo "Master running (pid=4242)"
        exit 0
        ;;
esac
printf '%s\n' "$@" >> "$MOCK_LOG"
if [[ "${MOCK_SLEEP:-0}" != "0" ]]; then sleep "$MOCK_SLEEP"; fi
exit "${MOCK_EXIT:-0}"
MOCK
chmod +x "$MOCK_DIR/ssh"

export PATH="$MOCK_DIR:$PATH"
export MOCK_LOG="$LOG"
export HOME="${HOME:-/tmp}"

run() { "$BIFROST" "$@" 2>&1; }

check() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        printf '  %sPASS%s %s\n' "$C_GRN" "$C_OFF" "$desc"
        PASS=$((PASS+1))
    else
        printf '  %sFAIL%s %s\n' "$C_RED" "$C_OFF" "$desc"
        printf '        expected: %q\n' "$expected"
        printf '        actual:   %q\n' "$actual"
        FAIL=$((FAIL+1))
    fi
}

contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        printf '  %sPASS%s %s\n' "$C_GRN" "$C_OFF" "$desc"
        PASS=$((PASS+1))
    else
        printf '  %sFAIL%s %s\n' "$C_RED" "$C_OFF" "$desc"
        printf '        missing: %q\n' "$needle"
        printf '        in:      %q\n' "$haystack"
        FAIL=$((FAIL+1))
    fi
}

section() { printf '\n%s%s%s\n' "$C_BLD" "$1" "$C_OFF"; }

# ============================================================================
section "usage and metadata"

out="$(run)"; rc=$?
check "no arguments exits 1" "1" "$rc"
contains "no arguments prints usage" "USAGE" "$out"

out="$(run help)"; rc=$?
check "help exits 0" "0" "$rc"
contains "help mentions bifrost" "bifrost" "$out"
contains "help documents the agent operating rules" "AGENT OPERATING RULES" "$out"
contains "help explains what bifrost is for" "DESCRIPTION" "$out"
contains "help warns about interactive commands" "NON-INTERACTIVE" "$out"

out="$(run --help)"; rc=$?
check "--help exits 0" "0" "$rc"
contains "--help prints the same documentation" "AGENT OPERATING RULES" "$out"

out="$(run "")"; rc=$?
check "empty argument exits 0" "0" "$rc"
contains "empty argument prints the help text" "USAGE" "$out"

out="$(run version)"; rc=$?
check "version exits 0" "0" "$rc"
contains "version prints a version string" "bifrost " "$out"

# ============================================================================
section "remote execution"

: > "$LOG"
out="$(run "echo hello")"; rc=$?
check "simple command exits 0" "0" "$rc"
contains "command reached the remote host" "asgard" "$(cat "$LOG")"
contains "remote command passed as a single argument" "echo hello" "$(cat "$LOG")"

: > "$LOG"
run "uptime && free -h" >/dev/null
contains "multi-word command preserved verbatim" "uptime && free -h" "$(cat "$LOG")"

: > "$LOG"
run "cat /var/log/syslog | tail -n 50" >/dev/null
contains "pipes preserved" "cat /var/log/syslog | tail -n 50" "$(cat "$LOG")"

: > "$LOG"
run "systemctl status nginx" >/dev/null
args="$(cat "$LOG")"
contains "-T disables the pseudo-terminal" "-T" "$args"
contains "BatchMode is forced on" "BatchMode=yes" "$args"
contains "StrictHostKeyChecking is set to accept-new" "StrictHostKeyChecking=accept-new" "$args"
contains "ControlMaster is enabled" "ControlMaster=auto" "$args"
contains "ControlPersist is enabled" "ControlPersist=10m" "$args"
contains "ServerAliveInterval is set" "ServerAliveInterval=15" "$args"
contains "ConnectTimeout is set" "ConnectTimeout=15" "$args"
contains "LogLevel is quieted" "LogLevel=ERROR" "$args"

# ============================================================================
section "exit code passthrough"

: > "$LOG"
MOCK_EXIT=42 run "exit 42" >/dev/null; rc=$?
check "remote exit code 42 is propagated" "42" "$rc"

MOCK_EXIT=127 run "command not found" >/dev/null; rc=$?
check "remote exit code 127 is propagated" "127" "$rc"

MOCK_EXIT=0 run "true" >/dev/null; rc=$?
check "success exit code 0 is propagated" "0" "$rc"

# ============================================================================
section "existing ssh config wins"

: > "$LOG"
MOCK_CFG=full run "echo hi" >/dev/null
args="$(cat "$LOG")"
if [[ "$args" == *"ControlMaster=auto"* ]]; then
    printf '  %sFAIL%s ControlMaster should not be re-specified\n' "$C_RED" "$C_OFF"; FAIL=$((FAIL+1))
else
    printf '  %sPASS%s configured ControlMaster is not overridden\n' "$C_GRN" "$C_OFF"; PASS=$((PASS+1))
fi
if [[ "$args" == *"BatchMode=yes"* ]]; then
    printf '  %sFAIL%s BatchMode should not be re-specified\n' "$C_RED" "$C_OFF"; FAIL=$((FAIL+1))
else
    printf '  %sPASS%s configured BatchMode is not overridden\n' "$C_GRN" "$C_OFF"; PASS=$((PASS+1))
fi

# ============================================================================
section "subcommand escaping"

: > "$LOG"
run -- status >/dev/null
contains "-- forces remote execution for reserved words" "status" "$(cat "$LOG")"

: > "$LOG"
run -- ping >/dev/null
contains "-- escapes the ping subcommand" "ping" "$(cat "$LOG")"

# ============================================================================
section "bridge subcommands"

out="$(run status)"; rc=$?
check "status exits 0" "0" "$rc"
contains "status shows the control path" "control path" "$out"

out="$(run open)"; rc=$?
check "open exits 0" "0" "$rc"
contains "open reports success" "Bridge open" "$out"

out="$(run reset)"; rc=$?
check "reset exits 0" "0" "$rc"
contains "reset reports closure" "Bridge closed" "$out"

out="$(run ping 2)"; rc=$?
check "ping exits 0" "0" "$rc"
contains "ping reports round trips" "reply" "$out"

out="$(run --ping)"; rc=$?
check "--ping exits 0" "0" "$rc"
contains "--ping reports reachability" "reachable" "$out"

# ============================================================================
section "timeout guard"

: > "$LOG"
MOCK_SLEEP=5 BIFROST_TIMEOUT=1 run "sleep 5" >/dev/null; rc=$?
check "a hanging remote command is killed by the timeout" "124" "$rc"

# ============================================================================
section "doctor"

out="$(run doctor)"; rc=$?
contains "doctor reports the toolchain" "==> Toolchain" "$out"
contains "doctor reports the target host" "==> Target host" "$out"
contains "doctor checks authentication" "==> Authentication" "$out"
contains "doctor checks the network" "==> Network" "$out"
contains "doctor checks the bridge" "==> Bridge" "$out"
contains "doctor checks the agent protocol" "==> Agent protocol" "$out"
contains "doctor prints a summary" "Result:" "$out"

# The doctor must not leak shell errors into its report.
if [[ "$out" == *"command not found"* || "$out" == *"cannot open"* || "$out" == *"unbound variable"* ]]; then
    printf '  %sFAIL%s doctor output contains shell errors\n' "$C_RED" "$C_OFF"
    printf '        %q\n' "$out"
    FAIL=$((FAIL+1))
else
    printf '  %sPASS%s doctor output is free of shell errors\n' "$C_GRN" "$C_OFF"
    PASS=$((PASS+1))
fi

# The same check applies to every other subcommand.
for sub in status help version; do
    sout="$(run "$sub")" 2>&1
    if [[ "$sout" == *"command not found"* || "$sout" == *"cannot open"* ]]; then
        printf '  %sFAIL%s "%s" output contains shell errors\n' "$C_RED" "$C_OFF" "$sub"
        FAIL=$((FAIL+1))
    else
        printf '  %sPASS%s "%s" output is free of shell errors\n' "$C_GRN" "$C_OFF" "$sub"
        PASS=$((PASS+1))
    fi
done

# ============================================================================
printf '\n%s%d passed, %d failed%s\n' "$C_BLD" "$PASS" "$FAIL" "$C_OFF"
(( FAIL == 0 )) || exit 1
exit 0
