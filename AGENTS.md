# Working on Toolbox

This Mac mini is the production server. Toolbox runs the applications, databases,
Cloudflare Tunnel, backups, and other host services. A scheduled macOS LaunchAgent
invokes the heartbeat from `/Users/philip/code/toolbox` every minute.

Postcard and its PostgreSQL database are the critical application services on this
Mac. Bully Pulpit is also critical, but runs on Vercel; preserve its local
checkouts and development work without treating them as Mac-hosted production.
Ghost, Booklet, Junk Drawer, Plausible (including its dedicated PostgreSQL and
ClickHouse databases), Netdata, and the Signal proxy are retired. Do not recreate
their services or data, Ghost backup automation, or Netdata startup/log-rotation
jobs during maintenance. Signal proxy refers to the `signal` Docker container
using `bbernhard/signal-cli-rest-api` and its dedicated `data/signal` directory;
preserve personal Signal application data. Existing Netdata files and history are
preserved. Existing domain redirects remain intentional. Preserve remote backup
history unless the user authorizes removal.

Netdata's user LaunchAgent and log-rotation job are disabled. A stale root-owned
`homebrew.mxcl.netdata` launch registration remains with a nonexistent executable
containing `@@HOMEBREW_PREFIX@@`; disabling/unloading that registration needs
administrator access. Do not repair its executable or restart it.

Cloudflare manages this tunnel's active ingress remotely. The remote configuration
overrides `config.yml` and includes additional routes. For an authorized route
change, fetch the current remote configuration, preserve unrelated settings,
apply only the reviewed change, and verify the public response. Keep the local
reference consistent, but never replace the remote configuration wholesale with
the local file. Never print tunnel credentials, environment values, or the full
LaunchAgent state, which can contain secrets.

## Cloudflare MCP

- Cloudflare's official MCP server is configured in this Mac's Codex host as
  `cloudflare`, at `https://mcp.cloudflare.com/mcp`, with OAuth authorization.
  Prefer it for Cloudflare account, Access, DNS and tunnel operations. Use the
  existing authorization; do not print or copy its stored tokens.
- If tools have not appeared in an existing chat, the local Codex app-server
  supports `mcpServerStatus/list` and `mcpServer/tool/call`. An ephemeral thread
  can call those tools without starting a model turn. This is a client loading
  issue, not evidence that OAuth failed. Do not silently switch credentials.
- The desktop-bundled CLI is currently
  `/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex`. Verify its
  path before use; the older `codex` shim may be stale. For a required reconnect,
  `codex mcp login cloudflare --no-browser --scopes ...` prints a login link and
  accepts the final callback URL. Keep callback codes and tokens out of logs.
- Search the MCP API schema before requests, request only needed permissions,
  and treat authentication as access to tools, not blanket permission to change
  production. Back up remote configuration privately before authorized edits.
- `toolbox.contraption.co` uses the existing Toolbox UI Access application and
  the same “Philip secure” allow policy as the retired Junk Drawer. Preserve that
  policy; never add a bypass or service-token rule just to make testing easier.

## Read-only dashboard

- `web/server.rb` is a small native Ruby/WEBrick service on **127.0.0.1:4178**,
  managed by `co.contraption.toolbox.dashboard`. It runs on macOS so host memory,
  disk and uptime describe the Mac, rather than Docker's Linux VM.
- The heartbeat installs its locked gems into `.runtime/dashboard/gems`, keeps
  its LaunchAgent running, and restarts only this service when the revision
  changes. Dashboard failures are reported without skipping other app checks.
  Its LaunchAgent receives an explicit environment without deployment secrets.
- Cloudflare Access is the only authentication mechanism. The connector and
  Ruby origin both validate the application JWT. The origin checks the signature,
  algorithm, issuer, audience and expiry; it never trusts an email header alone.
  `/healthz` exposes only readiness and revision. All UI/API routes require Access.
- Keep the HTTP API GET/HEAD-only. Never add shell commands, Docker mutations,
  arbitrary paths, environment dumps, full container inspect output, or credential
  helpers to the web app. Collectors use fixed, bounded read-only commands.
