#!/bin/bash
# Dev-Team CLI - Main command dispatcher
# This script routes subcommands to appropriate handlers

set -eo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get DEV_TEAM_HOME from environment or default to Homebrew location
if [ -z "$DEV_TEAM_HOME" ]; then
  # Try to detect Homebrew installation
  if command -v brew &>/dev/null; then
    DEV_TEAM_HOME="$(brew --prefix)/opt/dev-team/libexec"
  else
    echo -e "${RED}ERROR: DEV_TEAM_HOME not set and Homebrew not found${NC}" >&2
    exit 1
  fi
fi

# Get user's dev-team working directory (where actual configs/data live)
DEV_TEAM_DIR="${DEV_TEAM_DIR:-$HOME/dev-team}"

VERSION="1.0.0"

# Usage information
usage() {
  cat <<EOF
Dev-Team CLI v${VERSION}
Starfleet Development Environment

Usage: dev-team <command> [options]

Commands:
  setup       Run interactive setup wizard
  doctor      Health check and diagnostics
  status      Show current environment status
  upgrade     Upgrade dev-team components
  uninstall   Remove dev-team environment
  start       Start dev-team services
  stop        Stop dev-team services
  restart     Restart dev-team services
  version     Show version information
  help        Show this help message

Installation Locations:
  Framework:  ${DEV_TEAM_HOME}
  Working:    ${DEV_TEAM_DIR}

Examples:
  dev-team setup              # Run setup wizard
  dev-team doctor             # Check system health
  dev-team status             # Show current status
  dev-team start ios          # Start iOS team environment

For detailed help on a command:
  dev-team <command> --help
EOF
}

# Version information
version_info() {
  echo "Dev-Team v${VERSION}"
  echo "Framework: ${DEV_TEAM_HOME}"
  echo "Working Directory: ${DEV_TEAM_DIR}"
  echo ""

  # Show installation status
  if [ -f "${DEV_TEAM_DIR}/.dev-team-config" ]; then
    echo -e "${GREEN}✓${NC} Configured"
  else
    echo -e "${YELLOW}⚠${NC}  Not configured (run: dev-team setup)"
  fi
}

# Check if working directory is configured
check_configured() {
  if [ ! -f "${DEV_TEAM_DIR}/.dev-team-config" ]; then
    echo -e "${YELLOW}⚠ Dev-Team not configured${NC}" >&2
    echo "Run: dev-team setup" >&2
    exit 1
  fi
}

# Main command dispatcher
case "${1:-}" in
  setup)
    shift
    exec "${DEV_TEAM_HOME}/bin/dev-team-setup.sh" "$@"
    ;;

  doctor)
    shift
    exec "${DEV_TEAM_HOME}/libexec/commands/dev-team-doctor.sh" "$@"
    ;;

  status)
    check_configured
    shift
    exec "${DEV_TEAM_HOME}/libexec/commands/dev-team-status.sh" "$@"
    ;;

  upgrade)
    check_configured
    shift
    exec "${DEV_TEAM_HOME}/libexec/commands/dev-team-upgrade.sh" "$@"
    ;;

  uninstall)
    shift
    exec "${DEV_TEAM_HOME}/libexec/commands/dev-team-uninstall.sh" "$@"
    ;;

  start)
    check_configured
    shift
    exec "${DEV_TEAM_HOME}/libexec/commands/dev-team-start.sh" "$@"
    ;;

  stop)
    check_configured
    shift
    exec "${DEV_TEAM_HOME}/libexec/commands/dev-team-stop.sh" "$@"
    ;;

  restart)
    check_configured
    shift
    "${DEV_TEAM_HOME}/libexec/commands/dev-team-stop.sh" "$@"
    exec "${DEV_TEAM_HOME}/libexec/commands/dev-team-start.sh" "$@"
    ;;

  version|-v|--version)
    version_info
    ;;

  help|-h|--help|"")
    usage
    ;;

  *)
    echo -e "${RED}ERROR: Unknown command: $1${NC}" >&2
    echo "" >&2
    usage >&2
    exit 1
    ;;
esac
