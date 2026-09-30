#!/usr/bin/env bash
# test-rpc.sh — Integration test for switching the openmediavault-writecache
# workspace backing through the RPC, the way the web UI does it.
#
# Usage: sudo ./tests/test-rpc.sh [options] [STEP ...]
#
# Each STEP (tmpfs, zram or path) is applied with WriteCache.setSettings —
# which runs 'omv-writecache unmount --reconfigure' when the backing changes —
# followed by 'omv-salt deploy run writecache' (service restart + 'remount
# --reconfigure'). After every step the live system is checked:
#   - RPC and salt succeeded
#   - the workspace is really mounted as the requested type
#   - every configured path is overlaid, all from the current workspace (no
#     overlays or lower binds left behind on a previous workspace)
#   - no leaked zram devices
#   - no Tracebacks, 'fuser' kills or WORKSPACE_NOT_READY in the log; lazy
#     unmounts / other ERRORs warned
#   - the change is applied by a single remount, without a service restart
#   - no rollback of /var/log: a marker line in omv-writecache.log and a line
#     in a sentinel file are written before every step and must survive
#   - (default on) a stale cached copy planted in the shared folder workspace
#     is quarantined to stale/ instead of being written back
#
# omv-writecache.log (before/after), per-step logs, salt output and mount
# snapshots are copied to an output directory for analysis. The original
# settings are restored on exit, also after a failure or Ctrl-C.
#
# Requirements:
#   - Run as root
#   - OMV with the writecache plugin installed and enabled
#   - For 'path' steps: a shared folder for the workspace (--sharedfolder, or
#     the one currently configured)

set -uo pipefail

usage() {
    cat >&2 <<EOF
Usage: sudo $0 [options] [STEP ...]

STEP is one of: tmpfs, zram, path (default: path zram path tmpfs)

Options:
  -s, --sharedfolder NAME|UUID  shared folder for 'path' steps
                                (default: the one currently configured)
  -o, --out DIR                 output directory
                                (default: /root/omv-writecache-rpc-test-<timestamp>)
      --no-restore              leave the last step's settings in place
      --no-stale-check          don't plant a stale cached copy before
                                switching to the shared folder workspace
      --settle SECONDS          wait after each salt run (default: 2)
  -h, --help                    show this help

Example:
  sudo $0 -s writecache path zram path tmpfs zram tmpfs
EOF
}

SHARED_FOLDER=""
OUT_DIR=""
RESTORE=1
STALE_CHECK=1
SETTLE=2
declare -a STEPS=()

while [ $# -gt 0 ]; do
    case "$1" in
        -s|--sharedfolder) SHARED_FOLDER="${2:-}"; shift 2 ;;
        -o|--out) OUT_DIR="${2:-}"; shift 2 ;;
        --no-restore) RESTORE=0; shift ;;
        --no-stale-check) STALE_CHECK=0; shift ;;
        --settle) SETTLE="${2:-2}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        tmpfs|zram|path) STEPS+=("$1"); shift ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done
