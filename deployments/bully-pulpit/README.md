# Parallel Bully Pulpit hosting

This configuration prepares a production-mode copy of Bully Pulpit at
`https://bully-pulpit.contraption.co`, with live provider credentials. Initial
launch is pending a verified production Neon copy and the release checks below.
Vercel continues serving `www.philipithomas.com`. This is an explicit release,
independent of Toolbox's heartbeat.

The Compose project contains `bully-pulpit`, `bully-pulpit-postgres`, and
`bully-pulpit-proxy`. Only the proxy publishes a port, on `127.0.0.1:4244`.
Its network and PostgreSQL data are separate from Postcard and the shared
Toolbox database. Docker restart policies restore the stack after Docker starts.
The dashboard's `COMPOSE_APPLICATIONS` inventory observes it without releasing it.

## Credentials and data

Runtime files live under `/Users/philip/data/bully-pulpit-local` (mode0700), with
mode0600 secrets outside every checkout and Docker build context. The canonical
secret item is `Bully Pulpit Toolbox` in Toolbox's existing 1Password vault.
`ENV` contains application variables and `POSTGRES_ENV` the database administrator
environment. Keep real production keys; never substitute Stripe preview keys.
Run `python3 deployments/bully-pulpit/secrets.py` to render these files using
Toolbox's existing read-only service account. Creating/editing the vault item
requires a human save or a separate provisioning account with write access;
the running heartbeat account should remain read-only.
The session, Bell identity, cron and local database keys are separate identities.
Never print `docker inspect`, resolved Compose config, raw provider errors, or
environment contents. Decrypted secret files must not become PR/CI artifacts.

The application database is `bully_pulpit_toolbox`; its role is `bully_pulpit`.
Workflow uses a fresh `bully_pulpit_workflow_toolbox` database and `bully_workflow`
role. Vercel Workflow state is not exported with the Neon business database.
Copy Neon with the dedicated database tool, which rejects nonempty restore
targets, compares table counts from one source snapshot, and preserves a private
dump. Do not discard live local changes by rerunning the initial copy.

## Release

Run these commands from a separate, clean Toolbox checkout under
`/Users/philip/development/`. The initial bootstrap starts PostgreSQL before the
database commands; it does not require the application or proxy to be running.

1. Test and push both feature branches; keep full PRs open and verify CI. Select
   the full pushed application commit for this release.
2. Provision the private runtime directory and render its local credentials:

   ```sh
   python3 deployments/bully-pulpit/secrets.py
   ```

3. Build the selected application commit:

   ```sh
   BULLY_APP_COMMIT='<full-pushed-app-sha>'
   python3 deployments/bully-pulpit/deploy.py --commit "$BULLY_APP_COMMIT" --build-only
   ```

   Continue only when the build succeeds. This command verifies that the
   Toolbox checkout is clean, its remote is the expected repository, and its
   HEAD matches the pushed branch. It also verifies the application's remote
   SHA and builds a separate immutable source checkout. The application branch
   defaults to `feat/toolbox-self-hosting`; pass `--branch` to both release
   commands when selecting another branch.
4. From that same verified Toolbox checkout, start only the dedicated database
   with the exact image ID produced by the successful build. Keep the checkout
   and selected commit unchanged between these commands:

   ```sh
   BULLY_BOOTSTRAP_IMAGE="$(docker image inspect --format '{{.Id}}' "bully-pulpit-local:$BULLY_APP_COMMIT")"
   BULLY_RUNTIME_DIR=/Users/philip/data/bully-pulpit-local \
     BULLY_IMAGE="$BULLY_BOOTSTRAP_IMAGE" \
     docker compose -f deployments/bully-pulpit/compose.yml up -d --wait --no-deps postgres
   ```

   The selected Compose file pins PostgreSQL 17 and its dedicated data directory.
   `--no-deps postgres` starts only this service. Keep an existing healthy
   dedicated database; do not recreate its data to repeat the bootstrap.
