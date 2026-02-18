#!/bin/bash
# Dev-Team Doctor - Health check and diagnostics
# Verifies installation and identifies issues

set -eo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Get framework location
if [ -z "$DEV_TEAM_HOME" ]; then
  if command -v brew &>/dev/null; then
    DEV_TEAM_HOME="$(brew --prefix)/opt/dev-team/libexec"
  else
    echo -e "${RED}ERROR: DEV_TEAM_HOME not set${NC}" >&2
    exit 1
  fi
fi

# Working directory
DEV_TEAM_DIR="${DEV_TEAM_DIR:-$HOME/dev-team}"

VERSION="1.0.0"

# Usage
usage() {
  cat <<EOF
Dev-Team Doctor v${VERSION}
Health check and diagnostics for dev-team installation

Usage: dev-team doctor [options]

Options:
  --verbose              Show detailed diagnostic information
  --fix                  Attempt to fix common issues
  --check <component>    Check specific component only
  -v, --version          Show version
  -h, --help             Show this help

Components:
  dependencies    Check external dependencies
  framework       Check framework installation
  config          Check configuration files
  services        Check running services
  permissions     Check file permissions
  all             Run all checks (default)

Examples:
  dev-team doctor                    # Run all health checks
  dev-team doctor --verbose          # Detailed diagnostics
  dev-team doctor --check services   # Check services only
  dev-team doctor --fix              # Fix common issues
EOF
}

# Parse arguments
VERBOSE=false
FIX=false
CHECK_COMPONENT="all"

while [[ $# -gt 0 ]]; do
  case $1 in
    --verbose)
      VERBOSE=true
      shift
      ;;
    --fix)
      FIX=true
      shift
      ;;
    --check)
      CHECK_COMPONENT="$2"
      shift 2
      ;;
    -v|--version)
      echo "Dev-Team Doctor v${VERSION}"
      exit 0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo -e "${RED}ERROR: Unknown option: $1${NC}" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# Counters
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
WARNING_CHECKS=0

# Check result tracker
check_result() {
  local status=$1
  local message=$2

  TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

  case $status in
    pass)
      echo -e "${GREEN}✓${NC} $message"
      PASSED_CHECKS=$((PASSED_CHECKS + 1))
      ;;
    fail)
      echo -e "${RED}✗${NC} $message"
      FAILED_CHECKS=$((FAILED_CHECKS + 1))
      ;;
    warn)
      echo -e "${YELLOW}⚠${NC} $message"
      WARNING_CHECKS=$((WARNING_CHECKS + 1))
      ;;
  esac

  if [ "$VERBOSE" = true ] && [ $# -gt 2 ]; then
    echo "    ${3}"
  fi
}

