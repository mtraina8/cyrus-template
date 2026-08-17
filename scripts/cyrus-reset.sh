#!/usr/bin/env bash
# Full local restart of the Cyrus stack: pm2 process, orphaned agent processes,
# stale session state, and the Tailscale funnel. Does NOT touch OAuth tokens,
# .env, config.json, worktrees, or logs.
#
# Order: stop pm2 -> kill orphaned agents -> free port -> clean stale sessions
#        -> cycle funnel -> start pm2 -> wait for /status -> health check.
#
# Usage: cyrus-reset.sh
# Reach for this instead of `pm2 restart` when sessions look stuck, the
# funnel needs re-bringing-up, or a worktree process is holding the local
# port open. In-progress sessions in the state file get marked "complete"
# (a timestamped backup is written first) rather than left dangling.
#
# Requires: cyrus-env.sh in the same directory (see cyrus-env.sh.template),
# pm2, tailscale, python3, lsof, curl. Runs cyrus-health-check.sh at the end
# if it's present.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cyrus-env.sh
source "$SCRIPT_DIR/cyrus-env.sh"
STATE_FILE="$CYRUS_HOME/state/edge-worker-state.json"
BACKUP_DIR="$CYRUS_HOME/state/backups"
# Always start via the sanitizing wrapper — it strips XPC_FLAGS and leaked
# Claude harness vars that break Claude CLI networking in spawned sessions
# (see README.md TROUBLESHOOTING). Never point this at the cyrus
# binary/shim directly.
CYRUS_BIN="$CYRUS_HOME/scripts/cyrus-start.sh"
TS=$(date -u +%Y%m%dT%H%M%SZ)

step() { printf "\n\033[1m==> %s\033[0m\n" "$1"; }
note() { printf "    %s\n" "$1"; }
warn() { printf "    \033[33mWARN: %s\033[0m\n" "$1"; }

# ---------------------------------------------------------------- shut down
step "Stopping pm2 process '$PM2_NAME'"
if pm2 describe "$PM2_NAME" >/dev/null 2>&1; then
  pm2 stop "$PM2_NAME" >/dev/null && note "stopped"
else
  note "not registered with pm2, nothing to stop"
fi

step "Killing orphaned agent processes (cwd under $CYRUS_HOME/worktrees)"
# Never kill ourselves or our ancestors (this script may run inside a Claude session).
PROTECTED=" $$ "
p=$$
while [ "$p" -gt 1 ] 2>/dev/null; do
  p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ') || break
  [ -n "$p" ] && PROTECTED="$PROTECTED$p "
done

find_orphans() {
  lsof -a -d cwd -u "$(id -u)" -Fpn 2>/dev/null | awk -v wt="$CYRUS_HOME/worktrees" '
    /^p/ { pid = substr($0, 2) }
    /^n/ { if (index(substr($0, 2), wt) == 1) print pid }'
}

ORPHANS=""
for pid in $(find_orphans); do
  case "$PROTECTED" in *" $pid "*) continue ;; esac
  ORPHANS="$ORPHANS $pid"
done

if [ -n "${ORPHANS// /}" ]; then
  for pid in $ORPHANS; do
    note "TERM $pid: $(ps -o command= -p "$pid" 2>/dev/null | cut -c1-100)"
    kill "$pid" 2>/dev/null
  done
  sleep 3
  for pid in $ORPHANS; do
    if kill -0 "$pid" 2>/dev/null; then
      warn "$pid survived SIGTERM, sending SIGKILL"
      kill -9 "$pid" 2>/dev/null
    fi
  done
else
  note "none found"
fi

step "Freeing port $LOCAL_PORT"
LEFTOVER=$(lsof -ti "tcp:$LOCAL_PORT" -sTCP:LISTEN 2>/dev/null || true)
if [ -n "$LEFTOVER" ]; then
  for pid in $LEFTOVER; do
    warn "killing leftover listener pid $pid"
    kill "$pid" 2>/dev/null
  done
  sleep 2
  for pid in $LEFTOVER; do
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
  done
