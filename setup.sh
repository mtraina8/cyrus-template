#!/usr/bin/env bash
# Cyrus template setup wizard.
#
# Turns this repo into a personal Cyrus install at $CYRUS_HOME (default
# ~/.cyrus): templates config.json/.env/ops-scripts with your values, then
# prints the exact commands for everything else (Linear OAuth app, GitHub
# App, pm2, Tailscale) since those touch a browser or shared state and
# shouldn't run unattended.
#
# If you have Claude Code available, the faster path for the browser/OAuth
# steps is to run `claude` and ask it to run the cyrus-setup skill against
# your CYRUS_HOME — it automates the Linear/GitHub integration flow that
# this script can only hand you instructions for. Run this script first
# regardless: it's what seeds CYRUS_HOME with this template's ops scripts,
# model policy, and defaults.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

bold()  { printf "\033[1m%s\033[0m\n" "$1"; }
info()  { printf "  %s\n" "$1"; }
ok()    { printf "  \033[32m✓ %s\033[0m\n" "$1"; }
warn()  { printf "  \033[33m! %s\033[0m\n" "$1"; }
err()   { printf "  \033[31m✗ %s\033[0m\n" "$1"; }
step()  { printf "\n\033[1m== %s ==\033[0m\n" "$1"; }

ask() {
  # ask <prompt> <default> -> echoes the answer
  local prompt="$1" default="$2" answer
  read -rp "  $prompt [$default]: " answer
  echo "${answer:-$default}"
}

confirm() {
  local prompt="$1" answer
  read -rp "  $prompt [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

bold "Cyrus Template Setup"
info "This bootstraps a Cyrus install from $(basename "$REPO_DIR") — a Linear +"
info "Claude Code personal agent that runs in the background on your machine."
info "It writes files under a new CYRUS_HOME, but makes no changes outside it"
info "(no pm2 registration, no Tailscale changes, no OAuth calls)."

# ------------------------------------------------------------------ step 1
step "1/4 — Prerequisites"

MISSING=()
command -v node    >/dev/null 2>&1 && ok "node ($(node --version))"    || { err "node not found";      MISSING+=("node (https://nodejs.org)"); }
command -v cyrus    >/dev/null 2>&1 && ok "cyrus-ai ($(cyrus --version 2>/dev/null))" || { err "cyrus-ai not found"; MISSING+=("cyrus-ai — npm install -g cyrus-ai"); }
command -v pm2      >/dev/null 2>&1 && ok "pm2"      || { err "pm2 not found";        MISSING+=("pm2 — npm install -g pm2"); }
command -v tailscale >/dev/null 2>&1 && ok "tailscale" || { err "tailscale not found"; MISSING+=("tailscale — https://tailscale.com/download"); }
if command -v gh >/dev/null 2>&1; then
  ok "gh (GitHub CLI)"
  gh auth status >/dev/null 2>&1 || warn "gh is installed but not logged in — run 'gh auth login' before creating PRs"
else
  err "gh not found"
  MISSING+=("gh (GitHub CLI) — required for PR creation, see https://cli.github.com")
fi

if command -v claude >/dev/null 2>&1; then ok "claude (Claude Code CLI)"; else warn "claude not found (optional — needed only for the guided cyrus-setup skill path)"; fi

if [ "${#MISSING[@]}" -gt 0 ]; then
  printf "\n"
  err "Missing required tools. Install them, then re-run this script:"
  for m in "${MISSING[@]}"; do info "  - $m"; done
  exit 1
fi

# ------------------------------------------------------------------ step 2
step "2/4 — Configuration"

DEFAULT_CYRUS_HOME="$HOME/.cyrus"
CYRUS_HOME="$(ask "Cyrus home directory" "$DEFAULT_CYRUS_HOME")"

USER_EMAIL="$(ask "Your email (for userAccessControl.allowedUsers)" "")"
while [ -z "$USER_EMAIL" ]; do
  warn "Email is required — Cyrus only acts on issues assigned by allowed users."
  USER_EMAIL="$(ask "Your email" "")"
done

DETECTED_HOSTNAME=""
if command -v tailscale >/dev/null 2>&1; then
  DETECTED_HOSTNAME="$(tailscale status --json 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('Self',{}).get('DNSName','').rstrip('.'))" 2>/dev/null || true)"
fi
if [ -n "$DETECTED_HOSTNAME" ]; then
  info "Detected Tailscale MagicDNS hostname: $DETECTED_HOSTNAME"
else
  warn "Could not auto-detect a Tailscale hostname (run 'tailscale up' first if this is empty)."
fi
TAILSCALE_HOSTNAME="$(ask "Tailscale MagicDNS hostname" "$DETECTED_HOSTNAME")"
while [ -z "$TAILSCALE_HOSTNAME" ]; do
  warn "This is required — it's how Linear reaches your machine's webhook endpoint."
  TAILSCALE_HOSTNAME="$(ask "Tailscale MagicDNS hostname" "")"
done

FUNNEL_PORT="$(ask "Tailscale Funnel HTTPS port" "8443")"
CYRUS_SERVER_PORT="$(ask "Local Cyrus server port" "3456")"
CYRUS_BIN_PATH="$(command -v cyrus)"
CYRUS_BASE_URL="https://${TAILSCALE_HOSTNAME}:${FUNNEL_PORT}"

step "3/4 — Review"
info "CYRUS_HOME:          $CYRUS_HOME"
info "Email:                $USER_EMAIL"
info "CYRUS_BASE_URL:       $CYRUS_BASE_URL"
info "Local server port:    $CYRUS_SERVER_PORT"
info "cyrus binary:         $CYRUS_BIN_PATH"
printf "\n"
confirm "Write these to $CYRUS_HOME?" || { info "Aborted, nothing written."; exit 0; }

