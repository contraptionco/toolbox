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
      environment: { # Environment variables
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
      image: 'ghost:6.19.1',                                  # Docker image to use (specific version recommended)
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
    },
    {
      name: 'signal', # Container name
      image: 'bbernhard/signal-cli-rest-api:latest',         # Docker image to use
      ports: ['8080:8080'],                                  # Port mapping (host:container)
      volumes: ["#{DATA_DIR}/signal:/home/.local/share/signal-cli"], # Data persistence
      environment: {                                         # Environment variables
        MODE: 'native',
        SWAGGER_HOST: 'signal.contraption.co',
        SWAGGER_USE_HTTPS_AS_PREFERRED_SCHEME: 'true'
      },
      auto_update: true                                      # Whether to auto-update when image tag changes
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
      repo_url: 'git@github.com:contraptionco/contraption-ghost-theme.git', # Git repo
      local_path: "#{CODE_DIR}/contraption-ghost-theme",     # Where to clone the repo
      deploy_path: "#{DATA_DIR}/ghost/themes/contraption-ghost-theme", # Where to deploy the built theme (optional)
      build_cmd: 'asdf install && /Users/philip/.asdf/shims/npm install && /Users/philip/.asdf/shims/npm run build', # Build command
      auto_update: true, # Whether to auto-update when repo changes
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
          ADMIN_CHAT_URL: { type: '1password', item: 'Bklt', field: 'ADMIN_CHAT_URL' },
          RAILS_ENV: 'production'                            # Environment setting
        },
        cmd: 'bundle exec puma -C config/puma.rb'            # Command to run in the container
      },
      auto_update: true                                      # Whether to auto-update when repo changes
    },
    {
      name: 'postcard',                                          # Service name
      repo_url: 'git@github.com:contraptionco/postcard.git',     # CHANGE THIS to your repository
      local_path: "#{CODE_DIR}/postcard",                        # Where to clone the repo
      # Environment configuration from 1Password
      env_config: { type: '1password', item: 'Postcard', field: 'env' },
      container_config: { # Container configuration after build
        image_name: 'postcard', # Docker image name to create
        ports: ['3000:3000'],                                # Port mapping (host:container)
        environment: {                                       # Environment variables
          DATABASE_URL: { type: '1password', item: 'Postcard', field: 'DATABASE_URL' },
          RAILS_MASTER_KEY: { type: '1password', item: 'Postcard', field: 'RAILS_MASTER_KEY' },
          ADMIN_CHAT_URL: { type: '1password', item: 'Postcard', field: 'ADMIN_CHAT_URL' },
          APP_MODE: 'MULTIUSER',
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
      container_config: { # Container configuration after build
        image_name: 'junk-drawer', # Docker image name to create
        ports: ['4001:3000'],                                # Port mapping (host:container)
        environment: {                                       # Environment variables
          DATABASE_URL: { type: '1password', item: 'junk-drawer', field: 'DATABASE_URL' },
          RAILS_MASTER_KEY: { type: '1password', item: 'junk-drawer', field: 'RAILS_MASTER_KEY' },
          RAILS_ENV: 'production' # Environment setting
        },
        cmd: 'bundle exec puma -C config/puma.rb'            # Command to run in the container
      },
      auto_update: true                                      # Whether to auto-update when repo changes
    },
    {
      name: 'plausible',                                     # Service name
      repo_url: 'https://github.com/plausible/community-edition', # Repo URL (public repo)
      local_path: "#{DATA_DIR}/plausible/plausible-ce",      # Where to clone the repo
      branch: 'v3.1.0',                                      # Specific branch or tag to use
      # Environment configuration from 1Password (CHANGE THIS to your 1Password item)
      env_config: { type: '1password', item: 'Plausible', field: 'env' },
      # Custom docker-compose override
      compose_override: {
        services: {
          plausible: {
            ports: ['127.0.0.1:8000:8000'] # Port mapping for the service
            # Cloudflare connects to port 8000 to serve:
            # telegraph.contraption.co
          }
        }
      },
      auto_update: false # Whether to auto-update when repo changes
    },
    {
      name: 'mcp',                                           # Service name
      repo_url: 'git@github.com:contraptionco/mcp.git',  # Git repo
      local_path: "#{CODE_DIR}/mcp",                         # Where to clone the repo
      container_config: {                                    # Container configuration after build
        image_name: 'mcp',                                   # Docker image name to create
        ports: ['8001:8000'],                                # Port mapping (host:container) - mapping 8001 to container's 8000
        environment: {                                       # Environment variables from 1Password
          CHROMA_TENANT: { type: '1password', item: 'MCP', field: 'CHROMA_TENANT' },
          CHROMA_DATABASE: { type: '1password', item: 'MCP', field: 'CHROMA_DATABASE' },
          CHROMA_API_KEY: { type: '1password', item: 'MCP', field: 'CHROMA_API_KEY' },
          CHROMA_COLLECTION: { type: '1password', item: 'MCP', field: 'CHROMA_COLLECTION' },
          GHOST_ADMIN_API_KEY: { type: '1password', item: 'MCP', field: 'GHOST_ADMIN_API_KEY' },
          GHOST_API_URL: { type: '1password', item: 'MCP', field: 'GHOST_API_URL' },
          WEBHOOK_SECRET: { type: '1password', item: 'MCP', field: 'WEBHOOK_SECRET' },
          VOYAGEAI_API_KEY: { type: '1password', item: 'MCP', field: 'VOYAGEAI_API_KEY' }
        }
      },
      auto_update: true                                      # Whether to auto-update when repo changes
    },
    {
      name: 'quesogpt',                                      # Service name
      repo_url: 'git@github.com:contraptionco/quesogpt.git', # Git repo
      local_path: "#{CODE_DIR}/quesogpt",                    # Where to clone the repo
      container_config: {                                    # Container configuration after build
        image_name: 'quesogpt',                              # Docker image name to create
        ports: ['3001:3000'],                                # Map host 3001 -> container 3000
        environment: {                                       # Environment variables from 1Password
          CHROMA_TENANT:   { type: '1password', item: 'quesogpt', field: 'CHROMA_TENANT' },
          CHROMA_DATABASE: { type: '1password', item: 'quesogpt', field: 'CHROMA_DATABASE' },
          CHROMA_API_KEY:  { type: '1password', item: 'quesogpt', field: 'CHROMA_API_KEY' },
          OPENAI_API_KEY:  { type: '1password', item: 'quesogpt', field: 'OPENAI_API_KEY' },
          CHROMA_URL:      { type: '1password', item: 'quesogpt', field: 'CHROMA_URL' }
        }
      },
      auto_update: true                                      # Whether to auto-update when repo changes
    },
    {
      name: 'fonts',                                         # Service name
      repo_url: 'git@github.com:contraptionco/fonts.git',    # Git repo
      local_path: "#{CODE_DIR}/fonts",                       # Where to clone the repo
      container_config: {                                    # Container configuration after build
        image_name: 'fonts',                                 # Docker image name to create
        ports: ['3002:80']                                   # Map host 3002 -> container 80 (nginx default)
      },
      auto_update: true                                      # Whether to auto-update when repo changes
    },
    {
      name: 'trivet',                                        # Service name
      repo_url: 'git@github.com:contraptionco/trivet.git',   # Git repo
      local_path: "#{CODE_DIR}/trivet",                      # Where to clone the repo
      container_config: {                                    # Container configuration after build
        image_name: 'trivet',                                # Docker image name to create
        ports: ['3003:3000'],                                # Map host 3003 -> container 3000 (Trivet default)
        environment: {                                       # Environment variables from 1Password
          DATABASE_URL: { type: '1password', item: 'trivet', field: 'DATABASE_URL' },
          GOOGLE_OAUTH_CLIENT_ID: { type: '1password', item: 'trivet', field: 'GOOGLE_OAUTH_CLIENT_ID' },
          GOOGLE_OAUTH_CLIENT_SECRET: { type: '1password', item: 'trivet', field: 'GOOGLE_OAUTH_CLIENT_SECRET' },
          TRIVET_SESSION_SECRET: { type: '1password', item: 'trivet', field: 'TRIVET_SESSION_SECRET' },
          TRIVET_PUBLIC_BASE_URL: { type: '1password', item: 'trivet', field: 'TRIVET_PUBLIC_BASE_URL' },
          PORT: '3000'
        }
      },
      auto_update: true                                      # Whether to auto-update when repo changes
    }
  ]

  #-----------------------------------------------------------------------------------
  # SCRIPTS - OPTIONAL AUTOMATIONS
  #-----------------------------------------------------------------------------------

  SCRIPTS = [
    {
      name: 'ghost_backup',                                  # Script name
      type: 'ruby',                                          # Script type (:ruby or :shell)
      description: 'Back up Ghost data and metadata to ghost-backup repository',
      require: 'scripts/ghost_backup',                       # Relative path to the script file
      class_name: 'Scripts::GhostBackup',                    # Runner class
      method: :run,                                          # Method to execute
      enabled: true                                          # Toggle script without removing config
    },
    {
      name: 'postgres_backup',
      type: 'ruby',
      description: 'Export Postgres databases and upload to S3',
      require: 'scripts/postgres_backup',
      class_name: 'Scripts::PostgresBackup',
      method: :run,
      enabled: true
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
