#!/bin/bash
# Dev-Team Setup Wizard
# Interactive configuration and installation

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

VERSION="1.0.0"

# Banner
show_banner() {
  cat <<'EOF'
╔═══════════════════════════════════════════════════════════════════╗
║                                                                   ║
║   ██████╗ ███████╗██╗   ██╗      ████████╗███████╗ █████╗ ███╗   ███╗   ║
║   ██╔══██╗██╔════╝██║   ██║      ╚══██╔══╝██╔════╝██╔══██╗████╗ ████║   ║
║   ██║  ██║█████╗  ██║   ██║█████╗   ██║   █████╗  ███████║██╔████╔██║   ║
║   ██║  ██║██╔══╝  ╚██╗ ██╔╝╚════╝   ██║   ██╔══╝  ██╔══██║██║╚██╔╝██║   ║
║   ██████╔╝███████╗ ╚████╔╝          ██║   ███████╗██║  ██║██║ ╚═╝ ██║   ║
║   ╚═════╝ ╚══════╝  ╚═══╝           ╚═╝   ╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝   ║
║                                                                   ║
║            Starfleet Development Environment Setup                ║
║                        Version 1.0.0                              ║
║                                                                   ║
╚═══════════════════════════════════════════════════════════════════╝
EOF
  echo ""
}

# Usage
usage() {
  cat <<EOF
Dev-Team Setup Wizard v${VERSION}

Usage: dev-team setup [options]

Options:
  --install-dir DIR      Installation directory (default: ~/dev-team)
  --upgrade              Upgrade existing installation
  --uninstall            Remove dev-team configuration
  --non-interactive      Run in non-interactive mode
  -h, --help             Show this help

Interactive Mode:
  When run without options, launches interactive setup wizard
  to configure your dev-team environment.

Examples:
  dev-team setup                          # Interactive setup
  dev-team setup --install-dir ~/my-team  # Custom location
  dev-team setup --upgrade                # Upgrade existing
  dev-team setup --uninstall              # Clean removal
EOF
}

# Parse arguments
INSTALL_DIR="$HOME/dev-team"
MODE="interactive"

while [[ $# -gt 0 ]]; do
  case $1 in
    --install-dir)
      INSTALL_DIR="$2"
      shift 2
      ;;
    --upgrade)
      MODE="upgrade"
      shift
      ;;
    --uninstall)
      MODE="uninstall"
      shift
      ;;
    --non-interactive)
      MODE="non-interactive"
      shift
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

# Check if already configured
is_configured() {
  [ -f "${INSTALL_DIR}/.dev-team-config" ]
}

