# Toolbox: Simple automation for a Mac-based home web server

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
- (Optional) [UptimeRobot](https://uptimerobot.com/) account for monitoring
- (Optional) [Papertrail](https://www.papertrail.com/) account for log aggregation

## Quick start

1. Fork this repository
2. Clone your fork to your Mac
3. Configure your Cloudflare tunnel in `config.yml`
4. Edit `config.rb` to match your services and domains
5. Install Ruby: `asdf install`
6. Run: `ruby toolbox.rb`
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

## Setting up Cloudflare Tunnel

Cloudflare Tunnel provides a secure way to expose your home server to the internet without opening ports. For a detailed guide on setting up Cloudflare Tunnel on a Mac, follow [Sam Rhea's excellent guide](https://blog.samrhea.com/posts/2021/zero-trust-mac-browser/).

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

## Heartbeat script (auto-updates)

To keep your server updated automatically:

1. Run the installation script: `ruby install_launch_agent.rb`
2. Edit the generated plist file:
   ```
   vi ~/Library/LaunchAgents/co.contraption.toolbox.heartbeat.plist
   ```
3. Configure the plist file:
   - Set your 1Password service account token in the `OP_SERVICE_ACCOUNT_TOKEN` field
   - Update other paths if necessary
4. Load the LaunchAgent: `launchctl load ~/Library/LaunchAgents/co.contraption.toolbox.heartbeat.plist`

The script will check for updates every minute and apply them if found.

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
