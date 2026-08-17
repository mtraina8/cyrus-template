#!/usr/bin/env bash
# Read-only summary of Cyrus activity: agent session counts/status, log
# freshness, and recent ERROR/FATAL lines from the pm2 error log.
#
# Usage:
#   cyrus-activity.sh            summary: sessions, log freshness, recent errors/output
#   cyrus-activity.sh -f         follow live logs (pm2 logs cyrus)
#   cyrus-activity.sh -n <N>     dump last N log lines and exit
#
# Requires: cyrus-env.sh in the same directory (see cyrus-env.sh.template),
# pm2, python3.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cyrus-env.sh
source "$SCRIPT_DIR/cyrus-env.sh"

case "${1:-}" in
  -f|--follow)
    exec pm2 logs "$PM2_NAME"
    ;;
  -n)
    exec pm2 logs "$PM2_NAME" --lines "${2:-50}" --nostream
    ;;
esac

ERROR_LOOKBACK_MIN=60   # how far back to scan cyrus-error.log for fresh errors
RECENT_SESSIONS=5       # how many recently-updated sessions to list

green() { printf "\033[32m%s\033[0m\n" "$1"; }
red()   { printf "\033[31m%s\033[0m\n" "$1"; }
yellow() { printf "\033[33m%s\033[0m\n" "$1"; }

info() { printf "  %s\n" "$1"; }
warn() { yellow "  WARN $1"; }

section() { printf "\n\033[1m%s\033[0m\n" "$1"; }

# ---- agent sessions ----
section "agent sessions"

STATE_FILE="$CYRUS_HOME/state/edge-worker-state.json"
if [ ! -f "$STATE_FILE" ]; then
  warn "state file not found at $STATE_FILE"
else
  python3 - "$STATE_FILE" "$RECENT_SESSIONS" <<'PYEOF'
import json, sys, datetime

state_file, recent_n = sys.argv[1], int(sys.argv[2])
GREEN, RED, YELLOW, RESET = "\033[32m", "\033[31m", "\033[33m", "\033[0m"

try:
    with open(state_file) as f:
        data = json.load(f)
except Exception as e:
    print(f"{YELLOW}  WARN could not parse state file: {e}{RESET}")
    sys.exit(0)

sessions = list(data.get("state", {}).get("agentSessions", {}).values())
now = datetime.datetime.now(datetime.timezone.utc).timestamp()

def age(ms):
    if not ms:
        return "?"
    mins = int((now - ms / 1000) / 60)
    if mins < 120:
        return f"{mins}m ago"
    hours = mins // 60
    if hours < 48:
        return f"{hours}h ago"
    return f"{hours // 24}d ago"

counts = {}
for s in sessions:
    counts[s.get("status", "?")] = counts.get(s.get("status", "?"), 0) + 1
summary = ", ".join(f"{v} {k}" for k, v in sorted(counts.items()))
print(f"  {len(sessions)} total session(s): {summary}")

active = [s for s in sessions if s.get("status") == "active"]
if active:
    print(f"\n  active:")
    for s in sorted(active, key=lambda x: x.get("updatedAt") or 0, reverse=True):
        issue = s.get("issue") or {}
        title = (issue.get("title") or "")[:60]
        print(f"{GREEN}    {issue.get('identifier', '?'):8s}{RESET} {title}  (updated {age(s.get('updatedAt'))})")

errored = [s for s in sessions if s.get("status") == "error"]
if errored:
    print(f"\n  errored:")
    for s in sorted(errored, key=lambda x: x.get("updatedAt") or 0, reverse=True):
        issue = s.get("issue") or {}
        title = (issue.get("title") or "")[:60]
        print(f"{RED}    {issue.get('identifier', '?'):8s}{RESET} {title}  (updated {age(s.get('updatedAt'))})")

recent = sorted(sessions, key=lambda x: x.get("updatedAt") or 0, reverse=True)[:recent_n]
if recent:
    print(f"\n  most recently updated:")
    for s in recent:
        issue = s.get("issue") or {}
        title = (issue.get("title") or "")[:60]
        print(f"    {s.get('status', '?'):9s} {issue.get('identifier', '?'):8s} {title}  (updated {age(s.get('updatedAt'))})")
PYEOF
fi

# ---- logs ----
section "logs"

ERR_LOG="$HOME/.pm2/logs/${PM2_NAME}-error.log"
OUT_LOG="$HOME/.pm2/logs/${PM2_NAME}-out.log"

if [ -f "$OUT_LOG" ]; then
  LAST_OUT_LINE=$(tail -n 1 "$OUT_LOG" 2>/dev/null)
  LAST_TS=$(printf '%s' "$LAST_OUT_LINE" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}' || true)
  if [ -n "$LAST_TS" ]; then
    LAST_EPOCH=$(python3 -c "from datetime import datetime, timezone; print(int(datetime.fromisoformat('$LAST_TS').replace(tzinfo=timezone.utc).timestamp()))" 2>/dev/null)
    NOW_EPOCH=$(date -u +%s)
    if [ -n "$LAST_EPOCH" ]; then
      AGE_MIN=$(( (NOW_EPOCH - LAST_EPOCH) / 60 ))
      if [ "$AGE_MIN" -lt 1440 ]; then
        info "last out-log activity ${AGE_MIN}m ago ($LAST_TS)"
      else
        warn "last out-log activity is $((AGE_MIN/60))h ago ($LAST_TS) — no recent activity"
      fi
    else
      warn "could not parse last log timestamp"
    fi
  else
    warn "could not find a timestamp in last out-log line"
  fi
else
  warn "out log not found at $OUT_LOG"
fi

if [ -f "$ERR_LOG" ]; then
  CUTOFF_EPOCH=$(( $(date +%s) - ERROR_LOOKBACK_MIN * 60 ))
  RECENT_ERRORS=$(python3 -c "
import re, datetime, sys
cutoff = datetime.datetime.utcfromtimestamp($CUTOFF_EPOCH)
pat = re.compile(r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})')
hits = []
try:
    with open('$ERR_LOG') as f:
        for line in f:
            m = pat.match(line)
            if not m:
                continue
            try:
                ts = datetime.datetime.fromisoformat(m.group(1))
            except ValueError:
                continue
            if ts >= cutoff and ('ERROR' in line or 'FATAL' in line):
                hits.append(line.rstrip())
except FileNotFoundError:
    pass
print(len(hits))
for h in hits[-5:]:
    print(h)
" 2>/dev/null)
  RECENT_COUNT=$(printf '%s' "$RECENT_ERRORS" | head -n 1)
  if [ "${RECENT_COUNT:-0}" = "0" ]; then
    green "  no ERROR/FATAL lines in error log in last ${ERROR_LOOKBACK_MIN}m"
  else
    red "  $RECENT_COUNT ERROR/FATAL line(s) in last ${ERROR_LOOKBACK_MIN}m (showing last 5):"
    printf '%s\n' "$RECENT_ERRORS" | tail -n +2 | sed 's/^/    /'
  fi
else
  warn "error log not found at $ERR_LOG"
fi

if [ -f "$OUT_LOG" ]; then
  echo
  info "recent output (last 10 lines):"
  tail -n 10 "$OUT_LOG" | sed 's/^/    /'
fi

echo
info "follow live: $(basename "$0") -f   |   last N lines: $(basename "$0") -n 100"
echo
exit 0
