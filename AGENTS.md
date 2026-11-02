# Working on Toolbox

This Mac mini is the production server. Toolbox runs the applications, databases,
Cloudflare Tunnel, backups, and other host services. A scheduled macOS LaunchAgent
invokes the heartbeat from `/Users/philip/code/toolbox` every minute.

Postcard and its PostgreSQL database are the critical application services on this
Mac. Bully Pulpit is also critical, but runs on Vercel; preserve its local
checkouts and development work without treating them as Mac-hosted production.
Ghost, Booklet, Junk Drawer, and Plausible (including its dedicated PostgreSQL and
ClickHouse databases) are retired. Do not recreate their services or data, or
Ghost backup automation, during maintenance. Existing domain redirects remain
intentional. Preserve remote backup history unless the user authorizes removal.

Cloudflare manages this tunnel's active ingress remotely. The remote configuration
overrides `config.yml` and includes additional routes. For an authorized route
change, fetch the current remote configuration, preserve unrelated settings,
apply only the reviewed change, and verify the public response. Keep the local
reference consistent, but never replace the remote configuration wholesale with
the local file. Never print tunnel credentials, environment values, or the full
LaunchAgent state, which can contain secrets.

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
ruby -Itest -e 'Dir["test/**/*_test.rb"].sort.each { |file| require_relative file }'
zsh -n heartbeat.sh
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