# Uninstall mode
if [ "$MODE" = "uninstall" ]; then
  echo -e "${BOLD}Dev-Team Uninstall${NC}"
  echo ""

  if ! is_configured; then
    echo -e "${YELLOW}⚠ No dev-team installation found at: ${INSTALL_DIR}${NC}"
    exit 0
  fi

  echo "This will remove:"
  echo "  • Dev-team configuration from: ${INSTALL_DIR}"
  echo "  • LaunchAgents (kanban-backup, lcars-health)"
  echo "  • Shell integration from ~/.zshrc"
  echo ""
  echo -e "${RED}Warning: This will NOT remove the Homebrew formula${NC}"
  echo "To fully remove dev-team, also run: brew uninstall dev-team"
  echo ""
  read -p "Continue with uninstall? (yes/no): " confirm

  if [ "$confirm" != "yes" ]; then
    echo "Uninstall cancelled"
    exit 0
  fi

  # Remove LaunchAgents
  if [ -f "$HOME/Library/LaunchAgents/com.devteam.kanban-backup.plist" ]; then
    launchctl unload "$HOME/Library/LaunchAgents/com.devteam.kanban-backup.plist" 2>/dev/null || true
    rm "$HOME/Library/LaunchAgents/com.devteam.kanban-backup.plist"
    echo -e "${GREEN}✓${NC} Removed kanban-backup LaunchAgent"
  fi

  if [ -f "$HOME/Library/LaunchAgents/com.devteam.lcars-health.plist" ]; then
    launchctl unload "$HOME/Library/LaunchAgents/com.devteam.lcars-health.plist" 2>/dev/null || true
    rm "$HOME/Library/LaunchAgents/com.devteam.lcars-health.plist"
    echo -e "${GREEN}✓${NC} Removed lcars-health LaunchAgent"
  fi

  # Remove shell integration (backup first)
  if [ -f "$HOME/.zshrc" ]; then
    cp "$HOME/.zshrc" "$HOME/.zshrc.backup.$(date +%s)"
    # Remove dev-team sourcing lines
    grep -v "dev-team" "$HOME/.zshrc" > "$HOME/.zshrc.tmp" || true
    mv "$HOME/.zshrc.tmp" "$HOME/.zshrc"
    echo -e "${GREEN}✓${NC} Removed shell integration (backed up .zshrc)"
  fi

  # Ask about removing working directory
  echo ""
  read -p "Remove working directory ${INSTALL_DIR}? (yes/no): " remove_dir

  if [ "$remove_dir" = "yes" ]; then
    rm -rf "${INSTALL_DIR}"
    echo -e "${GREEN}✓${NC} Removed ${INSTALL_DIR}"
  else
    # Just remove config marker
    rm -f "${INSTALL_DIR}/.dev-team-config"
    echo -e "${GREEN}✓${NC} Unmarked installation (files preserved)"
  fi

  echo ""
  echo -e "${GREEN}Dev-Team uninstalled successfully${NC}"
  echo "To reinstall: dev-team setup"
  exit 0
fi

# Interactive setup
show_banner

echo -e "${CYAN}This wizard will configure your Starfleet Development Environment.${NC}"
echo ""

# Check dependencies
echo -e "${BOLD}Checking dependencies...${NC}"
echo ""

MISSING_DEPS=()

check_dep() {
  local cmd=$1
  local name=$2
  local install=$3

  if command -v "$cmd" &>/dev/null; then
    echo -e "${GREEN}✓${NC} $name"
  else
    echo -e "${RED}✗${NC} $name ${YELLOW}(missing)${NC}"
    MISSING_DEPS+=("$name:$install")
  fi
}

check_dep "python3" "Python 3" "brew install python@3.13"
check_dep "node" "Node.js" "brew install node"
check_dep "jq" "jq" "brew install jq"
check_dep "gh" "GitHub CLI" "brew install gh"
check_dep "git" "Git" "xcode-select --install"

# Check for iTerm2 (application, not command)
if [ -d "/Applications/iTerm.app" ]; then
  echo -e "${GREEN}✓${NC} iTerm2"
else
  echo -e "${RED}✗${NC} iTerm2 ${YELLOW}(missing)${NC}"
  MISSING_DEPS+=("iTerm2:brew install --cask iterm2")
fi

# Check for Claude Code
if command -v claude &>/dev/null; then
  echo -e "${GREEN}✓${NC} Claude Code"
else
  echo -e "${RED}✗${NC} Claude Code ${YELLOW}(missing)${NC}"
  MISSING_DEPS+=("Claude Code:npm install -g @anthropic-ai/claude-code")
fi

echo ""

# Handle missing dependencies
if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
  echo -e "${YELLOW}⚠ Missing required dependencies${NC}"
  echo ""
  echo "Install missing dependencies:"
  echo ""
  for dep in "${MISSING_DEPS[@]}"; do
    name="${dep%%:*}"
    install="${dep#*:}"
    echo "  $install"
  done
  echo ""
  read -p "Install missing dependencies now? (yes/no): " install_deps

  if [ "$install_deps" = "yes" ]; then
    echo ""
    echo -e "${BLUE}Installing dependencies...${NC}"
    for dep in "${MISSING_DEPS[@]}"; do
      install="${dep#*:}"
      echo "Running: $install"
      # Execute directly without eval - install commands are hardcoded in script
      bash -c "$install" || echo -e "${RED}Failed: $install${NC}"
    done
    echo ""
    echo -e "${GREEN}Dependencies installed${NC}"
    echo "Please restart the setup wizard"
    exit 0
  else
    echo ""
    echo -e "${RED}Cannot continue without required dependencies${NC}"
    exit 1
  fi