[ ${#STEPS[@]} -eq 0 ] && STEPS=(path zram path tmpfs)

if [ "$(id -u)" -ne 0 ]; then
    echo "Must be run as root." >&2
    exit 1
fi

for tool in omv-rpc omv-salt omv-writecache jq findmnt; do
    command -v "$tool" >/dev/null 2>&1 || { echo "Missing required tool: $tool" >&2; exit 1; }
done

LOG=/var/log/omv-writecache.log
CONFIG_YAML=/etc/omv-writecache/config.yaml
SENTINEL_NAME=wc-rpc-test.log
SENTINEL=/var/log/$SENTINEL_NAME
RAM_ROOT=/run/omv-writecache
RUN_ID="$(date +%s)-$$"

[ -z "$OUT_DIR" ] && OUT_DIR="/root/omv-writecache-rpc-test-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT_DIR/steps" || exit 1
SUMMARY="$OUT_DIR/summary.txt"

# ---------------------------------------------------------------------------
# Colours / counters
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0
SKIP=0
declare -a FAILED_TESTS=()

# All UI output goes to stderr; a colour-free copy is kept in summary.txt.
exec 2> >(tee >(sed -u 's/\x1b\[[0-9;]*m//g' >> "$SUMMARY") >&2)

section() { echo -e "\n${CYAN}${BOLD}=== $* ===${NC}" >&2; }
info()    { echo -e "  ${YELLOW}»${NC} $*" >&2; }

_pass() { echo -e "  ${GREEN}PASS${NC}  $1" >&2; ((PASS++)) || true; }
_fail() {
    echo -e "  ${RED}FAIL${NC}  $1" >&2
    [ -n "${2:-}" ] && echo -e "         ${RED}→${NC} $2" >&2
    ((FAIL++)) || true
    FAILED_TESTS+=("$1")
}
_warn() {
    echo -e "  ${YELLOW}WARN${NC}  $1" >&2
    [ -n "${2:-}" ] && echo -e "         ${YELLOW}→${NC} $2" >&2
    ((WARN++)) || true
}
_skip() { echo -e "  ${YELLOW}SKIP${NC}  $1${2:+  ($2)}" >&2; ((SKIP++)) || true; }

# ---------------------------------------------------------------------------
# RPC helpers
# ---------------------------------------------------------------------------

# Last successful RPC output is stored here.  Never call assert_rpc inside
# a $() subshell — that would prevent PASS/FAIL counter updates from
# propagating back to the parent shell.
RPC_OUT=""

# Assert RPC succeeds. Optional 5th arg: grep pattern that must appear.
# Result JSON is available in $RPC_OUT after the call.
assert_rpc() {
    local desc=$1 svc=$2 method=$3 params=${4:-'{}'} pattern=${5:-}
    local out ec=0
    RPC_OUT=""
    out=$(omv-rpc -u admin "$svc" "$method" "$params" 2>&1) || ec=$?
    if [ $ec -ne 0 ]; then
        _fail "$desc" "$(echo "$out" | tail -3)"
        return 1
    fi
    if [ -n "$pattern" ] && ! echo "$out" | grep -q "$pattern"; then
        _fail "$desc" "Pattern '$pattern' not found in: ${out:0:300}"
        return 1
    fi
    _pass "$desc"
    RPC_OUT="$out"
    return 0
}

get_sf_path() {
    omv-rpc -u admin "ShareMgmt" "getPath" "{\"uuid\":\"$1\"}" 2>/dev/null | jq -r '.' | sed 's:/*$::'
}

# setSettings params for a step, derived from the current settings.
settings_for() {
    local target=$1 cur=$2
    case "$target" in
        tmpfs) jq -c 'del(.status) | .use_tmpfs = true  | .ram_backing = "tmpfs"' <<<"$cur" ;;
        zram)  jq -c 'del(.status) | .use_tmpfs = true  | .ram_backing = "zram"'  <<<"$cur" ;;
        path)  jq -c --arg sf "$SF_UUID" 'del(.status) | .use_tmpfs = false | .sharedfolderref = $sf' <<<"$cur" ;;
    esac
}

# Backing type (tmpfs|zram|path) of a settings object.
settings_type() {
    if [ "$(jq -r '.use_tmpfs' <<<"$1")" = "false" ]; then
        echo path
    elif [ "$(jq -r '.ram_backing' <<<"$1")" = "zram" ]; then
        echo zram
    else
        echo tmpfs
    fi
}

# ---------------------------------------------------------------------------
# State helpers
# ---------------------------------------------------------------------------

# Top-level scalar from config.yaml, quotes stripped.
yaml_value() {
    sed -n "s/^$1: *//p" "$CONFIG_YAML" 2>/dev/null | head -1 | sed 's/^"\(.*\)"$/\1/'
}

# "path<TAB>mode" for every configured path.
configured_paths() {
    awk '/^paths: *\|/{f=1; next} /^[a-z_]+:/{f=0} f' "$CONFIG_YAML" \
        | sed 's/^ *//' | grep -v '^#' | grep -v '^$' \
        | awk -F' = ' '{p=$1; m=$2; sub(/ .*/, "", m); print p "\t" m}'
}

expected_overlay_count() {
    local n=0 p
    while IFS=$'\t' read -r p _; do
        [ -d "$p" ] && n=$((n + 1))
    done < <(configured_paths)
    echo "$n"
}