else
  note "port already free"
fi

# ----------------------------------------------------------- state cleanup
step "Cleaning up in-progress sessions in state file"
if [ -f "$STATE_FILE" ] && [ -s "$STATE_FILE" ]; then
  mkdir -p "$BACKUP_DIR"
  cp "$STATE_FILE" "$BACKUP_DIR/edge-worker-state.$TS.json"
  note "backed up to $BACKUP_DIR/edge-worker-state.$TS.json"
  python3 - "$STATE_FILE" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
sessions = data.get("state", {}).get("agentSessions", {}) or {}
flipped = 0
for sid, s in sessions.items():
    if isinstance(s, dict) and s.get("status") not in ("complete", "error"):
        ident = (s.get("issueContext") or {}).get("issueIdentifier", "?")
        print(f"    marking {s.get('status')} session {sid[:8]} ({ident}) as complete")
        s["status"] = "complete"
        flipped += 1
if flipped:
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
    print(f"    {flipped} session(s) cleaned up")
else:
    print("    no in-progress sessions found")
PY
else
  note "no state file, nothing to clean"
fi

# ------------------------------------------------------------- tailscale
step "Cycling Tailscale funnel ($FUNNEL_PORT -> $LOCAL_PORT)"
BACKEND_STATE=$(tailscale status --json 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('BackendState',''))" 2>/dev/null || true)
if [ "$BACKEND_STATE" != "Running" ]; then
  warn "tailscale backend state is '$BACKEND_STATE', attempting 'tailscale up'"
  tailscale up || warn "tailscale up failed — funnel will not work until tailscaled is running"
fi
tailscale funnel --https="$FUNNEL_PORT" off 2>/dev/null || true
tailscale funnel --bg --https="$FUNNEL_PORT" "$LOCAL_PORT" >/dev/null
if tailscale serve status 2>/dev/null | grep -q "127.0.0.1:$LOCAL_PORT"; then
  note "funnel up: $FUNNEL_URL -> 127.0.0.1:$LOCAL_PORT"
else
  warn "funnel did not come back up — check 'tailscale funnel status'"
fi

# -------------------------------------------------------------- spin up
step "Starting pm2 process '$PM2_NAME'"
if pm2 describe "$PM2_NAME" >/dev/null 2>&1; then
  pm2 start "$PM2_NAME" >/dev/null
else
  note "not registered, starting fresh from $CYRUS_BIN"
  pm2 start "$CYRUS_BIN" --name "$PM2_NAME" --interpreter bash >/dev/null
fi
pm2 save >/dev/null 2>&1 || true

step "Waiting for local /status (up to 30s)"
UP=""
for _ in $(seq 1 30); do
  BODY=$(curl -s -m 2 "http://127.0.0.1:$LOCAL_PORT/status" 2>/dev/null)
  if [ -n "$BODY" ]; then
    note "local /status: $BODY"
    UP=1
    break
  fi
  sleep 1
done
if [ -z "$UP" ]; then
  warn "local /status not responding after 30s — check: pm2 logs $PM2_NAME --lines 50 --nostream"
fi

step "Checking funnel /status"
FUNNEL_BODY=$(curl -s -m 8 "$FUNNEL_URL/status" 2>/dev/null)
if [ -n "$FUNNEL_BODY" ]; then
  note "funnel /status: $FUNNEL_BODY"
else
  warn "funnel /status not responding (webhooks from Linear will not arrive)"
fi

# ---------------------------------------------------------- health check
HEALTH="$CYRUS_HOME/scripts/cyrus-health-check.sh"
if [ -x "$HEALTH" ]; then
  step "Running health check"
  "$HEALTH" || warn "health check reported failures (see above)"
else
  step "Done"
  pm2 list
fi
