#!/bin/zsh
# Dev-Team LCARS-Inspired Prompt
# Customizable prompt showing team, branch, and kanban status

# Skip if already running a team-specific prompt
# Team zshrc files will override this with their own prompts
if [ -n "$SESSION_TYPE" ]; then
    # Already in a team terminal, don't override
    return 0
fi

#──────────────────────────────────────────────────────────────────────────────
# Color Definitions
#──────────────────────────────────────────────────────────────────────────────

# Common colors
BLACK='%F{black}'
WHITE='%F{white}'
GRAY='%F{245}'
YELLOW='%F{yellow}'
CYAN='%F{cyan}'
GREEN='%F{green}'
RED='%F{red}'
MAGENTA='%F{magenta}'
BLUE='%F{blue}'
BOLD='%B'
RESET='%f%b'

# Division colors (Starfleet-inspired)
COMMAND_RED='%F{160}'        # Command division
OPS_GOLD='%F{178}'           # Operations division
SCIENCES_BLUE='%F{33}'       # Sciences division

# Default to Operations Gold
THEME_COLOR="${DEV_TEAM_COLOR:-$OPS_GOLD}"
THEME_HIGHLIGHT="${DEV_TEAM_HIGHLIGHT:-$YELLOW}"

#──────────────────────────────────────────────────────────────────────────────
# Prompt Components
#──────────────────────────────────────────────────────────────────────────────

# Enable command substitution in prompt
setopt PROMPT_SUBST

# Git branch function
parse_git_branch() {
    git branch 2> /dev/null | sed -e '/^[^*]/d' -e 's/* \(.*\)/(\1)/'
}

# Worktree indicator
show_worktree() {
    if [ -n "$CURRENT_WORKTREE" ]; then
        echo "🌿${CURRENT_WORKTREE}"
    else
        echo "📂main"
    fi
}

# Team indicator
show_team() {
    if [ -n "$DEV_TEAM_NAME" ]; then
        echo "$DEV_TEAM_NAME"
    else
        echo "GENERAL"
    fi
}

# Stardate (optional - only if enabled)
show_stardate() {
    if [ "$DEV_TEAM_STARDATE" = "true" ]; then
        # Calculate stardate (simplified formula)
        # Real stardate would be more complex, this is just for fun
        local year=$(date +%Y)
        local day_of_year=$(date +%j)
        local stardate=$((($year - 2000) * 1000 + $day_of_year))
        echo "[⭐$stardate]"
    fi
}

#──────────────────────────────────────────────────────────────────────────────
# Prompt Construction
#──────────────────────────────────────────────────────────────────────────────

# Two-line LCARS-style prompt
# Line 1: Team, worktree, user@host, path, git branch, stardate
# Line 2: Input indicator

PROMPT='${THEME_COLOR}┌─[${WHITE}${BOLD}$(show_team)${RESET}${THEME_COLOR}]─[${GREEN}$(show_worktree)${THEME_COLOR}]─[${YELLOW}%n${THEME_COLOR}@${CYAN}%m${THEME_COLOR}]─[${WHITE}%~${THEME_COLOR}]${YELLOW}$(parse_git_branch)${GRAY}$(show_stardate)${RESET}
${THEME_COLOR}└─➤${RESET} '

# Right-side prompt (optional status indicators)
RPROMPT=''

#──────────────────────────────────────────────────────────────────────────────
# Customization Examples
#──────────────────────────────────────────────────────────────────────────────

# To customize your prompt, export these variables in your secrets.env:
#
# # Set team name
# export DEV_TEAM_NAME="iOS"
#
# # Set division color
# export DEV_TEAM_COLOR='%F{160}'      # Command Red
# export DEV_TEAM_HIGHLIGHT='%F{196}'  # Bright Red
#
# # Enable stardate display
# export DEV_TEAM_STARDATE=true
#
# Available colors:
#   Command:    %F{160} (red)
#   Operations: %F{178} (gold)
#   Sciences:   %F{33}  (blue)
#   Custom:     %F{NNN} where NNN is 0-255
#
# See: https://upload.wikimedia.org/wikipedia/commons/1/15/Xterm_256color_chart.svg