# Our overlays: "<target> <upperdir>" (octal escapes from /proc/mounts decoded).
writecache_overlays() {
    local target opts upper
    awk '$3 == "overlay" {print $2, $4}' /proc/mounts | while read -r target opts; do
        upper="$(grep -o 'upperdir=[^,]*' <<<"$opts" | cut -d= -f2-)"
        case "$upper" in */upper) ;; *) continue ;; esac
        printf '%b %b\n' "$target" "$upper"
    done
}

# Lower bind mounts: mountpoints ending in /lower next to an 'upper' dir.
writecache_lower_binds() {
    local mp
    awk '{print $2}' /proc/mounts | while read -r mp; do
        mp="$(printf '%b' "$mp")"
        case "$mp" in */lower) [ -d "$(dirname "$mp")/upper" ] && echo "$mp" ;; esac
    done
}

# zram devices that are sized but neither mounted nor used for swap.
leaked_zram() {
    local d dev
    for d in /sys/block/zram*; do
        [ -e "$d" ] || continue
        dev="/dev/$(basename "$d")"
        [ "$(cat "$d/disksize" 2>/dev/null || echo 0)" = "0" ] && continue
        grep -q "^$dev " /proc/mounts && continue
        grep -q "^$dev " /proc/swaps && continue
        echo "$dev"
    done
}

snapshot() {
    {
        echo "# config.yaml"; cat "$CONFIG_YAML" 2>/dev/null
        echo; echo "# writecache mounts"
        grep -E "omv-writecache|/dev/zram| overlay " /proc/mounts
        echo; echo "# overlays (target upperdir)"; writecache_overlays
        echo; echo "# lower binds"; writecache_lower_binds
        echo; echo "# zram"
        for d in /sys/block/zram*; do
            [ -e "$d" ] && echo "$(basename "$d") disksize=$(cat "$d/disksize" 2>/dev/null)"
        done
        cat /proc/swaps
        echo; echo "# omv-writecache status"; omv-writecache status 2>&1
        echo; echo "# omv-writecache df"; omv-writecache df 2>&1
        echo; echo "# systemctl status omv-writecache-setup"
        systemctl --no-pager status omv-writecache-setup.service 2>&1 | head -20
    } > "$1"
}

# Log lines from a marker to the end of the current log.
log_since_marker() {
    local line
    line="$(grep -nF -- "$1" "$LOG" | tail -1 | cut -d: -f1)"
    [ -n "$line" ] && tail -n +"$line" "$LOG"
}

# ---------------------------------------------------------------------------
# Cleanup — restores the original settings even after a failure or Ctrl-C
# ---------------------------------------------------------------------------
ORIG=""
RESTORED=0
declare -a MARKERS=()

