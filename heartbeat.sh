#!/usr/bin/env zsh
# LaunchAgents do not load an interactive shell environment.
export PATH="$HOME/.asdf/shims:$HOME/.asdf/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Define configurable paths with defaults
REPO_DIR="${TOOLBOX_REPO_DIR:-$HOME/code/toolbox}"
LOCK_PATH="${REPO_DIR}/.heartbeat.lock"
LOG_FILE="${TOOLBOX_HEARTBEAT_LOG:-${REPO_DIR}/heartbeat.log}"
MAX_LOG_BYTES=$((10 * 1024 * 1024))
MAX_LOG_ARCHIVES=5
LOCK_LEGACY_TIMEOUT=600
LOCK_OWNER_TIMEOUT=60
RECLAIM_TIMEOUT=60
LOCK_TOKEN="$$.$RANDOM.$(date +%s)"
RECLAIM_PATH="${LOCK_PATH}.reclaim"

process_birth() {
  ps -p "$1" -o lstart= 2>/dev/null |
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

LOCK_BIRTH="$(process_birth "$$")"

lock_record() {
  if [[ -d "$LOCK_PATH" && -f "$LOCK_PATH/pid" ]]; then
    head -n 1 "$LOCK_PATH/pid"
  elif [[ -f "$LOCK_PATH" ]]; then
    tr -d '[:space:]' < "$LOCK_PATH"
  fi
}

lock_mtime() {
  stat -f %m "$1" 2>/dev/null
}

owner_is_live() {
  local owner="$1" expected_birth="$2" current_birth

  [[ "$owner" == <-> ]] || return 1
  kill -0 "$owner" 2>/dev/null || return 1

  # Older directory locks did not record process birth time. Treat a live PID
  # conservatively; new locks compare birth time so PID reuse cannot wedge the
  # heartbeat forever after a crash or reboot.
  [[ -z "$expected_birth" ]] && return 0
  current_birth="$(process_birth "$owner")"
  [[ -n "$current_birth" && "$current_birth" == "$expected_birth" ]]
}

remove_reclaimed_lock() {
  local reclaimed_path="$1"

  if [[ -d "$reclaimed_path" ]]; then
    rm -f "$reclaimed_path/pid"
    rm -f "$reclaimed_path/owner.tmp"
    rmdir "$reclaimed_path" 2>/dev/null
  else
    rm -f "$reclaimed_path"
  fi
}

reclaim_stale_lock() {
  local expected_owner="$1" expected_token="$2" expected_birth="$3"
  local record current_owner current_token current_birth mtime age reclaimed_path

  mkdir "$RECLAIM_PATH" 2>/dev/null || return 1
  record="$(lock_record)"
  read -r current_owner current_token current_birth <<< "$record"
  if [[ "$current_owner" != "$expected_owner" ||
        "$current_token" != "$expected_token" ||
        "$current_birth" != "$expected_birth" ]]; then
    rmdir "$RECLAIM_PATH" 2>/dev/null
    return 1
  fi
  if owner_is_live "$current_owner" "$current_birth"; then
    rmdir "$RECLAIM_PATH" 2>/dev/null
    return 1
  fi
  if [[ "$current_owner" != <-> ]]; then
    mtime="$(lock_mtime "$LOCK_PATH")" || {
      rmdir "$RECLAIM_PATH" 2>/dev/null
      return 1
    }
    age=$(( $(date +%s) - mtime ))
    if (( age <= LOCK_LEGACY_TIMEOUT )); then
      rmdir "$RECLAIM_PATH" 2>/dev/null
      return 1
    fi
  fi

  reclaimed_path="${LOCK_PATH}.stale.$$.$RANDOM"
  if mv "$LOCK_PATH" "$reclaimed_path" 2>/dev/null; then
    rmdir "$RECLAIM_PATH" 2>/dev/null
    remove_reclaimed_lock "$reclaimed_path"
    return 0
  fi

  rmdir "$RECLAIM_PATH" 2>/dev/null
  return 1
}

acquire_lock() {
  local record owner token birth mtime age

  if [[ -d "$RECLAIM_PATH" ]]; then
    mtime="$(lock_mtime "$RECLAIM_PATH")" || return 1
    age=$(( $(date +%s) - mtime ))
    if (( age > RECLAIM_TIMEOUT )); then
      rmdir "$RECLAIM_PATH" 2>/dev/null || return 1
    else
      return 1
    fi
  fi
  while ! mkdir "$LOCK_PATH" 2>/dev/null; do
    [[ -e "$LOCK_PATH" ]] || continue
    record="$(lock_record)"
    read -r owner token birth <<< "$record"
    if [[ "$owner" == <-> ]]; then
      if owner_is_live "$owner" "$birth"; then
        return 1
      fi
      reclaim_stale_lock "$owner" "$token" "$birth" || return 1
      continue
    fi

    mtime="$(lock_mtime "$LOCK_PATH")" || continue
    age=$(( $(date +%s) - mtime ))
    if [[ -d "$LOCK_PATH" ]] && (( age <= LOCK_OWNER_TIMEOUT )); then
      return 1
    fi
    if (( age > LOCK_LEGACY_TIMEOUT )) || [[ -d "$LOCK_PATH" ]]; then
      reclaim_stale_lock "$owner" "$token" "$birth" || return 1
      continue
    fi

    return 1
  done

  print -r -- "$$ $LOCK_TOKEN $LOCK_BIRTH" > "$LOCK_PATH/owner.tmp"
  mv "$LOCK_PATH/owner.tmp" "$LOCK_PATH/pid"
}

if ! acquire_lock; then
  exit 0
fi

# Function to clean up lock on exit
cleanup() {
  local owner token birth

  echo "$(date): Cleaning up..."
  if [[ -d "$LOCK_PATH" && -f "$LOCK_PATH/pid" ]]; then
    read -r owner token birth < "$LOCK_PATH/pid"
  fi
  if [[ "$owner" == "$$" && "$token" == "$LOCK_TOKEN" && "$birth" == "$LOCK_BIRTH" ]]; then
    rm -f "$LOCK_PATH/pid"
    rmdir "$LOCK_PATH" 2>/dev/null
  fi
}

# Register cleanup function
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

run_heartbeat() {
  ruby "$REPO_DIR/lib/heartbeat_update.rb" "$REPO_DIR"
}

# The explicit pipeline makes logger failure observable while continuously
# rotating output, so a noisy hung run cannot exceed the configured log caps.
run_heartbeat 2>&1 | ruby "$REPO_DIR/lib/bounded_log_writer.rb" "$LOG_FILE" "$MAX_LOG_BYTES" "$MAX_LOG_ARCHIVES"
PIPE_STATUSES=("${pipestatus[@]}")
RUN_STATUS=$PIPE_STATUSES[1]
LOGGER_STATUS=$PIPE_STATUSES[2]

if (( LOGGER_STATUS != 0 )); then
  print -u2 -- "$(date): Heartbeat log writer failed with status $LOGGER_STATUS."
fi

if (( RUN_STATUS != 0 )); then
  exit "$RUN_STATUS"
fi

exit "$LOGGER_STATUS"