# Banner
echo ""
echo -e "${BOLD}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║           Dev-Team Doctor - Health Check                  ║${NC}"
echo -e "${BOLD}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check dependencies
check_dependencies() {
  echo -e "${CYAN}Checking external dependencies...${NC}"
  echo ""

  # Python
  if command -v python3 &>/dev/null; then
    py_version=$(python3 --version 2>&1 | awk '{print $2}')
    check_result pass "Python 3 (${py_version})"
  else
    check_result fail "Python 3 not found" "Install: brew install python@3.13"
  fi

  # Node.js
  if command -v node &>/dev/null; then
    node_version=$(node --version)
    check_result pass "Node.js (${node_version})"
  else
    check_result fail "Node.js not found" "Install: brew install node"
  fi

  # jq
  if command -v jq &>/dev/null; then
    jq_version=$(jq --version)
    check_result pass "jq (${jq_version})"
  else
    check_result fail "jq not found" "Install: brew install jq"
  fi

  # GitHub CLI
  if command -v gh &>/dev/null; then
    gh_version=$(gh --version | head -n1)
    check_result pass "GitHub CLI (${gh_version})"

    # Check if authenticated
    if gh auth status &>/dev/null; then
      check_result pass "GitHub CLI authenticated"
    else
      check_result warn "GitHub CLI not authenticated" "Run: gh auth login"
    fi
  else
    check_result fail "GitHub CLI not found" "Install: brew install gh"
  fi

  # Git
  if command -v git &>/dev/null; then
    git_version=$(git --version | awk '{print $3}')
    check_result pass "Git (${git_version})"
  else
    check_result fail "Git not found" "Install: xcode-select --install"
  fi

  # iTerm2
  if [ -d "/Applications/iTerm.app" ]; then
    check_result pass "iTerm2"
  else
    check_result fail "iTerm2 not found" "Install: brew install --cask iterm2"
  fi

  # Claude Code
  if command -v claude &>/dev/null; then
    claude_version=$(claude --version 2>&1 || echo "unknown")
    check_result pass "Claude Code (${claude_version})"

    # Check if authenticated
    if [ -f "$HOME/.config/claude/config.json" ]; then
      check_result pass "Claude Code configured"
    else
      check_result warn "Claude Code not configured" "Run: claude auth login"
    fi
  else
    check_result fail "Claude Code not found" "Install: npm install -g @anthropic-ai/claude-code"
  fi

  # Optional: Tailscale
  if command -v tailscale &>/dev/null; then
    check_result pass "Tailscale (optional)"
  else
    check_result warn "Tailscale not installed (optional)" "Install: brew install --cask tailscale"
  fi

  # Optional: ImageMagick
  if command -v convert &>/dev/null; then
    check_result pass "ImageMagick (optional)"
  else
    check_result warn "ImageMagick not installed (optional)" "Install: brew install imagemagick"
  fi

  echo ""
}

# Check framework installation
check_framework() {
  echo -e "${CYAN}Checking framework installation...${NC}"
  echo ""

  # Framework directory exists
  if [ -d "$DEV_TEAM_HOME" ]; then
    check_result pass "Framework directory: ${DEV_TEAM_HOME}"
  else
    check_result fail "Framework directory not found: ${DEV_TEAM_HOME}"
    return
  fi

  # Core templates exist in framework
  local core_templates=(
    "share/templates/kanban/kanban-helpers.template.sh"
    "share/templates/aliases/agent-aliases.sh"
    "share/templates/aliases/worktree-aliases.sh"
  )

  for tmpl in "${core_templates[@]}"; do
    local tmpl_name
    tmpl_name="$(basename "$tmpl")"
    if [ -f "${DEV_TEAM_HOME}/${tmpl}" ]; then
      check_result pass "${tmpl_name} (template)"
    else
      check_result warn "${tmpl_name} template missing"
    fi
  done

  # Core directories exist
  local core_dirs=(
    "share/templates"
    "share/teams"
    "docs"
    "libexec/commands"
    "libexec/lib"
  )

  for dir in "${core_dirs[@]}"; do
    if [ -d "${DEV_TEAM_HOME}/${dir}" ]; then
      check_result pass "${dir}/"
    else
      check_result fail "${dir}/ missing"
    fi
  done

  echo ""
}

# Check configuration
check_config() {
  echo -e "${CYAN}Checking configuration...${NC}"
  echo ""

  # Working directory exists
  if [ -d "$DEV_TEAM_DIR" ]; then
    check_result pass "Working directory: ${DEV_TEAM_DIR}"
  else
    check_result fail "Working directory not found: ${DEV_TEAM_DIR}" "Run: dev-team setup"
    return
  fi

  # Configuration marker exists
  if [ -f "${DEV_TEAM_DIR}/.dev-team-config" ]; then
    check_result pass "Configuration marker"

    # Read config
    if [ "$VERBOSE" = true ]; then
      echo "    $(cat "${DEV_TEAM_DIR}/.dev-team-config")"
    fi
  else
    check_result fail "Not configured" "Run: dev-team setup"
  fi

  # Templates directory
  if [ -d "${DEV_TEAM_DIR}/templates" ]; then
    check_result pass "Templates directory"
  else
    check_result warn "Templates directory missing"
  fi

  echo ""
}