fi

# Installation directory
echo -e "${BOLD}Installation Location${NC}"
echo ""
echo "Default installation directory: ${INSTALL_DIR}"
echo ""
read -p "Use default location? (yes/no): " use_default

if [ "$use_default" != "yes" ]; then
  read -p "Enter installation directory: " custom_dir
  INSTALL_DIR="${custom_dir/#\~/$HOME}" # Expand ~
fi

echo ""
echo "Installing to: ${INSTALL_DIR}"

# Check if already exists
if is_configured; then
  echo ""
  echo -e "${YELLOW}⚠ Existing installation found${NC}"
  echo ""
  read -p "Upgrade existing installation? (yes/no): " upgrade_existing

  if [ "$upgrade_existing" != "yes" ]; then
    echo "Setup cancelled"
    exit 0
  fi
  MODE="upgrade"
fi

# Create installation directory
mkdir -p "${INSTALL_DIR}"

# ═══════════════════════════════════════════════════════════════════════════
# EXPORT VARIABLES FOR INSTALLER MODULES
# ═══════════════════════════════════════════════════════════════════════════

export DEV_TEAM_DIR="${INSTALL_DIR}"
export INSTALL_ROOT="${DEV_TEAM_HOME}"
INSTALLERS_DIR="${DEV_TEAM_HOME}/libexec/installers"
TEAMS_DIR="${DEV_TEAM_HOME}/share/teams"

# Source common utilities (used by installer modules)
source "${DEV_TEAM_HOME}/libexec/lib/common.sh"

# ═══════════════════════════════════════════════════════════════════════════
# STEP 1: MACHINE IDENTITY
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}Step 1: Machine Identity${NC}"
echo ""
echo "Give this machine a name (used for Fleet Monitor and multi-machine setups)."
echo ""

DEFAULT_MACHINE_NAME="$(hostname -s 2>/dev/null || echo "my-mac")"
read -p "Machine name [${DEFAULT_MACHINE_NAME}]: " MACHINE_NAME
MACHINE_NAME="${MACHINE_NAME:-$DEFAULT_MACHINE_NAME}"

echo ""
echo -e "${GREEN}✓${NC} Machine name: ${MACHINE_NAME}"

# ═══════════════════════════════════════════════════════════════════════════
# STEP 2: TEAM SELECTION
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}Step 2: Select Teams${NC}"
echo ""
echo "Choose which development teams to install."
echo "Each team includes agent personas, kanban board, and startup scripts."
echo ""

# Build list of available teams from .conf files
AVAILABLE_TEAMS=()
TEAM_LABELS=()