5. Initialize the dedicated roles/databases, then copy the production Neon
   database. Before `copy`, provision the explicit production connection URL as
   `secrets/source-database.json` under the runtime directory, containing
   `{"url":"<production-Neon-URL>"}` with mode0600. `secrets.py` renders the local
   runtime credentials; it does not provision this source credential. Obtain
   the source from the production secret, never a development database or an
   environment-file fallback, and keep its value out of shell history/output.

   ```sh
   python3 deployments/bully-pulpit/database.py init
   python3 deployments/bully-pulpit/database.py copy
   ```

   Continue only after `copy` reports `verified: true` and writes
   `/Users/philip/data/bully-pulpit-local/database-copy.json`. The copy refuses
   an occupied target and verifies every table count against the exported source
   snapshot. A missing source credential blocks this step and the release.
   After a verified initial copy, skip this copy step for subsequent releases.
6. Apply the same reviewed application commit:

   ```sh
   python3 deployments/bully-pulpit/deploy.py --commit "$BULLY_APP_COMMIT" --apply
   ```

   The command requires the verified copy marker, freezes the selected Compose
   and proxy configuration, backs up both local databases, applies migrations,
   bootstraps the pinned Workflow backend, and starts this Compose project.
7. Verify the real homepage, a photo, search, optimized images, admin rejection,
   missing bot proof rejection, and Workflow smoke/restart behavior at the local
   proxy using `Host: bully-pulpit.contraption.co`.
8. Use Cloudflare MCP to fetch the current remote tunnel configuration, preserve
   unrelated rules, and change only this hostname to `http://127.0.0.1:4244` with
   a preceding `^/\.well-known/workflow`403 rule. Keep `config.yml` consistent.
   Verify the public site and that Vercel/Postcard remain healthy.

`deploy.log` is private. `deployment.json` records the app SHA, infrastructure
SHA, image and frozen Compose path; `previous-deployment.json` preserves the
last release. For application rollback use that exact prior image and Compose
file with the same runtime directory. Do not delete volumes or restore an older
database merely because an image failed. Migrations must remain additive.

## Parallel boundaries

`APP_RUNTIME=toolbox`, `NODE_ENV=production`, `DEPLOYMENT_ROLE=parallel` and the
explicit `APP_URL` identify this instance. No local scheduler is installed.
Bulk newsletters, retries, morning reports, subscriber backups sent by email,
catalog sync, click-to-call and incoming phone/provider callbacks are refused
before claims or external effects. This prevents an old copied audience from
receiving messages after a primary-site opt-out. OTP, test sends, direct admin
SMS, Checkout and billing are real operations. Changes to the copied application
database do not replicate back to Neon.

The worker calls `http://127.0.0.1:3000` inside its container. The public proxy
denies the normalized Workflow prefix; Cloudflare's regex alone does not handle
all encoded or dot-segment forms. No request header bypasses this restriction.
Only one deployed app version owns the workflow database. The Postgres adapter
does not automatically route old runs to compatible older code. Preserve
in-flight compatibility or drain before upgrading. A durable sleep recovery
probe is available; it sends no mail/SMS. An interrupted active step may wait for
its ownership lease, so a sleep recovery test does not promise instant recovery
of every provider call.

## Vercel dependency audit

| Capability | Toolbox implementation |
| --- | --- |
| Next.js hosting and image optimization | Locked Docker image and `next start` |
| Neon business database | Consistent copy into dedicated local PostgreSQL |
| Workflow jobs | Existing pinned SDK with pinned Postgres world |
| BotID | Production Cloudflare Turnstile, hostname/action verification |
| Vercel Firewall rate limits | Atomic PostgreSQL counters; unavailable checks fail closed |
| Analytics and Speed Insights | Disabled on Toolbox |
| Vercel Cron | Remains primary on Vercel; local calls paused |
| OIDC credentials | Explicit production API credentials from 1Password |
| Private photo Blob and AI Gateway | Intentionally retained external services |
| Google sign-in | Enable only after authorizing the new OAuth origin; OTP works independently |

The parallel hostname is public and has no Cloudflare Access application.
Subscriber/admin routes still enforce application authorization. Every response
has a noindex header. The production Turnstile widget is restricted to this
hostname; no zone-wide security settings are changed.

## Checks

Run the normal Toolbox unit tests plus
`python3 -m unittest discover -s deployments/bully-pulpit -p 'test_*.py'`.
The proxy fixture is opt-in (`python3 deployments/bully-pulpit/test_proxy.py`):
it uses disposable containers, an ephemeral loopback port and no credentials.
It never joins production networks or mounts production data.
