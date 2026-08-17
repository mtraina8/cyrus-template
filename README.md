# Overview

This is a template to get a cyrus agent connected to linear as a personal agent.

Cyrus is just a wrapper around Claude code that runs on your own hardware. It runs in the background on your machine via pm2 and connects to Linear via a tailscale funnel


# How it's used

After initial setup, you can interact with linear issues in several different ways.
1. by assigning your agent to the ticket which will start a claude code session on your machine and create prs for the given ticket
2. Tagging your agent as a comment on an issue
3. in linear code review diff as a pairing agent


# Getting started

Assumes `CYRUS_HOME=~/.cyrus`, a Tailscale Funnel on port 8443, and Cyrus's
local server on port 3456 — the only things that can't be assumed are your
email and your Tailscale MagicDNS hostname (`tailscale status` shows it).

## Step 1: Bootstrap `~/.cyrus`

Two equivalent ways to do this — pick one.

### Automated

```bash
git clone <this-repo-url>
cd cyrus-template
./setup.sh
```

Checks prerequisites (`node`, `cyrus-ai`, `pm2`, `tailscale`, `gh`), asks for
your email and Tailscale hostname, and writes a personalized `config.json`,
`.env`, and the ops scripts (`cyrus-start.sh`, `cyrus-health-check.sh`,
`cyrus-reset.sh`, `cyrus-activity.sh`) into `~/.cyrus`. Safe to re-run —
it never overwrites an existing `config.json`/`.env` (they may hold live
tokens), so rerun it any time to pick up template updates to the ops
scripts.

### Manual

Skip this if you ran `setup.sh`.

```bash
npm install -g cyrus-ai pm2
mkdir -p ~/.cyrus/{scripts,state,repos,worktrees,mcp-configs}
cp scripts/*.sh ~/.cyrus/scripts/
cp scripts/cyrus-env.sh.template ~/.cyrus/scripts/cyrus-env.sh
chmod +x ~/.cyrus/scripts/*.sh
cp -R cyrus-skills-plugin ~/.cyrus/cyrus-skills-plugin
cp config.json ~/.cyrus/config.json
cp .env-template ~/.cyrus/.env

for f in ~/.cyrus/config.json ~/.cyrus/.env ~/.cyrus/scripts/cyrus-env.sh; do
  sed -i '' \
    -e "s|{{CYRUS_HOME}}|$HOME/.cyrus|g" \
    -e "s|{{FUNNEL_PORT}}|8443|g" \
    -e "s|{{CYRUS_SERVER_PORT}}|3456|g" \
    -e "s|{{CYRUS_BIN_PATH}}|$(command -v cyrus)|g" \
    "$f"
done
```

(`sed -i ''` is the macOS/BSD form — drop the `''` argument on Linux.)

Then hand-fill the two placeholders that can't be assumed: `{{USER_EMAIL}}`
in `config.json`, and `{{TAILSCALE_HOSTNAME}}` in `.env` and
`scripts/cyrus-env.sh`.

## Step 2: Finish setup

Same steps regardless of which bootstrap path you used above. If you have
Claude Code installed, you can instead run `claude` and ask it to run the
`cyrus-setup` skill against your `CYRUS_HOME` — it drives the OAuth/App/repo
parts of this interactively.

1. **Tailscale Funnel** — exposes your local server to the internet so
   Linear can deliver webhooks:
   ```bash
   tailscale funnel --bg --https=8443 3456
   tailscale funnel status
   ```
2. **GitHub App** (optional) — `gh` (installed + `gh auth login`, already
   checked in Step 1) is enough for basic PR creation. A GitHub App
   additionally gives PRs a dedicated bot identity and enables
   auto-rebase/merge. Guided flow: the `cyrus-setup-github` skill. Manually:
   - Create one at github.com → Settings → Developer settings → GitHub Apps
     → New, install it on your org/repos, and save its private key to
     `~/.cyrus/github-app.pem`.
   - Add `GITHUB_APP_ID` and `GITHUB_APP_INSTALLATION_ID` to `~/.cyrus/.env`.
     All three (App ID, Installation ID, `.pem` file) are required together.
   - Further optional — for `@mention` replies on PR comments, attach a
     webhook on the same App pointed at
     `https://<tailscale-hostname>:8443/github-webhook`, set
     `CYRUS_HOST_EXTERNAL=true`, and copy its signing secret into
     `GITHUB_WEBHOOK_SECRET`.