for conf_file in "${TEAMS_DIR}"/*.conf; do
  [ -f "$conf_file" ] || continue
  tid="$(basename "$conf_file" .conf)"

  # Read team name and description from conf
  tname="$(grep '^TEAM_NAME=' "$conf_file" | head -1 | cut -d'"' -f2)"
  tdesc="$(grep '^TEAM_DESCRIPTION=' "$conf_file" | head -1 | cut -d'"' -f2)"
  tcat="$(grep '^TEAM_CATEGORY=' "$conf_file" | head -1 | cut -d'"' -f2)"

  AVAILABLE_TEAMS+=("$tid")
  TEAM_LABELS+=("${tid} - ${tname} (${tdesc})")
done

# Display teams with numbers
for i in "${!TEAM_LABELS[@]}"; do
  echo "  $((i + 1))) ${TEAM_LABELS[$i]}"
done
echo ""
echo "Enter team numbers separated by spaces (e.g., '1 3 5'), or 'all' for everything."
echo ""

read -p "Teams to install: " team_choices

SELECTED_TEAMS=()
if [ "$team_choices" = "all" ]; then
  SELECTED_TEAMS=("${AVAILABLE_TEAMS[@]}")
else
  for choice in $team_choices; do
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#AVAILABLE_TEAMS[@]} ]; then
      SELECTED_TEAMS+=("${AVAILABLE_TEAMS[$((choice - 1))]}")
    else
      echo -e "${YELLOW}⚠ Skipping invalid choice: $choice${NC}"
    fi
  done
fi

if [ ${#SELECTED_TEAMS[@]} -eq 0 ]; then
  echo -e "${RED}No teams selected. At least one team is required.${NC}"
  exit 1
fi

echo ""
echo -e "${GREEN}✓${NC} Selected teams: ${SELECTED_TEAMS[*]}"

# ═══════════════════════════════════════════════════════════════════════════
# STEP 3: FEATURE SELECTION
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}Step 3: Choose Features${NC}"
echo ""

INSTALL_SHELL="no"
INSTALL_CLAUDE="no"
INSTALL_KANBAN="no"
INSTALL_FLEET="no"

# Shell Environment
echo -e "${CYAN}Shell Environment${NC} — Terminal aliases, prompts, and helpers"
read -p "  Install shell environment? (yes/no) [yes]: " ans
INSTALL_SHELL="${ans:-yes}"
echo ""

# Claude Code Configuration
echo -e "${CYAN}Claude Code Config${NC} — AI agent settings, hooks, and personas"
read -p "  Install Claude Code config? (yes/no) [yes]: " ans
INSTALL_CLAUDE="${ans:-yes}"
echo ""

# LCARS Kanban System
echo -e "${CYAN}LCARS Kanban System${NC} — Visual task management with web UI"
read -p "  Install LCARS Kanban? (yes/no) [yes]: " ans
INSTALL_KANBAN="${ans:-yes}"
echo ""

# Fleet Monitor
echo -e "${CYAN}Fleet Monitor${NC} — Multi-machine coordination (requires Tailscale for remote)"
read -p "  Install Fleet Monitor? (yes/no) [no]: " ans
INSTALL_FLEET="${ans:-no}"
echo ""

echo -e "${GREEN}✓${NC} Features selected"

# ═══════════════════════════════════════════════════════════════════════════
# STEP 4: CONFIRM & INSTALL
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}Installation Summary${NC}"
echo ""
echo "  Machine:    ${MACHINE_NAME}"
echo "  Directory:  ${INSTALL_DIR}"
echo "  Teams:      ${SELECTED_TEAMS[*]}"
echo "  Features:"
echo "    Shell Environment:   ${INSTALL_SHELL}"
echo "    Claude Code Config:  ${INSTALL_CLAUDE}"
echo "    LCARS Kanban:        ${INSTALL_KANBAN}"
echo "    Fleet Monitor:       ${INSTALL_FLEET}"
echo ""
read -p "Proceed with installation? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
  echo "Setup cancelled."
  exit 0
fi

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Beginning Installation...${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════════${NC}"
echo ""

INSTALL_ERRORS=0

# -----------------------------------------------------------------------
# Copy base framework files
# -----------------------------------------------------------------------
echo -e "${BOLD}Copying framework files...${NC}"
mkdir -p "${INSTALL_DIR}/share"
mkdir -p "${INSTALL_DIR}/docs"
mkdir -p "${INSTALL_DIR}/teams"

[ -d "${DEV_TEAM_HOME}/share/templates" ] && cp -r "${DEV_TEAM_HOME}/share/templates" "${INSTALL_DIR}/templates" 2>/dev/null && echo -e "${GREEN}✓${NC} Templates"
[ -d "${DEV_TEAM_HOME}/docs" ] && cp -r "${DEV_TEAM_HOME}/docs"/* "${INSTALL_DIR}/docs/" 2>/dev/null && echo -e "${GREEN}✓${NC} Documentation"
[ -d "${DEV_TEAM_HOME}/share/teams" ] && cp -r "${DEV_TEAM_HOME}/share/teams"/* "${INSTALL_DIR}/teams/" 2>/dev/null && echo -e "${GREEN}✓${NC} Team configurations"
echo ""

# -----------------------------------------------------------------------
# Install selected teams
# -----------------------------------------------------------------------
echo -e "${BOLD}Installing teams...${NC}"
echo ""

for team_id in "${SELECTED_TEAMS[@]}"; do
  echo -e "${BLUE}  Installing team: ${team_id}${NC}"
  if [ -x "${INSTALLERS_DIR}/install-team.sh" ]; then
    DEV_TEAM_DIR="${INSTALL_DIR}" bash "${INSTALLERS_DIR}/install-team.sh" "$team_id" --dev-team-dir "${INSTALL_DIR}" 2>&1 | sed 's/^/    /' || {
      echo -e "    ${RED}✗ Team ${team_id} had errors (continuing)${NC}"
      INSTALL_ERRORS=$((INSTALL_ERRORS + 1))
    }
  else
    # Fallback: create basic team directory structure
    mkdir -p "${INSTALL_DIR}/${team_id}"
    echo -e "    ${GREEN}✓${NC} Created ${team_id}/ directory"
  fi
  echo ""
done

# -----------------------------------------------------------------------
# Install Shell Environment
# -----------------------------------------------------------------------
if [ "$INSTALL_SHELL" = "yes" ]; then
  echo -e "${BOLD}Installing Shell Environment...${NC}"
  if [ -x "${INSTALLERS_DIR}/install-shell.sh" ]; then
    # Source installer so its functions are available, then call main function
    (
      export DEV_TEAM_DIR="${INSTALL_DIR}"
      export INSTALL_ROOT="${DEV_TEAM_HOME}"
      source "${DEV_TEAM_HOME}/libexec/lib/common.sh"
      source "${INSTALLERS_DIR}/install-shell.sh"
      install_shell_environment
    ) 2>&1 | sed 's/^/  /' || {
      echo -e "  ${RED}✗ Shell environment had errors${NC}"
      INSTALL_ERRORS=$((INSTALL_ERRORS + 1))
    }
  else
    echo -e "  ${YELLOW}⚠ Shell installer not found (skipping)${NC}"
  fi
  echo ""
fi

# -----------------------------------------------------------------------
# Install Claude Code Configuration
# -----------------------------------------------------------------------
if [ "$INSTALL_CLAUDE" = "yes" ]; then
  echo -e "${BOLD}Installing Claude Code Configuration...${NC}"
  if [ -x "${INSTALLERS_DIR}/install-claude-config.sh" ]; then
    (
      export DEV_TEAM_DIR="${INSTALL_DIR}"
      export INSTALL_ROOT="${DEV_TEAM_HOME}"
      export TEMPLATE_DIR="${DEV_TEAM_HOME}/share/templates/claude"
      bash "${INSTALLERS_DIR}/install-claude-config.sh"
    ) 2>&1 | sed 's/^/  /' || {
      echo -e "  ${RED}✗ Claude config had errors${NC}"
      INSTALL_ERRORS=$((INSTALL_ERRORS + 1))
    }
  else
    echo -e "  ${YELLOW}⚠ Claude config installer not found (skipping)${NC}"
  fi
  echo ""
fi

# -----------------------------------------------------------------------
# Install LCARS Kanban System
# -----------------------------------------------------------------------
if [ "$INSTALL_KANBAN" = "yes" ]; then
  echo -e "${BOLD}Installing LCARS Kanban System...${NC}"
  if [ -f "${INSTALLERS_DIR}/install-kanban.sh" ]; then
    (
      export DEV_TEAM_DIR="${INSTALL_DIR}"
      export INSTALL_ROOT="${DEV_TEAM_HOME}"
      source "${DEV_TEAM_HOME}/libexec/lib/common.sh"
      source "${INSTALLERS_DIR}/install-kanban.sh"
      install_kanban_system
    ) 2>&1 | sed 's/^/  /' || {
      echo -e "  ${RED}✗ Kanban system had errors${NC}"
      INSTALL_ERRORS=$((INSTALL_ERRORS + 1))
    }
  else
    echo -e "  ${YELLOW}⚠ Kanban installer not found (skipping)${NC}"
  fi
  echo ""
fi

# -----------------------------------------------------------------------
# Install Fleet Monitor
# -----------------------------------------------------------------------
if [ "$INSTALL_FLEET" = "yes" ]; then
  echo -e "${BOLD}Installing Fleet Monitor...${NC}"
  if [ -f "${INSTALLERS_DIR}/install-fleet-monitor.sh" ]; then
    (
      export DEV_TEAM_DIR="${INSTALL_DIR}"
      export INSTALL_ROOT="${DEV_TEAM_HOME}"
      export MACHINE_NAME="${MACHINE_NAME}"
      source "${DEV_TEAM_HOME}/libexec/lib/common.sh"
      source "${INSTALLERS_DIR}/install-fleet-monitor.sh"
      install_fleet_monitor
    ) 2>&1 | sed 's/^/  /' || {
      echo -e "  ${RED}✗ Fleet Monitor had errors${NC}"
      INSTALL_ERRORS=$((INSTALL_ERRORS + 1))
    }
  else
    echo -e "  ${YELLOW}⚠ Fleet Monitor installer not found (skipping)${NC}"
  fi
  echo ""
fi

# ═══════════════════════════════════════════════════════════════════════════
# WRITE CONFIGURATION FILE
# ═══════════════════════════════════════════════════════════════════════════

# Convert yes/no to JSON true/false
to_json_bool() { [ "$1" = "yes" ] && echo "true" || echo "false"; }

cat > "${INSTALL_DIR}/.dev-team-config" <<EOF
{
  "version": "${VERSION}",
  "install_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "install_dir": "${INSTALL_DIR}",
  "framework_home": "${DEV_TEAM_HOME}",
  "machine_name": "${MACHINE_NAME}",
  "teams": [$(printf '"%s",' "${SELECTED_TEAMS[@]}" | sed 's/,$//')],
  "features": {
    "shell_environment": $(to_json_bool "$INSTALL_SHELL"),
    "claude_code_config": $(to_json_bool "$INSTALL_CLAUDE"),
    "lcars_kanban": $(to_json_bool "$INSTALL_KANBAN"),
    "fleet_monitor": $(to_json_bool "$INSTALL_FLEET")
  }
}
EOF

# ═══════════════════════════════════════════════════════════════════════════
# COMPLETION
# ═══════════════════════════════════════════════════════════════════════════

echo ""
if [ "$INSTALL_ERRORS" -gt 0 ]; then
  echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${YELLOW}║           Setup Complete (with ${INSTALL_ERRORS} warnings)                      ║${NC}"
  echo -e "${YELLOW}╚═══════════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${YELLOW}Some installers reported errors. Run 'dev-team doctor' for details.${NC}"
else
  echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║                    Setup Complete!                                ║${NC}"
  echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
fi
echo ""
echo "  Machine:    ${MACHINE_NAME}"
echo "  Directory:  ${INSTALL_DIR}"
echo "  Teams:      ${SELECTED_TEAMS[*]}"
echo ""
echo "Next steps:"
echo "  1. Restart your terminal:  source ~/.zshrc"
echo "  2. Run health check:       dev-team doctor"
echo "  3. Start your environment: dev-team start"
echo ""
echo "For help: dev-team help"
echo ""
