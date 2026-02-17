#!/bin/bash
# config.sh
# Shared configuration loader for dev-team lifecycle commands
# Provides helpers to read and validate config.json

# Config file location
get_config_file() {
  local dev_team_dir="${DEV_TEAM_DIR:-$HOME/dev-team}"
  echo "${dev_team_dir}/.dev-team-config"
}

# Check if dev-team is configured
is_configured() {
  local config_file
  config_file=$(get_config_file)
  [ -f "$config_file" ]
}

# Read config value
# Usage: get_config_value <key>
get_config_value() {
  local key="$1"
  local config_file
  config_file=$(get_config_file)

  if [ ! -f "$config_file" ]; then
    return 1
  fi

  if command -v jq &>/dev/null; then
    jq -r ".${key} // empty" "$config_file" 2>/dev/null
  else
    # Fallback if jq not available
    grep "\"${key}\"" "$config_file" | sed -E 's/.*"'${key}'": *"?([^",}]+)"?.*/\1/' | head -n1
  fi
}

# Get installed version
get_installed_version() {
  get_config_value "version"
}

# Get installation date
get_install_date() {
  get_config_value "installed_date"
}

# Get configured teams (returns space-separated list)
get_configured_teams() {
  local config_file
  config_file=$(get_config_file)

  if [ ! -f "$config_file" ]; then
    return 1
  fi

  if command -v jq &>/dev/null; then
    jq -r '.teams[]? // empty' "$config_file" 2>/dev/null | tr '\n' ' '
  else
    # Fallback: extract array values
    grep -A 100 '"teams"' "$config_file" | grep -v '"teams"' | grep '"' | sed 's/.*"\([^"]*\)".*/\1/' | tr '\n' ' '
  fi
}

# Get machine name
get_machine_name() {
  get_config_value "machine.name"
}

# Get machine ID
get_machine_id() {
  get_config_value "machine.id"
}

# Validate config structure
validate_config() {
  local config_file
  config_file=$(get_config_file)

  if [ ! -f "$config_file" ]; then
    echo "Config file not found: $config_file"
    return 1
  fi

  # Check if valid JSON (if jq available)
  if command -v jq &>/dev/null; then
    if ! jq empty "$config_file" 2>/dev/null; then
      echo "Invalid JSON in config file"
      return 1
    fi
  fi

  return 0
}

# Get working directory
get_working_dir() {
  echo "${DEV_TEAM_DIR:-$HOME/dev-team}"
}

# Get framework directory
get_framework_dir() {
  if [ -n "$DEV_TEAM_HOME" ]; then
    echo "$DEV_TEAM_HOME"
  elif command -v brew &>/dev/null; then
    echo "$(brew --prefix 2>/dev/null || echo '/opt/homebrew')/opt/dev-team/libexec"
  else
    echo "$HOME/dev-team-framework"
  fi
}