cleanup() {
    if [ $RESTORE -eq 1 ] && [ $RESTORED -eq 0 ] && [ -n "$ORIG" ]; then
        section "Cleanup: restoring original settings"
        info "setSettings + deploy with the original settings"
        omv-rpc -u admin "WriteCache" "setSettings" "$(jq -c 'del(.status)' <<<"$ORIG")" \
            > "$OUT_DIR/steps/cleanup-restore-rpc.out" 2>&1 || true
        omv-salt deploy run writecache > "$OUT_DIR/steps/cleanup-restore-salt.out" 2>&1 || true
        RESTORED=1
    fi
    [ -f "$LOG" ] && cp -a "$LOG" "$OUT_DIR/omv-writecache.log.after" 2>/dev/null
    snapshot "$OUT_DIR/state.after.txt"
    if [ -f "$SENTINEL" ]; then
        cp -a "$SENTINEL" "$OUT_DIR/$SENTINEL_NAME" 2>/dev/null
        rm -f "$SENTINEL"
    fi
    # Clear the web UI "apply changes" banner left by the setSettings calls.
    info "Deploying pending config changes asynchronously (clears web UI banner)"
    nohup omv-salt deploy run --quiet --append-dirty >/dev/null 2>&1 &
    info "Output: $OUT_DIR"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# One step: switch the backing via RPC, deploy, verify
# ---------------------------------------------------------------------------

# run_step N TARGET LABEL [PARAMS_JSON]
# PARAMS_JSON overrides the settings derived from the current ones (restore).
run_step() {
    local n=$1 target=$2 label=$3 override=${4:-}
    local dir; dir="$OUT_DIR/steps/$(printf '%02d' "$n")-$label"
    mkdir -p "$dir"
    section "Step $n: $label"

    local prev_type; prev_type="$(yaml_value workspace_type)"
    info "workspace: ${prev_type:-?} -> $target"

    # Plant a stale cached copy in the shared folder workspace before switching
    # to it: an old copy of the sentinel, older than the real one. The switch
    # must move it to stale/ instead of writing it back over the real file.
    local planted=0
    if [ "$target" = path ] && [ $STALE_CHECK -eq 1 ] && [ "$prev_type" != path ]; then
        local vl_mode
        vl_mode="$(configured_paths | awk -F'\t' '$1 == "/var/log" {print $2}')"
        if [ "$vl_mode" != flush ]; then
            _skip "stale cached copy check" "/var/log is not flush-policy"
        elif [ ! -d "$WS_PATH/var_log/upper" ]; then
            _skip "stale cached copy check" "$WS_PATH/var_log/upper does not exist yet"
        else
            echo "PLANTED-OLD-COPY run=$RUN_ID" > "$WS_PATH/var_log/upper/$SENTINEL_NAME"
            planted=1
            sleep 1.1   # the real sentinel written below must be strictly newer
            info "planted stale copy: $WS_PATH/var_log/upper/$SENTINEL_NAME"
        fi
    fi

    # Rollback markers: a line in omv-writecache.log and one in a sentinel file.
    local marker="RPC_TEST_MARKER run=$RUN_ID step=$n target=$label"
    echo "$(date '+%F %T') [TEST] $marker" >> "$LOG"
    echo "$marker" >> "$SENTINEL"
    MARKERS+=("$marker")

    # 1) setSettings via RPC (runs 'unmount --reconfigure' on a backing change)
    local params
    if [ -n "$override" ]; then
        params="$override"
    else
        assert_rpc "getSettings" "WriteCache" "getSettings" '{}' || return
        params="$(settings_for "$target" "$RPC_OUT")"
    fi
    jq . <<<"$params" > "$dir/settings.json"
    assert_rpc "setSettings -> $target" "WriteCache" "setSettings" "$params" || return
    echo "$RPC_OUT" > "$dir/rpc.out"

    # 2) apply with saltstack
    local out ec=0
    out=$(omv-salt deploy run writecache 2>&1) || ec=$?
    echo "$out" > "$dir/salt.out"
    if [ $ec -eq 0 ] && ! grep -qE '^Failed: +[1-9]' <<<"$out"; then
        _pass "omv-salt deploy run writecache"
    else
        _fail "omv-salt deploy run writecache (step $n)" \
            "rc=$ec $(grep -m2 -E 'Result: False|Failed:' <<<"$out" | tr '\n' ' ')"
    fi
    sleep "$SETTLE"

    snapshot "$dir/state.txt"
    log_since_marker "$marker" > "$dir/log.txt"
    local slice="$dir/log.txt"

    # 3) config and workspace type
    local got_type; got_type="$(yaml_value workspace_type)"
    if [ "$got_type" = "$target" ]; then
        _pass "config.yaml workspace_type=$got_type"
    else
        _fail "config.yaml workspace_type (step $n)" "got '$got_type', expected '$target'"
    fi

    local root
    case "$target" in
        tmpfs)
            root="$RAM_ROOT"
            if [ "$(findmnt -no FSTYPE "$root" 2>/dev/null)" = tmpfs ]; then
                _pass "tmpfs mounted at $root"
            else
                _fail "tmpfs mounted at $root (step $n)" "$(findmnt -no SOURCE,FSTYPE "$root" 2>/dev/null)"
            fi ;;
        zram)
            root="$RAM_ROOT"
            case "$(findmnt -no SOURCE "$root" 2>/dev/null)" in
                /dev/zram*) _pass "zram mounted at $root ($(findmnt -no SOURCE "$root"))" ;;
                *) _fail "zram mounted at $root (step $n)" "$(findmnt -no SOURCE,FSTYPE "$root" 2>/dev/null)" ;;
            esac ;;
        path)
            root="$WS_PATH"
            if [ -d "$root" ]; then
                _pass "shared folder workspace $root"
            else
                _fail "shared folder workspace $root (step $n)" "directory missing"
            fi
            if findmnt -no FSTYPE "$RAM_ROOT" >/dev/null 2>&1; then
                _fail "$RAM_ROOT torn down (step $n)" "still mounted: $(findmnt -no SOURCE,FSTYPE "$RAM_ROOT")"
            else
                _pass "$RAM_ROOT torn down"
            fi ;;
    esac

    # 4) overlays: all configured paths, all from the current workspace
    local want got foreign
    want="$(expected_overlay_count)"
    got="$(writecache_overlays | wc -l)"
    if [ "$got" -eq "$want" ]; then
        _pass "overlays mounted: $got/$want"
    else
        _fail "overlays mounted (step $n)" "got $got, expected $want"
    fi
    foreign="$(writecache_overlays | awk -v r="$root/" 'index($2, r) != 1')"
    if [ -z "$foreign" ]; then
        _pass "all overlays use $root"
    else
        _fail "overlays left on another workspace (step $n)" "$(tr '\n' ';' <<<"$foreign")"
    fi
    foreign="$(writecache_lower_binds | awk -v r="$root/" 'index($0, r) != 1')"
    if [ -z "$foreign" ]; then
        _pass "no lower binds left on an old workspace"
    else
        _fail "lower binds left on an old workspace (step $n)" "$(tr '\n' ' ' <<<"$foreign")"
    fi

    # 5) zram leaks (beyond what was already leaked before the run)
    local leaks="" z
    for z in $(leaked_zram); do
        case " $BASELINE_ZRAM_LEAKS " in *" $z "*) ;; *) leaks="$leaks $z" ;; esac
    done
    if [ -z "$leaks" ]; then
        _pass "no leaked zram devices"
    else
        _fail "leaked zram devices (step $n)" "$leaks"
    fi

    # 6) this step's log
    if [ ! -s "$slice" ]; then
        _fail "step marker still in $LOG (step $n)" "missing right after the step: log rolled back"
    else
        if grep -q Traceback "$slice"; then
            _fail "no Python Traceback (step $n)" "see $slice"
        else
            _pass "no Python Traceback"
        fi
        if grep -q 'CMD: fuser' "$slice"; then
            _fail "no fuser kills during a settings change (step $n)" "$(grep -m2 'CMD: fuser' "$slice")"
        else
            _pass "no fuser kills"
        fi
        if [ "$prev_type" = "$target" ]; then
            _skip "RPC pre-unmount with --reconfigure" "backing unchanged"
        elif grep -q 'SCRIPT_START: omv-writecache unmount --reconfigure' "$slice"; then
            _pass "RPC pre-unmount ran with --reconfigure"
        else
            _fail "RPC pre-unmount ran with --reconfigure (step $n)" "not found in $slice"
        fi
        local n_lazy n_err stale
        n_lazy="$(grep -c LAZY_UNMOUNT "$slice")"
        if [ "$n_lazy" -eq 0 ]; then
            _pass "no lazy unmounts"
        else
            _warn "$n_lazy lazy unmount(s)" \
                "$(grep LAZY_UNMOUNT "$slice" | sed 's/.*LAZY_UNMOUNT: //; s/ still busy.*//' | tr '\n' ' ')"
        fi
        # The pre-unmount flush skips an unmounted RAM workspace quietly now,
        # so a settings change must not log WORKSPACE_NOT_READY (or any ERROR).
        if grep -q WORKSPACE_NOT_READY "$slice"; then
            _fail "no WORKSPACE_NOT_READY on a settings change (step $n)" \
                "$(grep -c WORKSPACE_NOT_READY "$slice") in $slice"
        else
            _pass "no WORKSPACE_NOT_READY"
        fi
        n_err="$(grep -c '\[ERROR\]' "$slice")"
        if [ "$n_err" -eq 0 ]; then
            _pass "no ERROR lines"
        else
            _warn "$n_err ERROR line(s)" "$(grep '\[ERROR\]' "$slice" | head -2 | cut -c21- | tr '\n' ';')"
        fi
        # One remount applies the change; salt must not also restart the
        # service (ExecStop + ExecStart), which repeated the whole teardown/setup.
        local n_remount n_restart
        n_remount="$(grep -c 'SCRIPT_START: omv-writecache remount --reconfigure' "$slice")"
        n_restart="$(grep -cE 'SCRIPT_START: omv-writecache (rotateunmount|unmount|mount)$' "$slice")"
        if [ "$n_remount" -eq 1 ] && [ "$n_restart" -eq 0 ]; then
            _pass "applied with a single remount, no service restart"
        else
            _fail "applied with a single remount, no service restart (step $n)" \
                "remounts=$n_remount, service stop/start runs=$n_restart"
        fi
        stale="$(grep STALE_UPPER_QUARANTINED "$slice" | grep -v "$SENTINEL_NAME")"
        [ -n "$stale" ] && _warn "$(wc -l <<<"$stale") unexpected stale cached copies quarantined" "see $slice"
    fi

    # 7) sentinel must end with this step's line
    if [ "$(tail -1 "$SENTINEL" 2>/dev/null)" = "$marker" ]; then
        _pass "sentinel $SENTINEL is current"
    else
        _fail "sentinel $SENTINEL is current (step $n)" "last line: '$(tail -1 "$SENTINEL" 2>/dev/null)'"
    fi

    # 8) planted stale copy: quarantined, preserved, not written back
    if [ $planted -eq 1 ]; then
        local kept
        if grep -q "STALE_UPPER_QUARANTINED: $SENTINEL" "$slice"; then
            _pass "planted stale copy logged as quarantined"
        else
            _fail "planted stale copy logged as quarantined (step $n)" "no STALE_UPPER_QUARANTINED for $SENTINEL"
        fi
        kept="$(grep -rlx "PLANTED-OLD-COPY run=$RUN_ID" "$WS_PATH/var_log/stale" 2>/dev/null | head -1)"
        if [ -n "$kept" ]; then
            _pass "planted stale copy preserved at $kept"
        else
            _fail "planted stale copy preserved (step $n)" "not found under $WS_PATH/var_log/stale"
        fi
        if grep -qx "PLANTED-OLD-COPY run=$RUN_ID" "$SENTINEL"; then
            _fail "real $SENTINEL not overwritten by the stale copy (step $n)" "stale content found in $SENTINEL"
        else
            _pass "real $SENTINEL not overwritten by the stale copy"
        fi
        # Remove only what this run planted (and the dirs it left empty).
        if [ -n "$kept" ]; then
            rm -f "$kept"
            rmdir "$(dirname "$kept")" "$WS_PATH/var_log/stale" 2>/dev/null
        fi
    fi
}

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
section "Pre-flight"

