<div align="center">
  <a href="https://contraption.co/projects">
    <img src="/assets/toolbox.svg" alt="Toolbox" width="200">
  </a>
  <br /><br />
</div>


A lightweight framework for running multiple web apps on a Mac Mini (or, any Mac). This is the actual script that powers [www.contraption.co](https://contraption.co) and other web applications from a single Mac Mini home server. Learn more about the story in ["A mini data center"](https://www.contraption.co/a-mini-data-center/).

If you encounter any problems, please [open an issue](https://github.com/contraptionco/toolbox/issues/new).

## What is this?

Toolbox is a collection of Ruby scripts that orchestrate Docker containers, Git repositories, and system services to create a robust home server environment. It's designed to be simple, maintainable, and reliable - perfect for hosting personal web apps from home without complex infrastructure or monthly cloud costs.

For full setup instructions, read the post: [How to host web apps on a Mac Mini](https://www.contraption.co/how-to-host-web-apps-on-a-mac-mini/)

## Philosophy

This toolbox is built with the following principles in mind:

- **Simplicity over complexity**: Scripts are readable and maintainable
- **Docker-based**: Each service runs in its own container
- **Git-powered**: Auto-deployment from repositories
- **Configuration over code**: Centralized configuration in one file
- **Secure access**: Cloudflare Tunnel eliminates the need to open ports
- **Secret management**: 1Password integration keeps credentials secure
- **Legibility**: No frameworks, minimal learning curve, and mostly raw Docker

## Features

- **Automatic service management**: Start/restart services on boot
- **Cloudflare Tunnel integration**: Expose services to the internet securely
- **Git repository management**: Auto-update when changes are detected
- **Docker container orchestration**: Simplified management of containerized apps
- **One-password integration**: Secure credential management
- **Heartbeat monitoring**: Optional uptime monitoring
- **Lock screen on boot**: Secure your server with automatic screen locking after reboot
- **Complex Git Service Management**: Supports services requiring initial setup scripts and managed via their own Docker Compose.
- **Private dashboard**: Native host metrics, deployment status, Docker inventory,
  container metrics and redacted live logs behind Cloudflare Access.

## Dashboard

[toolbox.contraption.co](https://toolbox.contraption.co) is a read-only view of the
Mac mini. It shows disk capacity (including the distinction between immediately
free and reclaimable space), memory, load, uptime, heartbeat status, configured
applications, and running or stopped Docker containers. Unexpected running
containers are flagged. Expand a container for CPU, memory, network, block I/O,
restart count and recent logs.

The web service runs natively in Ruby on `127.0.0.1:4178`; running it inside Docker
would report Docker's Linux VM as the host. Toolbox manages its separate
`co.contraption.toolbox.dashboard` LaunchAgent and installs the locked dashboard
gems under `.runtime/dashboard/gems`. Application containers and the shared
PostgreSQL database are not dependencies of the UI. Netdata and its scheduled
log rotation are retired; the dashboard reads host metrics directly. Existing
Netdata files and metric history are preserved.

Cloudflare Access is the only login. The existing Toolbox UI application uses the
same private allow policy as Junk Drawer. The tunnel connector and Ruby origin
both verify the Access application token. There are no mutation or command
endpoints. `/healthz` contains only readiness and the loaded revision; other
routes require a valid token. Host logs are bounded and conservatively redacted,
but may still contain sensitive application output and remain private.

On an iPhone, open the dashboard in Safari, sign in through Cloudflare, then use
**Share → Add to Home Screen**. The web app has its own icons and standalone
display. Offline mode shows a reconnect message; metrics, logs and authentication
responses are never saved for offline use. Current metrics refresh every ten
seconds and logs every five seconds while visible. History is not retained.

### Develop and verify the dashboard

Use a separate development clone as described in [AGENTS.md](AGENTS.md):

```sh
bundle config set --local path .runtime/bundle
bundle install
ruby web/server.rb --demo
```

Open `http://127.0.0.1:4179` for synthetic host/container/log fixtures. Demo mode
cannot read production metrics. Unit tests use fake command runners, temporary
files and generated signing keys, so they do not need Docker or Cloudflare:

```sh
ruby -Itest -e 'Dir["test/**/*_test.rb"].sort.each { |file| require_relative file }'
zsh -n heartbeat.sh
node --check web/public/app.js
node --check web/public/sw.js
```

For an authorized rollout, merge a verified PR and let the heartbeat update
production. Check the native origin's `/healthz`, verify anonymous public requests
reach the Access login, then exercise the authenticated UI and API. This tunnel's
**remote configuration overrides `config.yml`**: fetch and edit only the intended
remote ingress rule through Cloudflare MCP, preserving unrelated routes and the
Access policy. Do not expose the origin before Access is confirmed.

## Requirements

For full setup instructions, read: [**How to host web apps on a Mac Mini**](https://www.contraption.co/how-to-host-web-apps-on-a-mac-mini/)

Before you start, ensure you have:

- A Mac running macOS (tested on Monterey and later)
- [Homebrew](https://brew.sh/) installed
- [Docker Desktop](https://www.docker.com/products/docker-desktop) installed and running
- [Git](https://git-scm.com/) installed and configured with access to your repositories
- [ASDF](https://asdf-vm.com/) for Ruby version management
- [1Password CLI](https://1password.com/downloads/command-line/) installed and configured
- [Cloudflare](https://www.cloudflare.com/) account with a domain
- [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) configured
- (Optional) [UptimeRobot](https://uptimerobot.com/?red=contra) account for monitoring
- (Optional) [Papertrail](https://www.papertrail.com/) account for log aggregation

## Quick start

1. Fork this repository
2. Clone your fork to your Mac
3. Configure your Cloudflare tunnel in `config.yml`
4. Edit `config.rb` to match your services and domains
5. Install Ruby: `asdf install`
6. Commit and push your configuration to your fork's `main`, then update the production checkout and run: `ruby toolbox.rb --production`
7. Set up the heartbeat script for auto-updates

## Setting up 1Password CLI

The toolbox relies on 1Password CLI for secure credential storage:

1. Install 1Password CLI:
   ```
   brew install 1password-cli
   ```

2. **Security Recommendation**: Create a dedicated vault in 1Password specifically for your server credentials. This limits the scope of access to only the secrets needed for this toolbox, keeping your personal secrets separate.

3. Choose an authentication method:

   **For manual use:**
   - Sign in to your 1Password account interactively:
     ```
     eval $(op signin)
     ```

   **For automated use (recommended for the heartbeat service):**
   - Create a service account token:
     - Go to 1Password account settings → Developer → Service Accounts
     - Create a new service account token with access only to your dedicated server vault
     - Add the token to the LaunchAgent plist file (no interactive login required)

For detailed setup instructions, follow the [official 1Password CLI guide](https://developer.1password.com/docs/cli/get-started/).

### Service account request limits

The heartbeat runs every minute, but it does not need to retrieve unchanged secrets
that often. With `OP_SERVICE_ACCOUNT_TOKEN` set, Toolbox caches successful field
reads and a successful authentication check for one hour in
`.runtime/one-password/`. The directory has mode `0700` and its files have mode
`0600`; the cache contains plaintext secrets and must remain private and outside
Git and Docker build contexts. Entries are scoped to the token, vault, backend,
item, and field. The token itself is not saved in this cache. Interactive CLI
sign-in without a service account remains uncached.

Secret changes and service account revocation can take up to one hour to reach
Toolbox. An expired entry must be refreshed successfully before use; authentication,
permission, and rate-limit errors do not fall back to expired credentials. The
cache cannot populate until 1Password accepts the first request.

For an authorized credential rotation, run the production heartbeat with
`TOOLBOX_OP_REFRESH=1` in the usual service-account environment. This bypasses fresh
entries and replaces them only after successful retrieval. A failed refresh
invalidates that entry. `TOOLBOX_OP_CACHE=0` disables cache reads and writes for a
run; leaving it disabled for scheduled runs can exhaust the daily request quota.
Keep the normal production checkout and intent guards in place for these runs.

## Setting up Cloudflare Tunnel

Cloudflare Tunnel provides a secure way to expose your home server to the internet without opening ports. For a detailed guide on setting up Cloudflare Tunnel on a Mac, follow [Sam Rhea's excellent guide](https://web.archive.org/web/20241113053641/https://blog.samrhea.com/posts/2021/zero-trust-mac-browser/).

To set up Cloudflare Tunnel for this toolbox:

1. Create a Cloudflare account and add your domain
2. Install cloudflared: `brew install cloudflared`
3. Authenticate with Cloudflare: `cloudflared tunnel login`
4. Create a tunnel: `cloudflared tunnel create toolbox`
5. Create a `config.yml` file in your toolbox directory with your host-to-port mappings:
   ```yaml
   tunnel: YOUR_TUNNEL_ID
   credentials-file: /path/to/credentials/file.json

   ingress:
     - hostname: yourapp.yourdomain.com
       service: http://localhost:8000
     - hostname: anotherapp.yourdomain.com
       service: http://localhost:4000
     - service: http_status:404
   ```
6. Update the `TUNNEL_CONFIG` section in `config.rb` to reference your config.yml file

The toolbox will manage starting and running your Cloudflare Tunnel using this configuration.

## Configuring your services

1. Edit `config.rb` to match your services and domains
2. Configure your Docker services, Git repositories, and system services in the corresponding sections
3. Update the Cloudflare Tunnel configuration to reference your `config.yml` file
4. Each service requires its own configuration

Here's an example of how services are defined in `config.rb`:

```ruby
DOCKER_SERVICES = [
  {
    name: 'ghost',
    image: 'ghost:5.109.2',
    ports: ['2368:2368'],
    volumes: ["#{DATA_DIR}/ghost:/var/lib/ghost/content"],
    environment: {
      url: 'https://your-domain.com',
      # Other environment variables...
    }
  }
]
```

Here's an example of a service cloned from Git that runs its own install script and is managed by Docker Compose within its directory:

```ruby
GIT_SERVICES = [
  {
    name: 'sentry',                                         # Service name
    repo_url: 'https://github.com/getsentry/self-hosted.git', # Sentry repo URL
    local_path: "#{Config::CODE_DIR}/sentry-self-hosted",   # Local path for the repo
    # Command to run ONCE after initial clone.
    install_cmd: './install.sh --no-report-self-hosted-issues',
    # Indicates this service uses docker-compose in its directory
    use_compose: true,
    # Auto-update set to false as Sentry upgrades involve install script, not just git pull
    auto_update: false
  }
]
```

### Manual

Manual runs at `https://manual.ilic.nyc` from the `philipithomas/manual` repository's
`main` branch. Toolbox builds the `tools` and `runner` Dockerfile targets as
`manual-migrate` and `manual-app` inside a temporary snapshot of the verified
release. Compose uses those local images, runs migrations and the idempotent
seed, then starts the app on `127.0.0.1:3007`. The app and migration containers
join the existing `toolbox_network`; no additional PostgreSQL server is created.

The `ENV` field of the `manual` item in the configured 1Password vault contains
the multiline production credentials and application settings. Toolbox writes
it to Manual's ignored `.env` with owner-only permissions. Compose parses the dotenv values, including
quoted values; do not split this field into Docker build arguments. Set
`DATABASE_URL` to the existing database connection string, using `postgres` as
the hostname when targeting Toolbox's PostgreSQL container. The database itself
must exist before deployment. The remaining variables are documented in Manual's
`.env.production.example` and README. Secrets are supplied only at runtime.

The local `config.yml` records the `manual.ilic.nyc` route to port 3007. Cloudflare
manages this tunnel's active ingress remotely, so the corresponding DNS and
remote ingress entry must also be configured while preserving all existing
routes. Verify the public sign-in page and the application flow after deployment,
as well as the app's `/api/health` endpoint.

#### Bedroom air quality

Toolbox supplies the bedroom Awair's nonsecret LAN settings through Manual's
`app.environment` Compose override in `config.rb`:

```text
AWAIR_LOCAL_URL=http://awair-elem-1425e2.local
AWAIR_DEVICE_MAC=70:88:6B:14:25:E2
```

These two deployment settings take precedence over the 1Password `ENV` field;
do not duplicate them there. The hostname follows the device across DHCP address
changes, and the MAC check prevents collecting readings from another device.
Enable the Awair's Local API in its app. Manual connects from Docker using IPv4,
checks device identity, and collects readings every five minutes. No cloud API
key, new port mapping, or firewall rule is required. Changing these settings in
`config.rb` causes the normal heartbeat to recreate Manual's containers and
wait for health before recording the deployment. Other credentials stay in
1Password.

#### Hue Bridge

Manual's `app.environment` override in `config.rb` supplies these nonsecret
settings for the local Hue Bridge:

```text
HUE_BRIDGE_URL=https://0017886136a4.local
HUE_BRIDGE_ID=001788FFFE6136A4
```

Keep `HUE_APPLICATION_KEY` only in the `manual` 1Password item's multiline `ENV`
field. Pair a dedicated application key through the Bridge's physical link
button; never commit the key or put it in Docker build arguments. The address
and identity above take precedence over `ENV`. Manual must verify HTTPS against
the Hue CA and the exact Bridge identity. The integration reads light status;
these settings do not authorize changing lights or HomeKit pairing.

After an authorized key update, Toolbox's one-hour 1Password cache may delay
activation. An authorized operator can refresh only `manual` / `ENV` through
`Core::OnePassword.get_item` with `TOOLBOX_OP_REFRESH=1` in the existing production
service-account environment. Never print the returned field. The next normal
heartbeat detects the changed dotenv bytes, recreates Manual's containers, and
waits for health even if the application commit has not changed. Do not edit the
generated `.env` or disable the cache globally.

#### Find My locations

Manual can read explicitly mapped family locations from Find My on the Mac. The
application stays in Docker. An optional native LaunchAgent,
`co.contraption.toolbox.manual-location`, serves only **127.0.0.1:4180**. Docker
Desktop reaches it through `host.docker.internal`; it has no public tunnel route.

The Mac must have a logged-in graphical session, Find My signed in, and the
relevant people already sharing their locations. In each Manual profile, set the
exact Find My display name. The bridge reads only those requested names. It does
not change Apple sharing permissions, read Apple account caches, or use the
keychain. Duplicate names with conflicting rows are unavailable rather than
guessed. This uses Find My's English Accessibility interface, not a supported
Apple People API, so macOS interface changes can require a reader update.

For an authorized production setup, create
`~/code/toolbox/.runtime/manual-location/config.json` as a regular, owner-owned
file with mode `0600`, in an owner-only directory. It contains only:

```json
{"key":"<random URL-safe key of at least 43 characters>"}
```

Set these variables in the `manual` 1Password item's `ENV` field:

```dotenv
MANUAL_LOCATION_BRIDGE_URL=http://host.docker.internal:4180
MANUAL_LOCATION_BRIDGE_KEY=<the same key>
```

The key is a separate, narrow credential. Do not reuse an Apple, 1Password, or
application signing credential. Keep it out of shell arguments, logs, and Git.
The heartbeat compiles `native/find_my_reader.swift`, installs the locked Ruby
dependencies, and starts only this LaunchAgent when the private configuration
exists. In **System Settings → Privacy & Security → Accessibility**, grant access
to both `~/code/toolbox/.runtime/manual-location/find-my-reader` and the Ruby
executable that launches this helper. Read the exact interpreter path from the
installed LaunchAgent without printing its environment:

```sh
/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' \
  "$HOME/Library/LaunchAgents/co.contraption.toolbox.manual-location.plist"
```

For example, the current installation uses
`/Users/philip/.asdf/installs/ruby/3.4.1/bin/ruby`. Use the command's actual output;
the version and path can change. A changed reader or interpreter may need approval
again; unrelated Toolbox releases preserve the reader binary.

If `permission_required` persists with the reader enabled, check the exact Ruby
entry too. macOS attributes this LaunchAgent's child Accessibility requests to
Ruby as the responsible process, so the reader's grant alone is insufficient.
The reader starts fresh for every refresh; restarting it does not grant its
parent permission. Do not grant unrelated interpreters or change the TCC database.

`GET /healthz` reports the helper revision, not Find My availability. Authenticated
`POST /v1/locations` accepts `people: [{personId, findMyName, findMySource}]` and
`refresh`. `findMySource` is `person` or `device`; omitting it preserves the
original People mapping. Use the exact displayed device name for a phone that
supplies someone's own location. `Me` without an observation time is not a
substitute. Responses retain `source: "find-my"` and include `findMySource` so
Manual can distinguish a device observation from a People observation.

Refresh runs asynchronously and may activate Find My or select its People or
Devices tab. Mixed requests read those tabs sequentially, with a separate bounded
native invocation for each; source and exact name jointly identify cached data,
refresh intervals, and failures. On older interfaces, it may open a mapped
person's or device's read-only detail card to
verify the exact name separately from the combined sidebar label. The same row
must be selected, and a preexisting header cannot validate selecting another row.
Ambiguous candidates remain unavailable. It never invokes sharing actions or
context menus. A missing Accessibility grant returns `permission_required`; a
locked session, unavailable app, missing person, or unsupported interface remains
unavailable. Device support currently requires the verified legacy sidebar and
detail-card layout; unsupported layouts fail closed. It never presses device
actions such as Play Sound, Mark As Lost, or Erase.

For supported layouts, the reader opens the verified bubble's **More Info**
control and reads the Info panel's separate name, street address, and observation
age fields. It closes only that read-only panel, waits for the sidebar to return,
and verifies the selected source again. A response may include `address` alongside
`label` when the exact identity and both observation ages agree. Generic city
labels, missing timestamps, mismatched panels, and unsupported address formats
never become precise addresses. Opening Info does not invoke its sharing or
settings controls. Address data has the same private, latest-only lifetime as
the observation and is omitted for paused, expired, or unavailable readings.

Only the latest observations are held in memory. There is no location history,
background collection timer, request log, or coordinate extraction. A displayed
`Now` or explicit age in the sidebar supplies the observation time. `Paused` is
always marked paused with no observation time; directions travel times are never freshness
evidence. Reads expire after 15 minutes, and observations older than two hours
are discarded. Manual must distinguish these actual observations from calendar
locations, which are plans. Responses are private and never cached by a CDN.
Existing Find My place labels, including Home and Work, are preserved. The helper
does not guess a place from a city, calendar entry, distance, or device name.

Removing the private configuration disables the helper on the next heartbeat,
unloads its own LaunchAgent, and leaves other services untouched. Optional-helper
failures do not skip application deployment checks.

### PostgreSQL backups, including Manual

Manual's production `DATABASE_URL` points to the `manual` database in Toolbox's
existing `postgres` container. The enabled `postgres_backup` script runs
`pg_dumpall` against that entire cluster, so it includes Manual, Postcard, the
other databases, and cluster roles. Manual does not need a second backup job or
another copy of its connection string. If `DATABASE_URL` moves to a different
PostgreSQL server, this coverage must be updated before the move.

The heartbeat checks the job every minute. A successful backup starts the next
24-hour interval; a failed export or upload does not advance the success marker.
The export uses pipeline failure propagation, an owner-only temporary file, and
a complete gzip integrity check that rejects empty or truncated exports before
upload. PostgreSQL provides each database's consistent dump snapshot; this is
not one atomic snapshot across every database in the cluster.

Backups use the existing `toolbox` 1Password item's `AWS_ACCESS_KEY_ID`,
`AWS_SECRET_ACCESS_KEY`, `AWS_REGION`, and `S3_BUCKET` fields. Objects have the key
`YYYY-MM-DD/postgres-YYYYMMDDTHHMMSSZ.sql.gz`, with the directory date in
`America/New_York` and the filename timestamp in UTC. The script does not delete
remote snapshots or change bucket lifecycle rules. Retention is governed by any
existing S3 lifecycle configuration; inspect it with an authorized account
rather than assuming the backup writer can read it. Preserve existing history.

`postgres_backup.last_success.txt` records the last completed upload in UTC.
`postgres_backup.lock.txt` prevents concurrent backups; an active lock also
blocks a forced run. Locks older than one hour follow the existing stale-lock
recovery behavior. Failed and partial exports are removed, and a successful
upload removes the local temporary dump.

For an explicitly authorized snapshot after a migration or import, run only the
backup entrypoint from the clean, verified production checkout, with the same
Ruby and secret environment as the heartbeat:

```sh
cd ~/code/toolbox
ruby scripts/postgres_backup.rb --production --force
```

`--force` skips only the 24-hour interval. It does not bypass the lock or the
production path, clean `main`, and `origin/main` checks. Omit `--force` to retain
the normal interval. This command does not deploy applications or restart the
tunnel. Do not print the LaunchAgent environment or put credentials in command
arguments to run it.

To verify recovery, use credentials authorized to download the snapshot and a
private temporary directory. Check the complete gzip, then restore the cluster
dump into an isolated PostgreSQL instance with the matching major version and
required extensions, including pgvector. Verify Manual's migrations, pages,
revisions, accounts, and upload references there. Export just the `manual`
database from that instance for a separately reviewed application restore. Do
not pipe the cluster dump into the live server: it also contains Postcard and
other applications. A successful upload and gzip check do not substitute for a
restore test; the backup writer may have no download permission.

This job backs up database records, including attachment metadata. Uploaded
image and PDF bytes remain in Manual's separate private S3 bucket; this database
job does not make a second copy of those objects.

## Heartbeat script (auto-updates)

To keep your server updated automatically:

1. From the production checkout, run: `ruby install_launch_agent.rb --production`
2. Edit the generated plist file:
   ```
   vi ~/Library/LaunchAgents/co.contraption.toolbox.heartbeat.plist
   ```
3. Configure the plist file:
   - Set your 1Password service account token in the `OP_SERVICE_ACCOUNT_TOKEN` field
   - Keep `TOOLBOX_OP_BACKEND` set to `docker` on macOS hosts where the native `op` daemon is unreliable
   - Update other paths if necessary
4. Load the LaunchAgent: `launchctl load ~/Library/LaunchAgents/co.contraption.toolbox.heartbeat.plist`

The script will check for updates every minute and apply them if found. This is
a production deployment mechanism: merging into `main` can update the live
server on the next successful heartbeat.

## Developing Toolbox on the production Mac

Use a separate clone for development. Leave the production checkout at
`~/code/toolbox` and the application checkouts named in `config.rb` untouched:

```sh
mkdir -p ~/development
git clone git@github.com:contraptionco/toolbox.git ~/development/toolbox
cd ~/development/toolbox
git pull --ff-only origin main
git switch -c my-change
```

Use your fork's remote URL if appropriate. A separate development environment is
not necessary for editing Toolbox and running its unit tests. See
[AGENTS.md](AGENTS.md) for the production boundaries, test commands, and PR workflow.

Do not start Toolbox from the development clone. Its configuration still names
the production Docker containers, data, ports, and application repositories.
The entrypoints refuse an unintended checkout before running services or writing
heartbeat state. Manual orchestration and LaunchAgent installation additionally
require `--production`. The default production location is `~/code/toolbox`;
`TOOLBOX_PRODUCTION_REPO_DIR` explicitly selects a different production location.
Changing this variable does not move application data or isolate Docker.

For an intentional production run, prefer `./heartbeat.sh` from the production
checkout so the heartbeat lock serializes scheduled and manual runs. Toolbox
requires a clean `main` matching `origin/main` and refuses unexpected branches
instead of switching them. Development edits to the production checkout are
unsafe even with these checks: the scheduler loads its own code from that path.

Git application services default to the remote `main` branch when `branch` is
omitted. Set `branch` explicitly to pin another branch or release tag. Application
source validation rejects unexpected branches, local commits ahead of or diverged
from the remote, tracked modifications, and untracked source files. A pinned tag
must match the remote tag's commit. Toolbox does not discard local changes to
make a deployment pass.

Docker and static-file builds use a temporary snapshot of the verified commit,
so ignored files and edits made during a build cannot enter that build context.
Snapshots omit `.git` and reject submodules rather than silently building without
their contents; applications requiring either need a supported build path first.
Replacement app containers use the immutable ID of the newly built image. An
unexplained change to a production image tag is refused while the existing
container is retained. Do not use production image tags for development builds.
Compose services retain their existing project directories and generated runtime
files; their bind mounts and install commands still need production-only paths.

These checks reduce accidental deployment risk; they do not provide automatic
rollback or zero-downtime replacement. Before rolling out this change, review
existing application checkouts for local modifications and branch drift. A
source-validation rejection leaves its existing container running and reports a failure.
Do not remove local files or relax the checks just to silence that failure.

On macOS, the disk check accounts for storage the operating system can reclaim,
while requiring at least 20 GiB to be immediately free before work starts. It
blocks at 90% effective usage, or when that physical reserve is unavailable, and
still warns about high raw usage. If macOS capacity information is unavailable,
the original `df` percentage limit applies along with the physical reserve.
Other operating systems retain the 90% `df` limit. The reserve is a starting
floor, not a guarantee that every backup or build fits; disk usage is checked
again after the run. Diagnose disk pressure separately; do not lower these
guards or prune production volumes as part of development.

## Security: Automatic screen locking

Included in the repository is a `lock_screen_on_login.app` utility that automatically locks your Mac's screen upon login. This is useful for servers configured with automatic login (to ensure services start on reboot) while still protecting physical access to the machine.

To set up automatic screen locking:

1. Add `lock_screen_on_login.app` to your Login Items:
   - Open System Preferences/Settings → Users & Groups → Login Items
   - Click the "+" button and select the `lock_screen_on_login.app` from the repository
   - This ensures the screen locks immediately after automatic login

This setup allows your server to reboot and start services automatically without requiring manual login, while still ensuring that anyone with physical access to the machine needs a password to use it.

## Configuring log forwarding (optional)

If you want to forward logs to a service like Papertrail:

1. Create a Papertrail account and set up a log destination
2. Run the installation script: `ruby install_papertrail.rb`
3. Follow the on-screen instructions to complete the setup
4. Update the generated `log_files.yml` configuration file with your Papertrail host and port

The script will:
- Create a LaunchDaemon plist file for remote_syslog
- Generate a sample log configuration if one doesn't exist
- Provide commands to finalize the installation

For manual installation instead:
1. Install the remote_syslog tool:
   ```
   brew install remote_syslog
   ```
2. Configure the LaunchDaemon:
   ```
   sudo cp com.papertrailapp.remote_syslog.plist /Library/LaunchDaemons/
   sudo vi /Library/LaunchDaemons/com.papertrailapp.remote_syslog.plist
   ```
3. Load the LaunchDaemon:
   ```
   sudo launchctl load /Library/LaunchDaemons/com.papertrailapp.remote_syslog.plist
   ```

## Key services

### Docker containers

All web applications run in Docker containers, making them isolated and easy to manage. The toolbox handles:

- Container creation and configuration
- Automatic updates when new images are available
- Network configuration
- Volume management for persistent data
- Health checks for service monitoring

#### Ollama LLM Service

The toolbox includes configuration for running Ollama, an open-source LLM inference server:

- **Model**: Configured with `gpt-oss:20b` by default
- **Port**: Exposed on `11434` for API access
- **Access Methods**:
  - Internal Docker network: `http://ollama:11434`
  - Local host: `http://localhost:11434`
  - Via Cloudflare Tunnel: `https://ollama.contraption.co` (configure your domain in `config.yml`)
- **Web Interface**: Ollama provides a web UI accessible at the same URL
- **Model persistence**: Models are stored in `~/data/ollama` and persist across container restarts
- **Auto-start**: Automatically starts on boot and pulls the specified model if not already present
- **Health monitoring**: Includes health checks to ensure the service is responsive

To test the Ollama service after starting:
```bash
# Test from the host
curl http://localhost:11434/api/generate \
     -d '{"model":"gpt-oss:20b","prompt":"Write one sentence about Mac Minis."}'

# From another Docker container in the toolbox network
curl http://ollama:11434/api/generate \
     -d '{"model":"gpt-oss:20b","prompt":"Hello, Ollama!"}'
```

### Cloudflare Tunnel

Cloudflare Tunnel creates a secure connection between your Mac and Cloudflare's edge network:

- No need to open ports on your router
- SSL termination and DDoS protection
- Access control with Cloudflare Access (optional)
- Custom domain support

### Git repositories

For apps that require custom builds:

- Automatic cloning and updating
- Build process management
- Deployment to containers or directories
- Support for private repos (requires GitHub authentication)
- Can handle complex setups involving initial installation scripts and integrated Docker Compose management.

## Customizing for your needs

This is a personal tool that I use for my own server - you'll need to adapt it:

1. Remove services you don't need (Ghost, Plausible, etc.)
2. Add your own applications to the config
3. Update domain names and URLs
4. Configure your own Cloudflare tunnel
5. Set up your own 1Password vault items

## Telemetry

Toolbox collects anonymous usage data to help us understand how many people are using this software, so we can prioritize feature updates. We **do not** collect any personal information, credentials, or the content of your services.

You can view our full privacy policy at [contraption.co/privacy](https://contraption.co/privacy), and see the telemetry script at [lib/telemetry.rb](lib/telemetry.rb).

To disable telemetry, set `DISABLE_ANONYMOUS_TELEMETRY = true` in `config.rb` or modify the code to remove it.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