# Check services
check_services() {
  echo -e "${CYAN}Checking services...${NC}"
  echo ""

  # LCARS Kanban server — read port from config, check root URL (no /health endpoint)
  local lcars_port=8080
  if [ -f "${DEV_TEAM_DIR}/lcars-ui/.lcars-port" ]; then
    lcars_port="$(cat "${DEV_TEAM_DIR}/lcars-ui/.lcars-port" 2>/dev/null || echo 8080)"
  fi
  if curl -s -o /dev/null -w '%{http_code}' "http://localhost:${lcars_port}/" 2>/dev/null | grep -q '200'; then
    check_result pass "LCARS Kanban server (port ${lcars_port})"
  else
    check_result warn "LCARS Kanban server not running" "Start: dev-team start lcars"
  fi

  # Fleet Monitor (if installed)
  if [ -d "${DEV_TEAM_DIR}/fleet-monitor" ]; then
    if curl -s -f http://localhost:3000/health &>/dev/null; then
      check_result pass "Fleet Monitor server"
    else
      check_result warn "Fleet Monitor server not running"
    fi
  fi

  # LaunchAgents
  if launchctl list | grep -q "com.devteam.kanban-backup"; then
    check_result pass "Kanban backup LaunchAgent"
  else
    check_result warn "Kanban backup LaunchAgent not loaded"
  fi

  if launchctl list | grep -q "com.devteam.lcars-health"; then
    check_result pass "LCARS health LaunchAgent"
  else
    check_result warn "LCARS health LaunchAgent not loaded"
  fi

  echo ""
}

# Check permissions
check_permissions() {
  echo -e "${CYAN}Checking permissions...${NC}"
  echo ""

  # Working directory writable
  if [ -w "$DEV_TEAM_DIR" ]; then
    check_result pass "Working directory writable"
  else
    check_result fail "Working directory not writable: ${DEV_TEAM_DIR}"
  fi

  # Scripts executable
  if [ -x "${DEV_TEAM_HOME}/bin/dev-team-cli.sh" ]; then
    check_result pass "CLI scripts executable"
  else
    check_result fail "CLI scripts not executable"
  fi

  echo ""
}

# Run checks based on component
case "$CHECK_COMPONENT" in
  dependencies)
    check_dependencies
    ;;
  framework)
    check_framework
    ;;
  config)
    check_config
    ;;
  services)
    check_services
    ;;
  permissions)
    check_permissions
    ;;
  all)
    check_dependencies
    check_framework
    check_config
    check_services
    check_permissions
    ;;
  *)
    echo -e "${RED}ERROR: Unknown component: ${CHECK_COMPONENT}${NC}" >&2
    usage >&2
    exit 1
    ;;
esac

# Summary
echo -e "${BOLD}Summary${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Total checks:    ${TOTAL_CHECKS}"
echo -e "Passed:          ${GREEN}${PASSED_CHECKS}${NC}"
echo -e "Warnings:        ${YELLOW}${WARNING_CHECKS}${NC}"
echo -e "Failed:          ${RED}${FAILED_CHECKS}${NC}"
echo ""

# Overall status
if [ $FAILED_CHECKS -eq 0 ]; then
  if [ $WARNING_CHECKS -eq 0 ]; then
    echo -e "${GREEN}✓ All checks passed - dev-team is healthy!${NC}"
    exit 0
  else
    echo -e "${YELLOW}⚠ Some warnings detected - dev-team should work but has minor issues${NC}"
    exit 0
  fi
else
  echo -e "${RED}✗ Some checks failed - dev-team may not function correctly${NC}"
  echo ""
  if [ "$FIX" = true ]; then
    echo "Attempting to fix issues..."
    # Placeholder for auto-fix functionality
    echo "(Auto-fix not yet implemented)"
  else
    echo "Run with --fix to attempt automatic fixes"
    echo "Or run: dev-team setup --upgrade"
  fi
  exit 1
fi
