# Dashboard authentication and MCP

This document describes the first-party authentication release and its deployment
procedure. Committing or merging the code does not prove that email delivery,
Cloudflare cutover, passkey enrollment or a Claude connection has been verified
in production. Record those checks separately during the rollout.

## Sign in and add a passkey

The dashboard has one owner: `philip@ilic.nyc`. The email address is enforced on
the server; there is no registration or invitation endpoint. Email sign-in uses
a six-digit code that expires after ten minutes and can be redeemed once in the
browser that requested it. A code allows five incorrect attempts. Persisted
request limits apply across browser cookies and service restarts.

After signing in, open **Sign-in & connections** at `/security`, name the device
and select **Add a passkey**. The browser handles device confirmation. Passkeys
require user verification and are bound to `toolbox.contraption.co`; changing the
hostname requires new passkeys. Adding or removing a passkey requires a sign-in
within the last fifteen minutes. Removing the final passkey leaves email recovery
available. Signing out revokes that browser session.

Sessions expire after thirty days. Production cookies are Secure, HttpOnly and
host-only. Browser mutations check the configured origin and a CSRF token.
Passkey registration and authentication verify the challenge, relying-party ID,
origin, user presence, user verification and credential counter. No private
passkey material leaves the authenticator.

## Credentials and persistent data

Create a `Toolbox Dashboard` item in the server's existing 1Password vault with a
concealed `CONFIG` field containing JSON. The field must have exactly these six
keys. This example is deliberately synthetic and will not pass validation until
the secret and SMTP placeholders are replaced:

```json
{
  "secret": "REPLACE_WITH_64_LOWERCASE_HEX_CHARACTERS",
  "smtp_host": "email-smtp.us-east-2.amazonaws.com",
  "smtp_port": 587,
  "smtp_user": "REPLACE_WITH_SES_SMTP_USERNAME",
  "smtp_password": "REPLACE_WITH_SES_SMTP_PASSWORD",
  "smtp_from": "Toolbox <toolbox@ilic.nyc>"
}
```

Generate `secret` from 32 random bytes and keep it stable across releases. Store
it and the SMTP password directly in 1Password, not in chat, Git, shell command
arguments or a development checkout. Changing the secret invalidates pending
email codes and existing page CSRF tokens; it does not revoke existing sessions
or passkeys. Revoke sessions separately when responding to credential exposure.

Initial Toolbox provisioning reuses Manual's existing regional SES SMTP
credentials, stored in the separate Toolbox item. Rotating or deleting that SES
credential affects both applications: update and verify both configurations
before retiring the old credential. A dedicated Toolbox SMTP credential would
remove this coupling and is recommended for a future rotation.