3. **Linear OAuth application** — Linear → Settings → API → OAuth
   Applications → New (name it anything except "cyrus"):
   - Redirect URI: `https://<tailscale-hostname>:8443/callback`
   - Scopes: `write, app:assignable, app:mentionable`
   - Copy the client ID/secret into `~/.cyrus/.env` as `LINEAR_CLIENT_ID` /
     `LINEAR_CLIENT_SECRET`.
   - Attach a webhook on the same application pointed at
     `https://<tailscale-hostname>:8443/linear-webhook`, and copy its
     signing secret into `LINEAR_WEBHOOK_SECRET`.
4. **Claude Code auth** — fill in `CLAUDE_CODE_OAUTH_TOKEN` in
   `~/.cyrus/.env` (see the `cyrus-setup-claude-auth` skill/docs for how to
   mint one).
5. **Authenticate with Linear and add a repository:**
   ```bash
   cd ~/.cyrus && cyrus self-auth-linear
   cyrus self-add-repo <git-url>
   ```
   `self-auth-linear` opens a browser to complete the OAuth flow and writes
   the resulting token into `config.json`. `self-add-repo` clones the repo
   and appends an entry to `config.json`'s `repositories` array (see
   [Customizing before first launch](#customizing-before-first-launch) for
   the fields it writes).
