#!/usr/bin/env zsh
# Load user environment
[[ -f ~/.zshrc ]] && source ~/.zshrc

# Define configurable paths with defaults
REPO_DIR="${TOOLBOX_REPO_DIR:-$HOME/code/toolbox}"
LOCK_FILE="${REPO_DIR}/.heartbeat.lock"

# Ensure lock file doesn't exist from a failed previous run
if [ -f "$LOCK_FILE" ]; then
  # Check if the lock is stale (older than 10 minutes)
  if [ $(( $(date +%s) - $(stat -f %m "$LOCK_FILE") )) -gt 600 ]; then
    echo "$(date): Removing stale lock file..."
    rm -f "$LOCK_FILE"
  else
    echo "$(date): Another instance is already running. Exiting."
    exit 0
  fi
fi

# Create lock file
touch "$LOCK_FILE"

# Function to clean up lock on exit
cleanup() {
  echo "$(date): Cleaning up..."
  rm -f "$LOCK_FILE"
}

# Register cleanup function
trap cleanup EXIT INT TERM

# Move into the repository
if ! cd "$REPO_DIR"; then
  echo "$(date): Failed to change to repository directory: $REPO_DIR"
  exit 1
fi

# Fetch the latest changes
if ! git fetch origin main; then
  echo "$(date): Failed to fetch from origin. Skipping update."
  exit 1
fi

# Check if there are new commits not in the local main branch
UPSTREAM=$(git rev-parse origin/main)
LOCAL=$(git rev-parse main)

if [ "$UPSTREAM" != "$LOCAL" ]; then
  echo "$(date): Changes detected, pulling and rebuilding..."

  if ! git pull origin main; then
    echo "$(date): Failed to pull latest changes. Aborting."
    exit 1
  fi

  if command -v asdf &> /dev/null; then
    echo "$(date): Installing dependencies via asdf..."
  asdf install
  else
    echo "$(date): asdf not found. Skipping dependency installation."
  fi

  echo "$(date): Rebuild complete."

  ruby toolbox.rb code_changed
else
  echo "$(date): No changes detected."

  ruby toolbox.rb no_changes
fi