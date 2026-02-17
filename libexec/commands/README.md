# Dev-Team Lifecycle Commands

This directory contains the complete lifecycle management commands for dev-team.

## Commands

### `dev-team-doctor.sh`
**Purpose:** Comprehensive health check and diagnostics

**Features:**
- Checks external dependencies (Python, Node, jq, gh, git, iTerm2, Claude Code)
- Verifies framework installation integrity
- Validates configuration files
- Checks running services (LCARS, Fleet Monitor)
- Verifies LaunchAgent status
- Checks git repository health
- Tests network connectivity (including Tailscale)
- Monitors disk space

**Options:**
- `--verbose` - Detailed diagnostic output
- `--fix` - Auto-fix common issues
- `--check <component>` - Check specific component only

**Exit Codes:**
- 0 - All checks passed
- 1 - Warnings detected (should work)
- 2 - Failures detected (may not work)

---

### `dev-team-upgrade.sh`
**Purpose:** Update dev-team components to latest version

**What Gets Updated:**
- Homebrew formula (if newer available)
- Template files (re-processed)
- LCARS UI files
- Shell aliases and helpers
- Skills (symlinks verified or re-copied)
- LaunchAgents (if changed)

**What Gets Preserved:**
- User customizations
- Kanban board data
- Team configurations
- secrets.env

**Options:**
- `--dry-run` - Preview changes without applying
- `--force` - Force upgrade even if current

---

### `dev-team-uninstall.sh`
**Purpose:** Clean removal of dev-team environment

**What Gets Removed:**
- zshrc integration
- LaunchAgents
- Running services
- Installed files in working directory
- Claude Code config additions

**What Can Be Preserved:**
- Kanban board data (with `--keep-data`)
- secrets.env (interactive prompt)

**Options:**
- `--keep-data` - Preserve kanban data
- `--purge` - Remove absolutely everything
- `--yes` - Skip confirmation prompts

**Note:** Does NOT uninstall Homebrew formula. After running this, execute:
```bash
brew uninstall dev-team
```

---

### `dev-team-status.sh`
**Purpose:** Display current environment status

**Shows:**
- Machine identity (name, ID, user)
- Installed version and date
- Active teams
- Running services with ports
- Active worktrees
- Kanban board summary
- Fleet Monitor status
- Last backup timestamp
- Disk usage

**Output Formats:**
- Default: LCARS-styled full display
- `--json`: Machine-readable JSON
- `--brief`: One-line summary

**Examples:**
```bash
dev-team status               # Full display
dev-team status --brief       # One-line: "Dev-Team 1.0.0 | MyMachine | 5/12 tasks | Status: OK"
dev-team status --json        # JSON output
```

---

### `dev-team-start.sh`
**Purpose:** Start dev-team services

**Services:**
- `all` - Start all services (default)
- `lcars` / `kanban` - LCARS Kanban server only
- `fleet` - Fleet Monitor only
- `agents` - Load LaunchAgents

**Options:**
- `--open` - Open LCARS dashboard in browser

**Examples:**
```bash
dev-team start                # Start everything
dev-team start lcars          # Start LCARS only
dev-team start --open         # Start and open browser
```

---

### `dev-team-stop.sh`
**Purpose:** Stop dev-team services

**Services:**
- `all` - Stop all services (default)
- `lcars` / `kanban` - LCARS only
- `fleet` - Fleet Monitor only
- `agents` - Unload LaunchAgents

**Options:**
- `--persist` - Keep LaunchAgents loaded

**Examples:**
```bash
dev-team stop                 # Stop everything
dev-team stop lcars           # Stop LCARS only
dev-team stop --persist       # Stop but keep agents loaded
```

---

### `dev-team-migrate-check.sh`
**Purpose:** Pre-migration analysis for existing installations

**What It Does:**
- Detects existing manual installation at ~/dev-team (or custom path)
- Identifies installed components (kanban, agents, teams, services)
- Checks for uncommitted git changes
- Analyzes configuration files
- Calculates risk score
- Estimates migration time and disk space needed
- Provides migration recommendation (safe/review/fix issues)

**Analysis Areas:**
- Git repository status and worktrees
- Kanban data and backups
- Configuration files (secrets, machine, teams)
- Claude agent configurations
- Team directories and personas
- Running services (LCARS, Fleet Monitor)
- LaunchAgent status
- Shell integration
- Disk space requirements

**Exit Codes:**
- 0 - Safe to migrate (low risk)
- 1 - Issues found (review recommended, medium risk)
- 2 - Critical issues (not recommended, high risk)
- 3 - Invalid installation or not found

**Options:**
- `--dir <path>` - Path to existing installation (default: ~/dev-team)
- `--verbose` - Show detailed analysis

**Examples:**
```bash
dev-team migrate --check                    # Check default location
dev-team migrate --check --verbose          # Detailed analysis
dev-team migrate --check --dir ~/old        # Check custom location
```

**Typical Output:**
```
✓ Git repository detected
✓ Kanban boards found: 5
✓ Plan documents found: 23
✓ Claude settings.json found
✓ Agent configurations found: 9
⚠ Uncommitted changes detected
✓ Risk Level: LOW (8 points)
✓ SAFE TO MIGRATE
```

---

### `dev-team-migrate.sh`
**Purpose:** Migrate existing manual installation to Homebrew-managed structure