- Logs are bounded and redacted, but redaction is best effort. Keep Access in
  front of them. Never cache metrics, logs or auth responses offline, or write
  raw request headers/tokens into web logs. Transient credential-helper containers
  must not expose their logs or appear as unconfigured application alerts.
- Show immediately free and reclaimable disk space separately. Docker.raw's
  allocated bytes are physical storage; its virtual capacity is not disk usage.
  Docker CPU can exceed 100%; network and block I/O values are lifetime counters.
- Deployment status comes from `.runtime/heartbeat-status.json`, written
  atomically by the heartbeat. Missing/stale evidence must not appear healthy.
- The first release has live readings only. DuckDB is a candidate if historical
  metrics are added later; do not add raw-log retention by default.
- For UI work, run `bundle install`, then `ruby web/server.rb --demo` in the
  development clone. This binds to **127.0.0.1:4179** and uses synthetic data only.
  There is no auth-bypass mode that reads the production host. Stop demo servers
  after testing. Match Bully Pulpit's typography, warm colors and square controls.
  Reuse the README's `assets/toolbox.svg` logo rather than inventing a wordmark.

## Use a separate checkout

- Treat `/Users/philip/code/toolbox` and application repositories referenced by
  production `config.rb` as deployment checkouts. Read-only inspection is fine.
  Do not edit files, switch branches, pull, stash, reset, clean, or run tests there
  as part of development.
- Use a separate clone under `/Users/philip/development/`. A separate development
  environment is not required for this project. Do not reconfigure Docker, create
  a VM, or move production services merely to develop Toolbox.
- When starting from `main`, first pull the latest `main` **in the development
  clone**, then create a feature branch. If the task opens in the production
  checkout, create or select the development clone before doing either operation.
- Keep production configuration, runtime state, secrets, and persistent data in
  their existing locations unless the user explicitly requests a rollout that
  changes them. Never copy production secrets into the development clone.

## Production boundaries

- Editing a separate clone is safe; executing its orchestration code against the
  host is a production operation. The default configuration still refers to the
  host's production repositories, data, Docker names, ports, and credentials.
- Do not run `toolbox.rb`, `heartbeat.sh`, the installation scripts, or backup
  scripts against real services to test a development change. Do not bypass
  production path/intent guards to target the real checkout during testing.
  Temporary fixture checkouts may explicitly configure their own test paths.
- Do not build images with production tags (for example `postcard`), restart or
  remove production containers, prune Docker resources, or alter production
  databases, volumes, tunnels, LaunchAgents, or secrets during development.
- Runtime integration checks must use temporary fixtures and mocked external
  commands. An actual production rollout requires an explicit user request.
- Production app builds must use a verified remote commit, not an editable
  development directory. Reject unexpected branches and local source changes;
  do not automatically discard them or switch a developer's branch.
- A refusal or failed deployment is not permission to relax a guard. Report the
  cause, preserve the running services, and prepare the necessary repair safely.
- A separate checkout prevents accidental file overlap; it does not revoke this
  account's access to production. Keep commands narrowly scoped to the task.

## Validation

Run the unit tests and shell syntax check from the development clone:

```sh
bundle install
ruby -Itest -e 'Dir["test/**/*_test.rb"].sort.each { |file| require_relative file }'
zsh -n heartbeat.sh
node --check web/public/app.js
node --check web/public/sw.js
git diff --check
```

Tests must use temporary repositories/directories and fake service commands, and
must not require production Docker, 1Password, network services, or credentials.
Keep new tests focused on the changed behavior and meaningful failure cases.

For an explicitly requested production rollout, preserve a recovery path and
verify the affected public application as well as its health endpoint. A healthy
container or successful health route does not prove the real application works.
Do not print secret values while collecting evidence.

## Pull requests

1. Open a full, non-draft PR for changes.
2. Poll until CI passes and address failures before completing the task.
3. After CI passes, poll the PR for an additional 10 minutes and address review
   comments. Reply in each addressed thread and resolve it when applicable.
   Stop polling early if the PR is merged or closed.
4. Keep a safety-hardening PR unmerged unless the user requests the merge or
   rollout. The production heartbeat follows `main`, so merging can change the
   live server automatically, including restarting the tunnel.
5. Report local validation, remote CI, and production verification separately.
   Do not describe an unmerged change as protection already installed on prod.
