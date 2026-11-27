# Bully Pulpit production on Toolbox

Toolbox deploys the reviewed `main` branch to a dedicated checkout at
`/Users/philip/code/bully-pulpit-production`. The ordinary heartbeat verifies the
remote release, rejects dirty or unexpected branches, and builds an immutable
archive of that commit. `/Users/philip/code/bully-pulpit` remains a development
checkout. Production runtime files live under `/Users/philip/data/bully-pulpit`.
The old pilot runtime and its separate PostgreSQL container remain untouched.

The new Compose project contains `bully-pulpit-production`, a one-shot migration
container, `bully-pulpit-production-proxy`, and `bully-pulpit-production-scheduler`.
Only the proxy publishes a port, `127.0.0.1:4244`. The app joins `toolbox_network`
and connects to the existing `postgres` container. There is no new database
server. The proxy and scheduler share a separate application network. The proxy
serves `www.philipithomas.com`, preserves streaming, and denies normalized
Workflow internal paths. The Workflow worker calls loopback inside the app.
It also redirects `philipithomas.com` with HTTP 308 and `ilic.nyc` plus
`www.ilic.nyc` with HTTP 307 to the fixed `https://www.philipithomas.com` origin,
preserving each request's original escaped path and query string.

## Staging, credentials, and database copy

Merging this configuration cannot start the app. The heartbeat skips the service
until `enabled.json` exists in the production runtime directory. The release
helper also requires that marker to identify the verified cloud-copy archive.
`DEPLOYMENT_ROLE=parallel` keeps scheduled work and primary-only side effects
paused. A primary role additionally requires a matching `primary.json` marker.
Removing `enabled.json` pauses future deployments; it does not stop an already
running application or scheduler.

Use the `Bully Pulpit Production` item in the existing Toolbox vault. Its `ENV`
field is the canonical multiline runtime configuration. Toolbox's read-only
service account reads it; creating or editing the item requires an authenticated
provisioning account or a human save. Do not broaden heartbeat permissions.
`secrets.py` renders owner-only files, extracts the two database passwords into
private provisioning state, and rejects implicit database credential rotation.
The application never receives cluster administrator credentials.

Required deployment identity:

```dotenv
APP_ENV=production
APP_RUNTIME=toolbox
DEPLOYMENT_ROLE=parallel
APP_URL=https://www.philipithomas.com
DATABASE_URL=postgresql://bully_pulpit:<encoded-password>@postgres/bully_pulpit
WORKFLOW_POSTGRES_URL=postgresql://bully_workflow:<encoded-password>@postgres/bully_pulpit_workflow
WORKFLOW_TARGET_WORLD=@workflow/world-postgres
WORKFLOW_LOCAL_BASE_URL=http://127.0.0.1:3000
PHOTO_ARCHIVE_S3_BUCKET=<private-photo-bucket>
PHOTO_ARCHIVE_S3_REGION=us-east-2
```

Preserve existing JWT and Bell identity secrets to retain session identity. Include
Turnstile keys restricted to the production host, direct OpenAI credentials,
AWS/SES credentials, live Stripe credentials, Twilio and OAuth credentials, and
other settings documented by the application. No Vercel storage or AI Gateway
credentials are needed. Only explicit public values (Turnstile site key, Google
client ID, Stripe publishable key, phone number, canonical origin) enter Docker
build arguments. Runtime secrets remain outside checkouts and build contexts.
The scheduler receives only the cron bearer secret and deployment role.

From the reviewed production Toolbox checkout, after preparing the vault item:

```sh
python3 deployments/bully-pulpit/secrets.py
python3 deployments/bully-pulpit/database.py init
```

Initialization creates `bully_pulpit` and `bully_pulpit_workflow` in managed
`postgres`, owned by `bully_pulpit` and `bully_workflow` respectively. Their roles
have no superuser, create-role, create-database, replication or bypass-RLS rights.
Public connection privileges on these two databases are revoked. Other databases
and the old pilot are not modified. Cluster-local administrator access is used
only by the operator's bounded provisioning/copy tool. Initialization validates
both credentials and requires both role names and both database names to be
unused before it changes anything. It never adopts an existing role or resets
its password. Role creation is transactional, but PostgreSQL database creation
cannot share that transaction. After a partial failure, stop and inspect the
specific new roles/databases before completing provisioning manually; rerunning
`init` refuses existing names and never drops, reassigns, or repairs them.

Prepare and test the exact reviewed application image before the maintenance
window so the final heartbeat build can reuse its Docker layers. Rehearsal
restores must use separately approved disposable databases, not the final target.
The final import must be a fresh production Neon snapshot, never pilot data.
Freeze cloud writes, stop cloud scheduled work, and drain/reconcile pending
Workflow/provider effects before taking that final snapshot. Preserve cloud data
and old deployments during verification.