**CRITICAL:** This script handles user data migration. Data loss is unacceptable. Every step is reversible.

**What It Migrates:**
- Kanban boards and plan documents → `~/.dev-team/kanban/`
- Kanban backups → `~/.dev-team/kanban-backups/`
- Configuration files → `~/.dev-team/config/`
- Claude agent configs → `~/.dev-team/claude/`
- Team data directories → `~/.dev-team/teams/`
- Fleet Monitor data → `~/.dev-team/fleet-monitor/`

**What It Updates:**
- LaunchAgent plists (path updates)
- Shell integration (~/.zshrc sourcing pattern)
- Configuration file paths

**What It Does NOT Touch:**
- Git repository structure (preserved as-is)
- Original ~/dev-team directory (left intact for user to delete after verification)
- Framework files (replaced by Homebrew installation)

**Migration Phases:**
1. **Pre-Migration Checks** - Runs `dev-team migrate --check` automatically
2. **Backup Phase** - Full backup to `~/.dev-team/migration-backups/TIMESTAMP/`
3. **Migration Phase** - Copies user data to new locations
4. **Update Phase** - Updates paths in configs and LaunchAgents
5. **Validation Phase** - Runs `dev-team doctor` to verify

**Safety Features:**
- Full backup created before any changes
- Backup integrity verification (file count comparison)
- Dry run mode (preview without changes)
- Rollback support (restore from backup)
- Original installation preserved (never deleted)
- Complete migration log (~/.dev-team/migration.log)
- Idempotent (can run multiple times safely)

**Options:**
- `--dry-run` - Preview migration without making changes
- `--skip-backup` - Skip backup creation (DANGEROUS - not recommended)
- `--skip-validation` - Skip post-migration validation
- `--force` - Force migration even with warnings
- `--rollback` - Rollback to most recent migration backup
- `--rollback-from <dir>` - Rollback from specific backup
- `--old-dir <path>` - Custom source installation path
- `--new-dir <path>` - Custom destination data path

**Examples:**
```bash
# Standard migration workflow
dev-team migrate --check                    # Analyze first
dev-team migrate --dry-run                  # Preview changes
dev-team migrate                            # Perform migration

# Advanced usage
dev-team migrate --old-dir ~/old-location   # Custom source
dev-team migrate --force                    # Ignore warnings

# Rollback if needed
dev-team migrate --rollback                 # Undo migration
```

**Exit Codes:**
- 0 - Migration successful
- 1 - Migration failed (check logs)
- 2 - Pre-migration check failed
- 3 - Rollback successful

**Post-Migration Steps:**
1. Restart terminal (new shell integration)
2. Run `dev-team doctor` (verify installation)
3. Run `dev-team start` (start services)
4. Verify kanban boards accessible
5. Test agent workflows
6. Only then, manually delete ~/dev-team if desired

**Architecture Change:**

Before (Manual):
```
~/dev-team/                  (everything mixed together)
  kanban/                    (user data)
  kanban-helpers.sh          (framework code)
  academy-startup.sh         (framework code)
  lcars-ui/                  (framework code)
```

After (Homebrew):
```
/opt/homebrew/opt/dev-team/  (framework - Homebrew-managed)
  libexec/commands/
  libexec/lib/
  share/templates/

~/.dev-team/                 (user data - persists across updates)
  kanban/
  config/
  claude/
  teams/
```

**Benefits:**
- Framework updates via `brew upgrade dev-team`
- User data preserved across updates
- Clean separation of framework vs user data
- Easier multi-machine setup
- Rollback support

---

## Shared Libraries

### `../lib/config.sh`
Configuration loader and helpers:
- `is_configured()` - Check if dev-team is configured
- `get_config_value <key>` - Read config value
- `get_installed_version()` - Get version
- `get_configured_teams()` - Get team list
- `validate_config()` - Validate config structure
- `get_working_dir()` - Get working directory
- `get_framework_dir()` - Get framework directory

### `../lib/wizard-ui.sh`
LCARS-styled UI helpers:
- `print_success()`, `print_error()`, `print_warning()`, `print_info()`
- `print_header()`, `print_section()`
- `prompt_yes_no()`, `prompt_text()`, `prompt_select()`
- Color constants for LCARS styling

---

## CLI Integration

Commands are invoked via the main CLI dispatcher at `bin/dev-team-cli.sh`:

```bash
dev-team doctor              # Health check
dev-team status              # Show status
dev-team upgrade             # Upgrade
dev-team uninstall           # Remove
dev-team start [service]     # Start services
dev-team stop [service]      # Stop services
dev-team restart             # Restart all
```

All lifecycle commands are located in the framework (`${DEV_TEAM_HOME}/libexec/commands/`) rather than the working directory, ensuring they're always available and versioned with the framework.

---

## Design Principles

1. **Fast** - Commands don't do expensive operations without explicit flags
2. **Informative** - Clear, LCARS-styled output
3. **Safe** - Confirmations for destructive operations
4. **Consistent** - All use shared UI library and exit codes
5. **Standalone** - Commands work independently and via CLI
6. **Maintainable** - Simple, readable code with clear structure

---

**Author:** Commander Jett Reno, Academy Team
**Date:** 2026-02-17
**Version:** 1.0.0
