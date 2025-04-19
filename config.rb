require 'etc'

module Config
  #-----------------------------------------------------------------------------------
  # SYSTEM PATHS - Automatically detected, should work on most systems (OK TO LEAVE AS IS)
  #-----------------------------------------------------------------------------------

  # Current username - automatically detected from system
  USER = ENV['USER'] || Etc.getlogin || `whoami`.strip

  # User's home directory - automatically detected
  HOME_DIR = ENV['HOME'] || "/Users/#{USER}"

  # Data storage location - where persistent data will be stored
  # CHANGE THIS if you want to store data elsewhere
  DATA_DIR = "#{HOME_DIR}/data"

  # Code repositories location - where git repos will be cloned
  # CHANGE THIS if you want to store code elsewhere
  CODE_DIR = "#{HOME_DIR}/code"

  #-----------------------------------------------------------------------------------
  # NETWORK CONFIGURATION
  #-----------------------------------------------------------------------------------

  # Docker network name (OK TO LEAVE AS IS)
  # All containers will be connected to this network to communicate with each other
  NETWORK_NAME = 'toolbox_network'

  #-----------------------------------------------------------------------------------
  # 1PASSWORD CONFIGURATION - IMPORTANT TO REVIEW
  #-----------------------------------------------------------------------------------

  # 1Password vault ID where secrets are stored (CHANGE THIS to your vault ID)
  # Find this in 1Password by going to Settings > Vaults and looking at the vault's URL
  OP_VAULT = 'ao6pgbthqnu4expub6pdb4z3oa'

  #-----------------------------------------------------------------------------------
  # UPTIME ROBOT CONFIGURATION - OPTIONAL
  #-----------------------------------------------------------------------------------

  # Configuration for Uptime Robot healthcheck (CHANGE THIS to your Uptime Robot settings)
  # Retrieves the URL from 1Password to ping the Uptime Robot monitoring service
  # To disable Uptime Robot, set this to nil or remove this section entirely
  UPTIME_ROBOT = {
    url_source: { type: '1password', item: 'UptimeRobot', field: 'url' }
  }
  # UPTIME_ROBOT = nil  # Uncomment this line and comment out the above to disable Uptime Robot

  #-----------------------------------------------------------------------------------
  # DOCKER SERVICES - CUSTOMIZE THESE BASED ON YOUR NEEDS
  #-----------------------------------------------------------------------------------

  # List of Docker containers to run
  # Each entry defines a container configuration
  DOCKER_SERVICES = [
    # PostgreSQL Database (MODIFY OR REMOVE if not needed)
    {
      name: 'postgres',                                      # Container name
      image: 'pgvector/pgvector:pg17',                       # Docker image to use (specific version recommended)
      ports: ['5432:5432'],                                  # Port mapping (host:container)
      volumes: ["#{DATA_DIR}/postgres:/var/lib/postgresql/data"], # Data persistence
      environment: {                                         # Environment variables
        # Credentials retrieved from 1Password (CHANGE THESE to your 1Password items)
        POSTGRES_USER: { type: '1password', item: 'Postgres Docker', field: 'username' },
        POSTGRES_PASSWORD: { type: '1password', item: 'Postgres Docker', field: 'password' },
        POSTGRES_MAX_CONNECTIONS: '1000'
      },
      auto_update: true                                      # Whether to auto-update when image tag changes
    },
    {
      name: 'mysql',                                         # Container name
      image: 'mysql:8.0',                                    # Docker image to use (specific version recommended)
      ports: ['3306:3306'],                                  # Port mapping (host:container)
      volumes: ["#{DATA_DIR}/mysql:/var/lib/mysql"],         # Data persistence
      environment: {                                         # Environment variables
        # Credentials retrieved from 1Password (CHANGE THESE to your 1Password items)
        MYSQL_ROOT_PASSWORD: { type: '1password', item: 'MySQL Docker', field: 'password' },
        MYSQL_USER: { type: '1password', item: 'MySQL Docker', field: 'username' },
        MYSQL_PASSWORD: { type: '1password', item: 'MySQL Docker', field: 'password' },
        MYSQL_DATABASE: 'ghost'                              # Default database name
      },
      auto_update: true                                      # Whether to auto-update when image tag changes
    },

    {
      name: 'ghost',                                         # Container name
      image: 'ghost:5.109.2',                                # Docker image to use (specific version recommended)
      ports: ['2368:2368'],                                  # Port mapping (host:container)
      volumes: ["#{DATA_DIR}/ghost:/var/lib/ghost/content"], # Data persistence
      environment: {                                         # Environment variables
        # CHANGE THESE URLs to your domain
        url: 'https://www.contraption.co',                   # Public URL for your Ghost site
        admin__url: 'https://write.contraption.co',          # Admin URL for your Ghost site

        # Database configuration (linked to MySQL container)
        database__client: 'mysql',
        database__connection__host: 'mysql',
        database__connection__user: { type: '1password', item: 'MySQL Docker', field: 'username' },
        database__connection__password: { type: '1password', item: 'MySQL Docker', field: 'password' },
        database__connection__database: 'ghost',

        # Mail configuration (CHANGE THESE to your mail provider)
        mail__transport: 'SMTP',
        mail__options__service: 'Mailgun',
        mail__options__host: 'smtp.mailgun.org',
        mail__options__port: '465',
        mail__options__secure: 'true',
        # Mail credentials from 1Password (CHANGE THESE to your 1Password items)
        mail__options__auth__user: { type: '1password', item: 'Mailgun', field: 'username' },
        mail__options__auth__pass: { type: '1password', item: 'Mailgun', field: 'password' },
        # CHANGE THIS to your email address
        mail__from: "'Philip I. Thomas' <philip@contraption.co>"
      },
      auto_update: true,                                     # Whether to auto-update when image tag changes
      depends_on: ['mysql']                                  # This container depends on MySQL
    }
  ]

  #-----------------------------------------------------------------------------------
  # GIT-BASED SERVICES - CUSTOMIZE THESE BASED ON YOUR NEEDS
  #-----------------------------------------------------------------------------------

  # Services that are based on Git repositories
  # These can be code that gets built and deployed, or code that runs in containers
  GIT_SERVICES = [
    {
      name: 'ghost_theme',                                   # Service name
      repo_url: 'git@github.com:contraptionco/ghost.git',    # Git repo
      local_path: "#{CODE_DIR}/ghost",                       # Where to clone the repo
      deploy_path: "#{DATA_DIR}/ghost/themes/contraption-ghost-theme", # Where to deploy the built theme (optional)
      build_cmd: 'asdf install && npm install && npm run build', # Build command
      auto_update: true,                                     # Whether to auto-update when repo changes
      after_deploy: { type: 'restart_service', service: 'ghost' } # Action after deployment
    },
    {
      name: 'bklt',                                          # Service name
      repo_url: 'git@github.com:contraptionco/bklt.git',     # CHANGE THIS to your repository
      local_path: "#{CODE_DIR}/bklt",                        # Where to clone the repo
      container_config: {                                    # Container configuration after build
        image_name: 'bklt',                                  # Docker image name to create
        ports: ['4000:3000'],                                # Port mapping (host:container)
        environment: {                                       # Environment variables
          DATABASE_URL: { type: '1password', item: 'Bklt', field: 'DATABASE_URL' },
          RAILS_MASTER_KEY: { type: '1password', item: 'Bklt', field: 'RAILS_MASTER_KEY' },
          SECRET_KEY_BASE: { type: '1password', item: 'Bklt', field: 'SECRET_KEY_BASE' },
          SENTRY_DSN: { type: '1password', item: 'Bklt', field: 'SENTRY_DSN' },
          RAILS_ENV: 'production'                            # Environment setting
        },
        cmd: 'bundle exec puma -C config/puma.rb'            # Command to run in the container
      },
      auto_update: true                                      # Whether to auto-update when repo changes
    },
    {
      name: 'junk-drawer',                                          # Service name
      repo_url: 'git@github.com:contraptionco/junk-drawer.git',     # CHANGE THIS to your repository
      local_path: "#{CODE_DIR}/junk-drawer",                        # Where to clone the repo
      container_config: {                                    # Container configuration after build
        image_name: 'junk-drawer',                                  # Docker image name to create
        ports: ['4001:3000'],                                # Port mapping (host:container)
        environment: {                                       # Environment variables
          DATABASE_URL: { type: '1password', item: 'junk-drawer', field: 'DATABASE_URL' },
          SECRET_KEY_BASE: { type: '1password', item: 'junk-drawer', field: 'SECRET_KEY_BASE' },
          GHOST_DATABASE_URL: { type: '1password', item: 'junk-drawer', field: 'GHOST_DATABASE_URL' },
          RAILS_ENV: 'production'                            # Environment setting
        },
        cmd: 'bundle exec puma -C config/puma.rb'            # Command to run in the container
      },
      auto_update: true                                      # Whether to auto-update when repo changes
    },
    {
      name: 'plausible',                                     # Service name
      repo_url: 'https://github.com/plausible/community-edition', # Repo URL (public repo)
      local_path: "#{DATA_DIR}/plausible/plausible-ce",      # Where to clone the repo
      branch: 'v2.1.5',                                      # Specific branch or tag to use
      # Environment configuration from 1Password (CHANGE THIS to your 1Password item)
      env_config: { type: '1password', item: 'Plausible', field: 'env' },
      # Custom docker-compose override
      compose_override: {
        services: {
          plausible: {
            ports: ['127.0.0.1:8000:8000']                   # Port mapping for the service
                                                             # Cloudflare connects to port 8000 to serve:
                                                             # telegraph.contraption.co
          }
        }
      },
      auto_update: true                                      # Whether to auto-update when repo changes
    }
  ]

  #-----------------------------------------------------------------------------------
  # SYSTEM SERVICES - CUSTOMIZE THESE BASED ON YOUR NEEDS
  #-----------------------------------------------------------------------------------

  # System-level services to manage (not in Docker)
  SYSTEM_SERVICES = [
    # Netdata monitoring (MODIFY OR REMOVE if not needed)
    {
      name: 'netdata',                                       # Service name
      type: 'system',                                        # Service type
      cmd: '/opt/homebrew/opt/netdata/sbin/netdata',         # Command path (CHANGE if path differs)
      detection: 'pgrep -f "/opt/homebrew/opt/netdata/sbin/netdata"', # How to detect if running
      start_cmd: '/opt/homebrew/opt/netdata/sbin/netdata -D' # Command to start the service
                                                             # Cloudflare connects to port 19999 to serve:
                                                             # toolbox.contraption.co
    }
  ]

  #-----------------------------------------------------------------------------------
  # CLOUDFLARE TUNNEL CONFIGURATION - REQUIRED
  #-----------------------------------------------------------------------------------

  # Cloudflare tunnel settings (REQUIRED - the entire toolbox depends on this)
  # You must have a Cloudflare tunnel configured for this to work properly
  TUNNEL_CONFIG = {
    # Path to the tunnel config file (CHANGE THIS to your tunnel config path)
    config_path: "#{CODE_DIR}/toolbox/config.yml",
    # Name of the tunnel (CHANGE THIS to your tunnel name)
    tunnel_name: 'toolbox',
    # Path to log file (OK TO LEAVE AS IS)
    log_file: "#{CODE_DIR}/toolbox/tunnel.log"
  }

  #-----------------------------------------------------------------------------------
  # TELEMETRY CONFIGURATION - OPTIONAL
  #-----------------------------------------------------------------------------------

  # Set to true to disable anonymous telemetry collection
  # This helps us understand how many people are using Toolbox
  DISABLE_ANONYMOUS_TELEMETRY = false
end