assert_rpc "getSettings (original)" "WriteCache" "getSettings" '{}' || exit 1
ORIG="$RPC_OUT"
jq 'del(.status)' <<<"$ORIG" > "$OUT_DIR/settings.orig.json"
info "original backing: $(settings_type "$ORIG")"

SF_UUID=""
WS_PATH=""
if printf '%s\n' "${STEPS[@]}" | grep -qx path || [ "$(settings_type "$ORIG")" = path ]; then
    assert_rpc "enumerateSharedFolders" "ShareMgmt" "enumerateSharedFolders" '{}' || exit 1
    if [ -n "$SHARED_FOLDER" ]; then
        SF_UUID="$(jq -r --arg s "$SHARED_FOLDER" '.[] | select(.uuid == $s or .name == $s) | .uuid' <<<"$RPC_OUT" | head -1)"
    else
        SF_UUID="$(jq -r '.sharedfolderref // ""' <<<"$ORIG")"
    fi
    if [ -z "$SF_UUID" ]; then
        _fail "shared folder for 'path' steps" "pass --sharedfolder NAME; available: $(jq -r '[.[].name] | join(", ")' <<<"$RPC_OUT")"
        ORIG=""   # nothing changed yet: skip the restore
        exit 1
    fi
    WS_PATH="$(get_sf_path "$SF_UUID")"
    if [ -n "$WS_PATH" ] && [ -d "$WS_PATH" ]; then
        _pass "shared folder workspace: $WS_PATH"
    else
        _fail "shared folder workspace path" "ShareMgmt.getPath returned '$WS_PATH'"
        ORIG=""
        exit 1
    fi
