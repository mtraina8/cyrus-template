#!/usr/bin/env bash
# Read-only health check for a Cyrus install: pm2 process status, Tailscale
# backend + funnel config, local/public /status connectivity, and Linear
# token validity. Prints OK/FAIL/WARN per check plus a pass/fail summary.
#
# Usage: cyrus-health-check.sh
# Exit code: 0 if every check passed, 1 if any FAILed (WARNs don't affect it).
#
# Requires: cyrus-env.sh in the same directory (see cyrus-env.sh.template),
# pm2, tailscale, python3, curl, and the cyrus CLI on PATH.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cyrus-env.sh
source "$SCRIPT_DIR/cyrus-env.sh"

PASS=0
FAIL=0

green() { printf "\033[32m%s\033[0m\n" "$1"; }
red()   { printf "\033[31m%s\033[0m\n" "$1"; }
yellow() { printf "\033[33m%s\033[0m\n" "$1"; }

ok()   { green "  OK   $1"; PASS=$((PASS+1)); }
bad()  { red   "  FAIL $1"; FAIL=$((FAIL+1)); }
warn() { yellow "  WARN $1"; }

section() { printf "\n\033[1m%s\033[0m\n" "$1"; }

# ---- pm2 ----
section "pm2"

if ! command -v pm2 >/dev/null 2>&1; then
  bad "pm2 not found on PATH"
else
  PM2_JSON=$(pm2 jlist 2>/dev/null)
  PROC=$(printf '%s' "$PM2_JSON" | python3 -c "
import json, sys
try:
    procs = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for p in procs:
    if p.get('name') == '$PM2_NAME':
        print(json.dumps({
            'status': p['pm2_env'].get('status'),
            'restarts': p['pm2_env'].get('restart_time'),
            'uptime_ms': p['pm2_env'].get('pm_uptime'),
            'pid': p.get('pid'),
        }))
        break
" 2>/dev/null)

  if [ -z "$PROC" ]; then
    bad "process '$PM2_NAME' not found in pm2"
  else
    STATUS=$(printf '%s' "$PROC" | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])")
    RESTARTS=$(printf '%s' "$PROC" | python3 -c "import json,sys; print(json.load(sys.stdin)['restarts'])")
    PID=$(printf '%s' "$PROC" | python3 -c "import json,sys; print(json.load(sys.stdin)['pid'])")

    if [ "$STATUS" = "online" ]; then
      ok "process online (pid $PID)"
    else
      bad "process status is '$STATUS' (expected online)"
    fi

    if [ "$RESTARTS" -gt 5 ] 2>/dev/null; then
      warn "restart count is $RESTARTS — check for crash-looping"
    else
      ok "restart count is $RESTARTS"
    fi
  fi
fi

# ---- tailscale ----
section "tailscale"

if ! command -v tailscale >/dev/null 2>&1; then
  bad "tailscale CLI not found on PATH"
else
  BACKEND_STATE=$(tailscale status --json 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('BackendState',''))" 2>/dev/null)
  if [ "$BACKEND_STATE" = "Running" ]; then
    ok "tailscale backend state: Running"
  else
    bad "tailscale backend state: '$BACKEND_STATE' (expected Running)"
  fi

  SERVE_OUT=$(tailscale serve status 2>/dev/null)
  if printf '%s' "$SERVE_OUT" | grep -q "$FUNNEL_URL"; then
    ok "funnel configured for $FUNNEL_URL"
  else
    bad "funnel not found for $FUNNEL_URL"
  fi

  if printf '%s' "$SERVE_OUT" | grep -q "127.0.0.1:$LOCAL_PORT"; then
    ok "funnel proxies to local port $LOCAL_PORT"
  else
    bad "funnel does not proxy to 127.0.0.1:$LOCAL_PORT"
  fi
fi

# ---- connectivity ----
section "connectivity"

LOCAL_BODY=$(curl -s -m 5 "http://127.0.0.1:$LOCAL_PORT/status" 2>/dev/null)
if [ -n "$LOCAL_BODY" ]; then
  ok "local /status responding: $LOCAL_BODY"
else
  bad "local port $LOCAL_PORT /status not responding"
fi

FUNNEL_BODY=$(curl -s -m 8 "$FUNNEL_URL/status" 2>/dev/null)
if [ -n "$FUNNEL_BODY" ]; then
  ok "funnel /status responding: $FUNNEL_BODY"
else
  bad "funnel URL /status not responding"
fi

# ---- linear auth ----
section "linear auth"

if ! command -v cyrus >/dev/null 2>&1; then
  bad "cyrus CLI not found on PATH"
else
  TOKEN_OUT=$(timeout 20 cyrus check-tokens --cyrus-home "$CYRUS_HOME" 2>&1)
  WORKSPACE_LINES=$(printf '%s' "$TOKEN_OUT" | grep -E "^Workspace .*:" || true)
  if [ -z "$WORKSPACE_LINES" ]; then
    warn "could not determine Linear token status (no output from check-tokens)"
  else
    while IFS= read -r line; do
      WS_NAME=$(printf '%s' "$line" | sed -E 's/^Workspace ([^:]+):.*/\1/')
      if printf '%s' "$line" | grep -q "✅"; then
        ok "Linear token valid for workspace $WS_NAME"
      else
        bad "Linear token invalid for workspace $WS_NAME — run: cyrus refresh-token --cyrus-home $CYRUS_HOME"
      fi
    done <<< "$WORKSPACE_LINES"
  fi
fi

# ---- summary ----
section "summary"
echo "  $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