Provision the explicit production URL privately as
`secrets/source-database.json` (`{"url":"<production-Neon-URL>"}`, mode 0600).
Do not use a development environment fallback. Then run:

```sh
python3 deployments/bully-pulpit/database.py copy
```

Copy refuses an occupied target, takes one read-only source snapshot, saves a
private custom-format backup, restores only the app database transactionally,
and compares every application table count with that same snapshot. The success
record includes the source archive SHA256. It excludes provider Workflow schemas;
the new Workflow database starts fresh. Cloud Workflow state requires draining
or explicit reconciliation, not a blind retry of already accepted sends.

The managed cluster's existing daily `pg_dumpall` S3 backup automatically includes
both new databases and roles. The release helper additionally backs up these two
databases before migrations. Run the documented forced Toolbox backup and an
isolated restore check after migration; an upload success is not a restore test.

## Enable, verify, and activate

Use the SHA256 from the verified `database-copy.json`, without printing secrets:

```sh
python3 deployments/bully-pulpit/deploy.py enable --copy-sha256 <verified-source-sha256>
```

The next heartbeat builds from the verified application commit with public build
arguments, preserves the exact image ID and frozen Compose/proxy/scheduler files,
runs additive app and Workflow migrations, starts the containers and waits for
health. Only then is deployment success recorded. The app remains parallel.
Verify the real homepage, articles/photos, search, optimized images, signup and
OTP, account/admin authorization, Checkout/download ownership, and delivery-free
Workflow sleep/restart recovery. Verify the local proxy using the production Host
header while public traffic still follows the reviewed maintenance plan.

After the final copy and local checks, with cloud writers and schedules stopped:

```sh
python3 deployments/bully-pulpit/deploy.py activate --copy-sha256 <verified-source-sha256>
```

Change the canonical vault ENV to `DEPLOYMENT_ROLE=primary` and refresh that
specific item in Toolbox's one-hour credential cache through the documented
operator environment. The normal heartbeat recreates the app and scheduler with
the role change and performs health checks. Use Cloudflare MCP to back up and
patch current remote tunnel ingress and DNS for the production host; preserve
unrelated rules and Access settings. Route `www.philipithomas.com` and all three
aliases (`philipithomas.com`, `ilic.nyc`, `www.ilic.nyc`) to the proxy on port
4244. Preserve each incoming Host header; an override to the canonical host would
skip the alias redirects. Do not use the old port-3005 redirector for these aliases:
it discards article paths and query strings. Keep `config.yml` consistent after
the reviewed route change, then verify alias status/Location with a non-root path
and query, public flows, and `/api/health`.

`deployment.json` contains the healthy image/configuration; the preceding healthy
record is saved to `previous-deployment.json`. Image IDs have persistent unique
tags. For application rollback, pause automatic updates and restore the previous
record's Compose wrapper and exact image without restoring an older database.
The migration contract remains additive. Do not re-enable cloud writers against
a stale database after local writes begin; a reverse data migration is a separate
operation. Never use `down -v` or delete the old pilot while validating this move.

## Scheduled work

`scheduler.py` preserves four UTC schedules:

| Route | Schedule |
| --- | --- |
| suppression-sync | `*/15 * * * *` |
| bell-retention | `17 10 * * *` |
| subscriber-backup | `0 11 1 * *` |
| morning-report | `*/15 11,12 * * *` |

The scheduler does nothing unless its role is primary. A persistent SQLite ledger
under `scheduler/` transactionally claims each route and UTC minute before its
HTTP request. Multiple tickers and restarts cannot repeat that interval. Failed,
interrupted or uncertain requests are not automatically retried in the same
interval, particularly the monthly subscriber email. This provides at-most-once
attempts, not exactly-once external delivery. Morning report keeps its existing
application deduplication and same-morning catch-up. Missed intervals after a
restart are recorded rather than replayed. Failed/missed attempts and stale
heartbeats make the scheduler container unhealthy until a later successful
interval or a reviewed repair. Logs include only route, minute, outcome and HTTP
status; no response bodies or credentials.

## Development checks

Use the separate Toolbox development clone. Run the normal Ruby suite and:

```sh
python3 -m unittest discover -s deployments/bully-pulpit -p 'test_*.py'
python3 deployments/bully-pulpit/test_proxy.py
```

The second command is an opt-in isolated nginx test with unique disposable
containers, an ephemeral loopback port, and no production networks/data/secrets.
Do not run deployment scripts against real services to test code changes.