fi

info "steps:  ${STEPS[*]}$([ $RESTORE -eq 1 ] && echo " (then restore $(settings_type "$ORIG"))")"
info "output: $OUT_DIR"

cp -a "$LOG" "$OUT_DIR/omv-writecache.log.before" 2>/dev/null
snapshot "$OUT_DIR/state.before.txt"
BASELINE_ZRAM_LEAKS="$(leaked_zram | tr '\n' ' ')"
[ -n "$BASELINE_ZRAM_LEAKS" ] && info "already-leaked zram devices before start (ignored): $BASELINE_ZRAM_LEAKS"

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------
n=0
for target in "${STEPS[@]}"; do
    n=$((n + 1))
    run_step "$n" "$target" "$target"
done

if [ $RESTORE -eq 1 ]; then
    n=$((n + 1))
    orig_type="$(settings_type "$ORIG")"
    if [ "$orig_type" = path ]; then
        SF_UUID="$(jq -r '.sharedfolderref' <<<"$ORIG")"
        WS_PATH="$(get_sf_path "$SF_UUID")"
    fi
    STALE_CHECK=0
    # Put back every original setting, not just the backing.
    run_step "$n" "$orig_type" "restore-$orig_type" "$(jq -c 'del(.status)' <<<"$ORIG")"
    RESTORED=1