6. **Register with pm2** — always via the sanitizing wrapper (see
   [Gotchas](#gotchas) for why):
   ```bash
   pm2 start ~/.cyrus/scripts/cyrus-start.sh --name cyrus --interpreter bash
   pm2 save
   ```
7. **Verify:**
   ```bash
   ~/.cyrus/scripts/cyrus-health-check.sh
   ```

## Customizing before first launch

### Agent-session skills

Every Linear-triggered session runs as a Claude Code session with a plugin
of Skills available to it — instructions Claude loads when their
description matches what the session needs. `cyrus-skills-plugin/` in this
repo is that plugin, and ships five:

| Skill | Description |
| --- | --- |
| `investigate` | Research the codebase to answer a question — search, read, gather context, then answer directly in Linear-compatible markdown. |
| `debug` | Full bug-fix workflow: reproduce with a failing test, root-cause it, then make the minimal targeted fix. |
| `implementation` | Implement a requested change: production-ready code following existing patterns, tests run to verify it. |
| `verify-and-ship` | Post-implementation gate: validate acceptance criteria against the issue, run tests/lint/typecheck, update the changelog, commit, push, and open/update the PR (draft by default). |
| `summarize` | Format the final status update that gets streamed back into the Linear session — work completed, key details, status. |

Claude picks which of these to use per session based on the issue (a
question routes to `investigate`; a bug report to `debug`; a feature request
to `implementation` then `verify-and-ship` then `summarize`) — you don't
invoke them yourself.

Cyrus normally auto-deploys its own default versions of these skills to
`~/.cyrus/cyrus-skills-plugin/` on first startup, but only if that directory
doesn't already exist. Because Step 1 above seeds `~/.cyrus` with this
repo's copy first, Cyrus's auto-deploy is skipped and your customized
versions are what sessions actually use from the start.

To customize: edit the `SKILL.md` files under `cyrus-skills-plugin/skills/*/`
— in this repo before Step 1, or directly in
`~/.cyrus/cyrus-skills-plugin/skills/*/` afterward (takes effect on the next
session, no restart needed). Each file is plain markdown with a
`name`/`description` frontmatter block; the description is what Claude
matches against to decide when to load it, so keep it specific. Add a new
directory with its own `SKILL.md` to introduce an entirely new skill.

### Repository routing and tools

`cyrus self-add-repo` generates a minimal entry in `config.json`'s
`repositories` array:

```json
{
  "id": "<uuid>",
  "name": "my-repo",
  "repositoryPath": "/abs/path/to/repo",
  "baseBranch": "main",
  "workspaceBaseDir": "/abs/path/to/worktrees",
  "linearWorkspaceId": "<linear-org-id>",
  "isActive": true,
  "routingLabels": ["my-repo"]
}
```

Hand-edit that entry afterward to add overrides — `routingLabels` (which
Linear issue labels route to this repo), `allowedTools`/`disallowedTools`
(Claude Code tool permissions for sessions in this repo), and `model`
(per-repo model override — see [Model selection](#model-selection)).

### Custom directions for all sessions

Optional: point `promptTemplatePath` on a repository entry in `config.json`
at a copy of the package's `standard-issue-assigned-user-prompt.md` with a
`<custom_directions>` section appended (mirrors `~/.claude/CLAUDE.md`), to
give every Linear-triggered session the same standing instructions (repo
conventions, PR etiquette, when to ask before proceeding).

```bash
cp "$(npm root -g)/cyrus-ai/node_modules/cyrus-edge-worker/dist/prompts/standard-issue-assigned-user-prompt.md" \
  ~/.cyrus/issue-prompt-template.md
# then append a <custom_directions>...</custom_directions> section
```

> **Note:** it must keep the `{{...}}` placeholders or sessions lose all issue context.

After upgrading `cyrus-ai`, diff your copy against the shipped template to pick up changes:

```bash
diff ~/.cyrus/issue-prompt-template.md \
  "$(npm root -g)/cyrus-ai/node_modules/cyrus-edge-worker/dist/prompts/standard-issue-assigned-user-prompt.md"
```


# Cyrus — Operations Cheat Sheet

Day-2 operations — for first-time setup see [Getting started](#getting-started) above.

- **Endpoint:** `https://<tailscale-hostname>:8443` (Tailscale Funnel -> `localhost:3456`)
- **Config:** `~/.cyrus/config.json`
- **Env/secrets:** `~/.cyrus/.env` (never cat/print this file — contains API keys/tokens)
- **Process manager:** pm2 (process name `cyrus`)

## Startup

Start Cyrus under pm2 (only needed if it isn't already running). ALWAYS start via the sanitizing wrapper — it strips env vars that break Claude sessions (see [Gotchas](#gotchas)). Do NOT start the cyrus binary/shim directly.

```bash
pm2 start ~/.cyrus/scripts/cyrus-start.sh --name cyrus --interpreter bash
pm2 save
```

Make sure the Tailscale Funnel is up (persists across reboots via `tailscaled`, but if it ever drops, bring it back with):

```bash
tailscale funnel --bg --https=8443 3456
tailscale funnel status
```

Enable pm2 auto-start on machine reboot (one-time, requires sudo):

```bash
pm2 startup
# ^ run the sudo command it prints, then:
pm2 save
```

## Teardown

```bash
# Stop Cyrus but keep it registered with pm2 (can restart later)
pm2 stop cyrus

# Fully remove Cyrus from pm2's process list
pm2 delete cyrus

# Turn off the public Tailscale Funnel (stops external webhook delivery)
tailscale funnel --https=8443 off
```

## View logs / status

```bash
# Tail live logs
pm2 logs cyrus

# Last N lines without following
pm2 logs cyrus --lines 50 --nostream

# Process status (pid, uptime, restarts, memory/cpu)
pm2 list
pm2 show cyrus

# App-level health check
curl -s http://localhost:3456/status
curl -s https://<tailscale-hostname>:8443/status   # via public tunnel

# Check Linear token status
cyrus check-tokens
```

Or use the bundled helper for a one-shot summary of sessions + recent errors:

```bash
~/.cyrus/scripts/cyrus-activity.sh          # summary
~/.cyrus/scripts/cyrus-activity.sh -f       # follow live logs
~/.cyrus/scripts/cyrus-activity.sh -n 100   # last 100 lines
```

## Restart / reload

```bash
pm2 restart cyrus     # restart process (brief downtime)
pm2 reload cyrus      # zero-downtime reload (if supported in fork mode)
```

For a full restart that also clears orphaned agent processes and stale
in-progress sessions (doesn't touch tokens, `.env`, `config.json`, worktrees,
or logs):

```bash
~/.cyrus/scripts/cyrus-reset.sh
```

## Common maintenance

```bash
# Add another repository
cyrus self-add-repo <git-url>              # uses default/only Linear workspace
cyrus self-add-repo <git-url> "<workspace>" # if multiple workspaces configured

# Re-authorize Linear (e.g. after revoking access)
cyrus self-auth-linear

# Refresh a specific Linear token
cyrus refresh-token

# See registered repositories (safe — no secrets in output)
grep -o '"name": "[^"]*"' ~/.cyrus/config.json
```

## Gotchas

Known pitfalls, roughly in the order you're likely to hit them.

**`cyrus self-add-repo` fails with "No Linear credentials found."**
It requires a workspace already authenticated via `cyrus self-auth-linear`
in `config.json`. Run `self-auth-linear` first — see
[Finish setup](#step-2-finish-setup), step 5.

**PR creation silently doesn't happen, or fails with an auth error.**
`gh` needs to be installed and authenticated (`gh auth login`) — that's the
one required piece. If you've also set up a GitHub App for bot-identity PRs,
`GITHUB_APP_ID` and `GITHUB_APP_INSTALLATION_ID` alone aren't enough — Cyrus
also needs the App's private key saved at `~/.cyrus/github-app.pem`. Missing
any one of those three silently disables it. `@mention` replies need the
further-optional webhook on top — see [Finish setup](#step-2-finish-setup),
step 2.

**`Cyrus failed to start` in Linear, or a 401 "Missing Authorization header" on `/linear-webhook`.**
Cyrus defaults to Linear "proxy mode" (expects a Bearer token from Cyrus's
hosted relay) unless `LINEAR_DIRECT_WEBHOOKS=true` is set. Self-hosted setups
using their own Linear OAuth app + `LINEAR_WEBHOOK_SECRET` need direct mode
(the shipped `.env-template` already sets this — check it wasn't removed):
```bash
grep '^LINEAR_DIRECT_WEBHOOKS=' ~/.cyrus/.env
# Should print: LINEAR_DIRECT_WEBHOOKS=true
# Confirm after restart via: pm2 logs cyrus --lines 40 --nostream | grep "Linear event transport"
# Should say "(direct mode)" not "(proxy mode)".
```

**Every session fails with `API Error: Unable to connect to API (ConnectionRefused)` or `(FailedToOpenSocket)` after 10 retries, while Linear webhooks still arrive fine.**
pm2 snapshots the shell env at `pm2 start` and replays it forever; a shell
opened from a macOS GUI terminal can carry `XPC_FLAGS` (e.g. `0x2`), which
breaks the Claude Code CLI's network stack in every subprocess Cyrus spawns.
Fix: always start Cyrus via `~/.cyrus/scripts/cyrus-start.sh` (unsets
`XPC_FLAGS` + leaked `CLAUDE_*` harness vars before exec) rather than the
`cyrus` binary directly. If it recurs, check the stored env with:
```bash
pm2 env 0 | grep -E "XPC_FLAGS|CLAUDECODE"
# and re-create the process: pm2 delete cyrus, then re-run the Startup command.
```

**pm2 shows the process crash-looping with a `SyntaxError: missing )` in `cyrus-error.log`.**
pm2 tried to run the pnpm shell shim as JS — always register the process
with `--interpreter bash` (see [Startup](#startup) above).

**Webhooks stop arriving with no other symptom.**
Confirm the Tailscale Funnel is still up — it doesn't always survive
`tailscale up`/network changes:
```bash
tailscale funnel status
```

**A model-selection label/tag on the issue doesn't seem to take effect.**
Priority order is issue label > issue description `[model=...]` tag >
per-repository `model` field > global `claudeDefaultModel` — a lower-priority
setting never overrides a higher one. See [Model selection](#model-selection).

**Deleted or corrupted `config.json` gets silently replaced.**
If `config.json` is missing when Cyrus starts, it recreates an empty one
(`{"repositories": []}`) rather than failing — which drops your
`allowedUsers`, `claudeDefaultModel`, and any repository config. Keep a
backup once you've customized it.

**Never `cat`/print `~/.cyrus/.env` or paste it into chat.** It holds live
API keys and OAuth tokens. Use targeted `grep` on non-secret keys instead:
```bash
grep -o '"name": "[^"]*"' ~/.cyrus/config.json
```

## Model selection

Default model is `opus` (`config.json`'s `claudeDefaultModel`) unless overridden.

```bash
grep claudeDefaultModel ~/.cyrus/config.json
```

Scopes, in priority order (highest wins):

1. Linear issue label: `opus` | `sonnet` | `haiku` | `fable` (per-issue, no restart)
2. Issue description tag: `[model=sonnet]` (per-issue, no restart)
3. Per-repository override: `model` field on a repo entry in `config.json`
4. Global default: `claudeDefaultModel` (or legacy `defaultModel`) in `config.json`
   - fallback model (used on retry) is `claudeDefaultFallbackModel`/`defaultFallbackModel`

`config.json` is watched and hot-reloads automatically — no pm2 restart needed after editing it. Changes apply to NEW sessions; an in-flight session keeps whatever model it already resolved at start.
