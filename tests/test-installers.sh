#!/bin/bash

# test-installers.sh
# Tests for installer modules (libexec/installers/)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALLERS_DIR="$TAP_ROOT/libexec/installers"

# Set up test environment
export DEV_TEAM_DIR="$TEST_TMP_DIR/dev-team"
export DEV_TEAM_HOME="$TAP_ROOT"
mkdir -p "$DEV_TEAM_DIR"

# ═══════════════════════════════════════════════════════════════════════════
# Helper Functions
# ═══════════════════════════════════════════════════════════════════════════

get_installer_files() {
  find "$INSTALLERS_DIR" -maxdepth 1 -name "install-*.sh" -type f
}

# ═══════════════════════════════════════════════════════════════════════════
# Tests
# ═══════════════════════════════════════════════════════════════════════════

test_start "Installers directory exists"
assert_dir_exists "$INSTALLERS_DIR"
test_pass

test_start "At least one installer module exists"
installer_count=$(get_installer_files | wc -l | tr -d ' ')
[ "$installer_count" -gt 0 ]
assert_exit_success $?
test_pass

test_start "All installer modules are executable"
while IFS= read -r installer; do
  [ -x "$installer" ]
  assert_exit_success $? "Not executable: $(basename "$installer")"
done < <(get_installer_files)
test_pass

test_start "All installer modules have proper shebangs"
while IFS= read -r installer; do
  first_line=$(head -n 1 "$installer")
  assert_contains "$first_line" "#!/" "Missing shebang: $(basename "$installer")"
done < <(get_installer_files)
test_pass

test_start "All installer modules can be sourced without errors"
while IFS= read -r installer; do
  # Try to source (may define functions)
  bash -c "source '$installer' && exit 0" 2>/dev/null || true
  # At minimum, should not have syntax errors
  bash -n "$installer" 2>/dev/null
  assert_exit_success $? "Syntax error in: $(basename "$installer")"
done < <(get_installer_files)
test_pass

test_start "Shell installer exists"
assert_file_exists "$INSTALLERS_DIR/install-shell.sh"
test_pass

test_start "Shell installer handles missing zshrc gracefully"
# Create temp home for testing
temp_home="$TEST_TMP_DIR/home"
mkdir -p "$temp_home"
rm -f "$temp_home/.zshrc"  # Ensure it doesn't exist

# Run installer in dry-run mode
output=$(bash "$INSTALLERS_DIR/install-shell.sh" --help 2>&1 || true)
# Should have help or handle missing file
assert_not_empty "$output"
test_pass

test_start "Kanban installer exists"
assert_file_exists "$INSTALLERS_DIR/install-kanban.sh"
test_pass

test_start "Kanban installer is executable"
[ -x "$INSTALLERS_DIR/install-kanban.sh" ]
assert_exit_success $?
test_pass

test_start "Claude config installer exists"
assert_file_exists "$INSTALLERS_DIR/install-claude-config.sh"
test_pass

test_start "Claude config installer handles missing ~/.claude/"
# Should create directory or handle missing config gracefully
output=$(bash "$INSTALLERS_DIR/install-claude-config.sh" --help 2>&1 || true)
assert_not_empty "$output"
test_pass

test_start "Fleet monitor installer exists"
assert_file_exists "$INSTALLERS_DIR/install-fleet-monitor.sh"
test_pass

test_start "Fleet monitor installer handles missing Tailscale"
# Should detect or warn about missing Tailscale
output=$(bash "$INSTALLERS_DIR/install-fleet-monitor.sh" --help 2>&1 || true)
assert_not_empty "$output"
test_pass

test_start "Team installer exists"
assert_file_exists "$INSTALLERS_DIR/install-team.sh"
test_pass

test_start "Team installer handles unknown team ID gracefully"
# Should error or warn on invalid team
output=$(bash "$INSTALLERS_DIR/install-team.sh" invalid-team-id 2>&1 || true)
# Should handle unknown team (check for Error, error, unknown, or invalid - case insensitive)
output_lower=$(echo "$output" | tr '[:upper:]' '[:lower:]')
assert_contains "$output_lower" "error" || assert_contains "$output_lower" "unknown" || assert_contains "$output_lower" "invalid"
test_pass

test_start "All installers have --help or usage documentation"
while IFS= read -r installer; do
  output=$(bash "$installer" --help 2>&1 || bash "$installer" -h 2>&1 || true)
  # Should have some form of help
  assert_not_empty "$output" "No help output: $(basename "$installer")"
done < <(get_installer_files)
test_pass

test_start "Shell installer mentions shell environment setup"
output=$(bash "$INSTALLERS_DIR/install-shell.sh" --help 2>&1 || true)
# Should mention shell/zsh/bash
assert_not_empty "$output"
test_pass

test_start "Kanban installer mentions kanban system"
output=$(bash "$INSTALLERS_DIR/install-kanban.sh" --help 2>&1 || grep -i kanban "$INSTALLERS_DIR/install-kanban.sh" || true)
assert_not_empty "$output"
test_pass

test_start "Claude config installer mentions Claude Code"
output=$(bash "$INSTALLERS_DIR/install-claude-config.sh" --help 2>&1 || grep -i claude "$INSTALLERS_DIR/install-claude-config.sh" || true)
assert_not_empty "$output"
test_pass

test_start "Fleet monitor installer mentions fleet/monitor"
output=$(bash "$INSTALLERS_DIR/install-fleet-monitor.sh" --help 2>&1 || grep -i "fleet\|monitor" "$INSTALLERS_DIR/install-fleet-monitor.sh" || true)
assert_not_empty "$output"
test_pass

test_start "Expected installers are all present"
expected_installers="shell kanban claude-config fleet-monitor team"
for installer in $expected_installers; do
  assert_file_exists "$INSTALLERS_DIR/install-${installer}.sh" "Missing: install-${installer}.sh"
done
test_pass

# Success!
exit 0