fi

# ---------------------------------------------------------------------------
# Whole run: nothing written during the run may have been rolled back
# ---------------------------------------------------------------------------
section "Whole run"

missing=0; last_line=0; order_ok=1
for m in "${MARKERS[@]}"; do
    line="$(grep -nF -- "$m" "$LOG" | tail -1 | cut -d: -f1)"
    if [ -z "$line" ]; then
        missing=$((missing + 1))
    else
        [ "$line" -lt "$last_line" ] && order_ok=0
        last_line="$line"
    fi
done
if [ $missing -eq 0 ]; then
    _pass "all ${#MARKERS[@]} step markers still in $LOG"
else
    _fail "all step markers still in $LOG" "$missing of ${#MARKERS[@]} missing: log rolled back"
fi
if [ $order_ok -eq 1 ]; then
    _pass "step markers in order"
else
    _fail "step markers in order" "markers out of order in $LOG"
fi

missing=0
for m in "${MARKERS[@]}"; do
    grep -qxF -- "$m" "$SENTINEL" 2>/dev/null || missing=$((missing + 1))
done
if [ $missing -eq 0 ]; then
    _pass "sentinel still has all ${#MARKERS[@]} lines"
else
    _fail "sentinel still has all lines" "$missing of ${#MARKERS[@]} lost from $SENTINEL"
fi

# Timestamps must never jump backwards in the log since the run started.
first="$(grep -nF -- "${MARKERS[0]}" "$LOG" | head -1 | cut -d: -f1)"
if [ -n "$first" ]; then
    back="$(tail -n +"$first" "$LOG" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} ' \
        | awk '{k=$1" "$2} prev != "" && k < prev {print prev " -> " k} {prev=k}')"
    if [ -z "$back" ]; then
        _pass "no backwards timestamp jumps in $LOG since the run started"
    else
        _fail "no backwards timestamp jumps in $LOG" "$(head -3 <<<"$back" | tr '\n' ';')"
    fi
else
    _fail "no backwards timestamp jumps in $LOG" "first step marker missing"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "" >&2
echo -e "${BOLD}Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${YELLOW}${WARN} warnings${NC}, ${YELLOW}${SKIP} skipped${NC}" >&2
if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
    echo -e "${RED}Failed tests:${NC}" >&2
    for t in "${FAILED_TESTS[@]}"; do
        echo -e "  - $t" >&2
    done
    exit 1
fi
exit 0