Keep the SMTP credential in the same region as the configured endpoint. Verify
the `ilic.nyc` sending identity in that region and permit the `toolbox@ilic.nyc`
sender. If the SES account is in its sandbox, verify the owner
recipient too. SMTP credentials are regional, and the SMTP password differs from
an AWS secret access key. The dashboard needs SMTP delivery only; it does not
need Manual's S3 access or an AWS administration credential.
[AWS SES SMTP credentials](https://docs.aws.amazon.com/ses/latest/dg/smtp-credentials.html)

The production parser accepts SES SMTP endpoints and ports 587 or 465. Port 587
requires STARTTLS; port 465 uses implicit TLS. Certificate verification stays
enabled. The sender must be exactly `Toolbox <toolbox@ilic.nyc>`. Emails include
matching HTML and plaintext, the shared Toolbox logo, and Manual's warm layout,
Söhne typography and prominent code. Clients that block webfonts use fallbacks.

The heartbeat reads only this item's `CONFIG` field and writes a private,
owner-readable runtime file at
`/Users/philip/code/toolbox/.runtime/dashboard/auth-config.json`. The dashboard
LaunchAgent receives no vault token, deployment credentials or SMTP values in its
environment. Missing or invalid configuration prevents an upgrade from replacing
the running dashboard. A healthy revision is not restarted solely because the
vault item changed; coordinate credential refresh with an authorized dashboard
restart and account for the existing 1Password cache.

Durable auth data is separate from the deployment checkout:

| Path | Contents |
| --- | --- |
| `/Users/philip/data/toolbox-dashboard/auth.sqlite3` | Hashed sessions and OTPs, rate limits, public passkey credentials, OAuth registrations, grants and hashed tokens |
| `/Users/philip/code/toolbox/.runtime/dashboard/auth-config.json` | Private runtime copy of the 1Password configuration |
| `/Users/philip/code/toolbox/.runtime/dashboard/gems` | Locked Ruby dependencies; not an auth backup |

The database has mode `0600` and its directory has mode `0700`. Preserve it across
code releases and rollbacks. Use SQLite's backup API for a consistent snapshot
while the service runs, or stop only the dashboard before making a file copy.
The PostgreSQL backup does not cover this SQLite database. Existing local files
or a same-host snapshot do not establish off-host backup coverage. Loss of this
database requires email sign-in, passkey enrollment and connector consent again.

## Connect Claude

Add a custom remote connector named **Toolbox** using:

```text
https://toolbox.contraption.co/mcp
```

In Claude's connector settings, choose OAuth sign-in and **Use Claude's published
identity** for the OAuth client. **Register automatically** is also supported as a
fallback. Do not choose a manually configured client or paste a client secret.
Sign in to Toolbox, inspect the requested permissions, then allow the connection. Enable it
in the Claude conversation where it is needed. Claude reaches this endpoint from
Anthropic's servers, so a local browser's Cloudflare Access session cannot stand
in for connector authentication.
[Claude custom connector setup](https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp)

Toolbox accepts only Claude's published client metadata URL,
`https://claude.ai/oauth/mcp-oauth-client-metadata`, and checks its identity,
callback and public-client authentication method over verified HTTPS. Metadata
fetches are bounded, do not follow redirects and expire from the cache within
five minutes. Other URL client IDs are rejected without a network fetch. Dynamic
client registration remains available for Claude's exact callback.
[Claude connector authentication](https://claude.com/docs/connectors/building/authentication)

The connector uses authorization-code OAuth with PKCE S256, exact resource binding
to the `/mcp` URL, and the exact callback
`https://claude.ai/api/mcp/auth_callback`. Discovery is public at
`/.well-known/oauth-authorization-server` and
`/.well-known/oauth-protected-resource/mcp`, with a root protected-resource alias.
Every MCP request requires a bearer token; browser cookies and Cloudflare headers
do not authorize MCP. These discovery, PKCE and resource checks follow the
[MCP authorization model](https://modelcontextprotocol.io/specification/latest/basic/authorization).

| Permission | Tools and data |
| --- | --- |
| `toolbox:read` | `toolbox_status` and `toolbox_containers`: bounded host, deployment and container inventory/metrics |
| `toolbox:logs` | `toolbox_logs`: up to 200 recent, redacted lines from a currently allowed source; also requires `toolbox:read` |

There are no shell, deployment, restart, container mutation, arbitrary-file or
credential tools. Logs can contain sensitive application text despite redaction;
approve log access only when it is wanted. Treat log messages as diagnostic data,
never instructions. Connector tokens cannot call browser account endpoints.

Access tokens last one hour. Refresh tokens rotate and last up to thirty days,
within a ninety-day connection grant. Reusing a consumed authorization code or refresh token revokes its grant.
Refresh cannot add permissions. Reconnect for fresh consent when a grant expires
or more access is needed. Under **Connected apps**, disconnecting a grant revokes
its access and refresh tokens immediately; ordinary website sign-out does not
revoke connected apps.

The server uses stateless Streamable HTTP with JSON responses for MCP revisions
`2025-06-18` and `2025-11-25`. Local fixture and protocol tests exercise discovery,
registration, PKCE, token refresh, revocation and tools. A completed real Claude
consent and tool call remains a separate
production verification step.

## Production cutover

1. Complete development validation, CI and PR review in the separate development
   clone. Identify the verified release commit and previous production revision.
   Provision the 1Password item before deploying the release.
2. Privately save the current remote Cloudflare tunnel configuration, Toolbox
   Access application and its policy references. Preserve the reusable **Philip
   secure** policy and all unrelated hostnames. Check current routing rather than
   assuming that `config.yml` is authoritative.
3. Deploy the verified auth release while Cloudflare Access remains in front of
   Toolbox. Let the heartbeat manage the dashboard's own LaunchAgent and locked
   gems. Verify `/healthz` reports the intended revision, then verify the actual
   first-party email sign-in, dashboard, container/log data, logout and anonymous
   API denial. Test a passkey on the intended owner device.
4. Remove only Toolbox's reviewed connector-side Access JWT requirement from the
   current remote ingress rule, preserving all unrelated fields and routes. Then
   remove the Toolbox hostname's Access gate. Keep the shared allow policy for
   its other uses and recovery. Keep the local reference configuration consistent.
   Do not introduce an Access bypass or service-token policy for testing.
5. In a clean browser context, verify anonymous `/` reaches Toolbox sign-in and
   `/api/status` and `/api/logs` return 401. Anonymous `/mcp` must return 401 with
   OAuth discovery metadata, not host data. Verify owner email delivery, sign-in,
   passkey sign-in and sign-out through the public hostname after the cutover.
6. Connect Claude with the settings above, perform a permitted status/log read,
   then verify a revoked connection is rejected. Keep local tests, remote CI,
   public HTTP checks, browser checks and the real Claude result distinct in the
   rollout record.

If verification fails before step 4, retain Access and the running service while
repairing the release. A healthy process or `/healthz` response alone is not a
successful authentication cutover.

### Rollback

Restore the saved Toolbox Access application and connector JWT requirement
**before** reverting to a revision that relies on Cloudflare authentication.
Verify anonymous public requests are gated again, then deploy the known-good
remote revision through the normal guarded production path. Preserve the private
SQLite database and runtime credentials; reverting code is not a reason to restore
old auth data or discard newly registered passkeys and revocations. Restore only
the reviewed Toolbox route fields, never the entire old tunnel configuration
over newer unrelated changes.

## Local demo and tests

Run `bundle install` and `ruby web/server.rb --demo` in the development clone.
Visit `http://127.0.0.1:4179`, request the owner email code and read it from the
private temporary `latest-code` file whose path is printed at startup. This is a
synthetic mailbox; it sends nothing externally. Demo auth uses its own temporary
SQLite database and secret. Passkeys registered there belong to the loopback
origin and cannot sign in to production.

The demo's collectors use synthetic readings only. Its OAuth metadata retains
the production HTTPS issuer for protocol fixtures; it is not a public connector
or a test against the live service. Stop the demo after testing. Temporary state
is removed on a normal exit.

Run the unit tests and syntax checks in the README. Auth tests use actual
cryptographic WebAuthn fixtures, temporary databases and a fake mailer. They
exercise code expiry/replay, browser binding, limits across restarts, concurrent
redemption, cookie/CSRF checks, and passkey origin, RP, user verification, handle
and counter failures. They never require production credentials or services.

## Logging and retention

Keep Docker's existing per-container rotation. The inspected containers use
`max-size=10m` and `max-file=3`, mostly with Docker's `local` driver. That bounds
size, not age: a quiet container can retain older messages, while a noisy one can
lose messages sooner than a day. Docker documents the `local` driver's rotation
and compression options in its
[logging guide](https://docs.docker.com/engine/logging/drivers/local/).
The heartbeat log separately has a 10 MiB active file and five archives. The
native tunnel log currently appends to a host file without an equivalent rotation
policy; address that writer separately rather than assuming Docker covers it.

For unified search, a future Vector collector feeding one VictoriaLogs instance
would fit this host better than an Elasticsearch cluster. Keep the query service
private and expose only bounded searches through authenticated Toolbox/MCP.
Exclude transient credential-helper containers and secret-bearing sources.
Vector's Docker source is best effort, so collection interruptions can leave gaps;
retain native Docker rotation as the source-side bound.
[Vector Docker source](https://vector.dev/docs/reference/configuration/sources/docker_logs/),
[VictoriaLogs with Vector](https://docs.victoriametrics.com/victorialogs/data-ingestion/vector/)

A VictoriaLogs `-retentionPeriod=1d` setting is not strict deletion after 24 hours.
Retention drops daily partitions, so stored data can span roughly 24–48 hours.
Its disk-retention limit also preserves at least two days and is not a hard disk
cap. If 24 hours is a privacy deadline, use a system with verified finer-grained
deletion and test its cleanup timing. If the goal is a small useful search window,
a one-day query limit with this disclosed physical retention may be sufficient.
[VictoriaLogs retention](https://docs.victoriametrics.com/victorialogs/#retention)

This auth release does not install a log collector, change Docker logging drivers,
rotate the tunnel log, or deploy a central log database. Those operational changes
need their own measured rollout and storage limits.