# ------------------------------------------------------------------ step 3
render_template() {
  local src="$1" dst="$2"
  python3 - "$src" "$dst" "$CYRUS_HOME" "$USER_EMAIL" "$TAILSCALE_HOSTNAME" "$FUNNEL_PORT" "$CYRUS_SERVER_PORT" "$CYRUS_BIN_PATH" <<'PY'
import sys
src, dst, cyrus_home, user_email, ts_host, funnel_port, server_port, cyrus_bin = sys.argv[1:9]
with open(src) as f:
    content = f.read()
for token, value in {
    "{{CYRUS_HOME}}": cyrus_home,
    "{{USER_EMAIL}}": user_email,
    "{{TAILSCALE_HOSTNAME}}": ts_host,
    "{{FUNNEL_PORT}}": funnel_port,
    "{{CYRUS_SERVER_PORT}}": server_port,
    "{{CYRUS_BIN_PATH}}": cyrus_bin,
}.items():
    content = content.replace(token, value)
with open(dst, "w") as f:
    f.write(content)
PY
}

mkdir -p "$CYRUS_HOME"/{scripts,state,repos,worktrees,mcp-configs}

render_template "$REPO_DIR/scripts/cyrus-env.sh.template" "$CYRUS_HOME/scripts/cyrus-env.sh"
for script in cyrus-start.sh cyrus-health-check.sh cyrus-reset.sh cyrus-activity.sh; do
  cp "$REPO_DIR/scripts/$script" "$CYRUS_HOME/scripts/$script"
done
chmod +x "$CYRUS_HOME"/scripts/*.sh
ok "Ops scripts installed to $CYRUS_HOME/scripts"

if [ -d "$REPO_DIR/cyrus-skills-plugin" ]; then
  if [ -e "$CYRUS_HOME/cyrus-skills-plugin" ] && [ "$FORCE" -ne 1 ]; then
    warn "$CYRUS_HOME/cyrus-skills-plugin already exists — leaving it as-is (rerun with --force to overwrite)"
  else
    rm -rf "$CYRUS_HOME/cyrus-skills-plugin"
    cp -R "$REPO_DIR/cyrus-skills-plugin" "$CYRUS_HOME/cyrus-skills-plugin"
    ok "Deployed cyrus-skills-plugin (default agent-session skills) to $CYRUS_HOME"
  fi
fi

if [ -e "$CYRUS_HOME/config.json" ] && [ "$FORCE" -ne 1 ]; then
  warn "$CYRUS_HOME/config.json already exists — leaving it untouched (it may hold live Linear tokens)"
else
  render_template "$REPO_DIR/config.json" "$CYRUS_HOME/config.json"
  ok "Wrote $CYRUS_HOME/config.json"
fi

if [ -e "$CYRUS_HOME/.env" ] && [ "$FORCE" -ne 1 ]; then
  warn "$CYRUS_HOME/.env already exists — leaving it untouched (it may hold live secrets)"
else
  render_template "$REPO_DIR/.env-template" "$CYRUS_HOME/.env"
  ok "Wrote $CYRUS_HOME/.env"
fi

# ------------------------------------------------------------------ step 4
step "4/4 — Remaining steps"
cat <<EOF

CYRUS_HOME is ready at: $CYRUS_HOME

Everything below touches a browser, pm2, or Tailscale, so it's left for you
to run by hand. If Claude Code is installed, you can instead say:
  "run the cyrus-setup skill for CYRUS_HOME=$CYRUS_HOME"
and it will drive steps A-F interactively.

A) Bring up the Tailscale Funnel:
     tailscale funnel --bg --https=$FUNNEL_PORT $CYRUS_SERVER_PORT
     tailscale funnel status

B) Create a GitHub App (optional — basic PR creation already works via
   'gh', checked above; a GitHub App only adds a dedicated bot identity and
   auto-rebase/merge). github.com -> Settings -> Developer settings ->
   GitHub Apps -> New, install it on your org/repos, and download its
   private key.
     Save the private key to:  $CYRUS_HOME/github-app.pem
   Then fill in $CYRUS_HOME/.env:
     -> GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID
   Further optional — to also get @mention replies on PR comments, attach a
   webhook on the same App pointed at ${CYRUS_BASE_URL}/github-webhook, set
   CYRUS_HOST_EXTERNAL=true, and copy its signing secret into
   GITHUB_WEBHOOK_SECRET.

C) Create a Linear OAuth application (Linear -> Settings -> API -> OAuth
   Applications -> New), then fill in $CYRUS_HOME/.env:
     Redirect URI:  ${CYRUS_BASE_URL}/callback
     Scopes:        write, app:assignable, app:mentionable
     -> LINEAR_CLIENT_ID, LINEAR_CLIENT_SECRET
   Attach a webhook on that same application pointed at
   ${CYRUS_BASE_URL}/linear-webhook and copy its signing secret into
   LINEAR_WEBHOOK_SECRET.

D) Add Claude Code auth — fill in $CYRUS_HOME/.env:
     -> CLAUDE_CODE_OAUTH_TOKEN
   (see the cyrus-setup-claude-auth skill/docs for how to mint one)

E) Authenticate and add your first repository:
     cd $CYRUS_HOME && cyrus self-auth-linear
     cyrus self-add-repo <git-url>

F) Register with pm2 (always via the sanitizing wrapper — see README
   Gotchas for why):
     pm2 start $CYRUS_HOME/scripts/cyrus-start.sh --name cyrus --interpreter bash
     pm2 save

Then verify everything is wired up:
     $CYRUS_HOME/scripts/cyrus-health-check.sh

See this repo's README.md for full setup details and the operations cheat
sheet (logs, restarts, model selection, gotchas).
EOF
