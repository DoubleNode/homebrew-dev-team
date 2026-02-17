#!/usr/bin/env bash

# TNG-Themed Status Line for Claude Code
# Matches the exact zsh prompt structure and colors
#
# AUTOMATIC THEME DETECTION:
# This script automatically detects your terminal theme by reading ~/.claude_tng_theme
# which is written by the ios_prompt() function in ~/.zshrc
#
# Usage in terminal:
#   ios_prompt bridge        - Switch to Main Bridge (Command Red)
#   ios_prompt engineering   - Switch to Engineering (Operations Gold)
#   ios_prompt sickbay       - Switch to Sickbay (Medical Teal)
#   ios_prompt holodeck      - Switch to Holodeck (Operations Gold)
#   ios_prompt observation   - Switch to Observation Lounge (Science Teal)
#   ios_prompt stellar       - Switch to Stellar Cartography (Operations Gold)
#   ios_theme_status         - Show current theme
#
# Claude Code will automatically pick up the theme change on the next status line refresh

# Read JSON input from stdin
input=$(cat)
model=$(echo "$input" | jq -r '.model.display_name')
dir=$(echo "$input" | jq -r '.workspace.current_dir')
user=$(whoami)
hostname=$(hostname -s)
short_dir=$(basename "$dir")

# ============================================================================
# Working Item Detection
# ============================================================================
# Get the current kanban item being worked on from the board file

get_working_item() {
    local KANBAN_DIR="${HOME}/dev-team/kanban"

    # Detect team/terminal/window from tmux session
    local session_name window_name
    session_name=$(tmux display-message -p '#S' 2>/dev/null || echo "")
    window_name=$(tmux display-message -p '#W' 2>/dev/null || echo "main")

    # If not in tmux, can't determine context
    [[ -z "$session_name" ]] && return

    # Extract team and terminal from session name
    # Terminal is the last segment, team is everything before
    local terminal team
    terminal="${session_name##*-}"
    team="${session_name%-*}"

    # Build window_id (terminal:window_name)
    local window_id="${terminal}:${window_name}"

    # Determine board file from team prefix
    local board_file=""
    case "$team" in
        ios) board_file="${KANBAN_DIR}/ios-board.json" ;;
        android) board_file="${KANBAN_DIR}/android-board.json" ;;
        firebase) board_file="${KANBAN_DIR}/firebase-board.json" ;;
        command) board_file="${KANBAN_DIR}/command-board.json" ;;
        academy) board_file="${KANBAN_DIR}/academy-board.json" ;;
        dns) board_file="${KANBAN_DIR}/dns-board.json" ;;
        freelance) board_file="${KANBAN_DIR}/freelance-board.json" ;;
        freelance-doublenode-starwords) board_file="${KANBAN_DIR}/freelance-doublenode-starwords-board.json" ;;
        freelance-doublenode-workstats) board_file="${KANBAN_DIR}/freelance-doublenode-workstats-board.json" ;;
        *) return ;;  # Unknown team, no working item
    esac

    # Check board file exists
    [[ ! -f "$board_file" ]] && return

    # Method 1: Query for workingOnId from matching activeWindow
    local working_id
    working_id=$(jq -r --arg wid "$window_id" \
        '.activeWindows[] | select(.id == $wid) | .workingOnId // empty' \
        "$board_file" 2>/dev/null)

    # Method 2: Fallback - check backlog items for worktreeWindowId
    # This handles cases where the activeWindow wasn't synced but the item is assigned
    if [ -z "$working_id" ]; then
        working_id=$(jq -r --arg wid "$window_id" \
            '.backlog[] | select(.worktreeWindowId == $wid and .activelyWorking == true) | .id // empty' \
            "$board_file" 2>/dev/null | head -1)
    fi

    # Method 3: Check subitems for worktreeWindowId
    if [ -z "$working_id" ]; then
        working_id=$(jq -r --arg wid "$window_id" \
            '.backlog[].subitems[]? | select(.worktreeWindowId == $wid and .status == "in_progress") | .id // empty' \
            "$board_file" 2>/dev/null | head -1)
    fi

    echo "$working_id"
}

# Get the working item (if any)
working_item=$(get_working_item)

# Parse context window data for percentage calculation
context_size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
usage=$(echo "$input" | jq '.context_window.current_usage // null')

if [ "$usage" != "null" ]; then
    input_tokens=$(echo "$usage" | jq -r '.input_tokens // 0')
    cache_creation=$(echo "$usage" | jq -r '.cache_creation_input_tokens // 0')
    cache_read=$(echo "$usage" | jq -r '.cache_read_input_tokens // 0')
    current_tokens=$((input_tokens + cache_creation + cache_read))
    context_percent=$((current_tokens * 100 / context_size))
else
    context_percent=0
fi

# Determine context color indicator based on percentage
if [ "$context_percent" -lt 50 ]; then
    context_color="82"    # Green
    context_indicator="🟢"
elif [ "$context_percent" -lt 75 ]; then
    context_color="226"   # Yellow
    context_indicator="🟡"
else
    context_color="196"   # Red
    context_indicator="🔴"
fi

# Parse lines changed from cost data
lines_added=$(echo "$input" | jq -r '.cost.total_lines_added // 0')
lines_removed=$(echo "$input" | jq -r '.cost.total_lines_removed // 0')
lines_info="+${lines_added} -${lines_removed}"

# Get git branch and status if available
branch=$(git -C "$dir" --no-optional-locks branch --show-current 2>/dev/null || echo '')

# Get git status counts (modified and untracked files)
if [ -n "$branch" ]; then
    # Get modified files count (includes modified, added, deleted, renamed)
    modified_count=$(git -C "$dir" --no-optional-locks status --porcelain 2>/dev/null | grep -E "^[MADR ]M|^M |^A |^D |^R " | wc -l | tr -d ' ')

    # Get untracked files count
    untracked_count=$(git -C "$dir" --no-optional-locks status --porcelain 2>/dev/null | grep "^??" | wc -l | tr -d ' ')

    # Build git status string
    status_parts=""
    [ "$modified_count" -gt 0 ] && status_parts="${status_parts}±${modified_count}"
    [ "$untracked_count" -gt 0 ] && status_parts="${status_parts}+${untracked_count}"

    # Build git info with branch, file status, and session lines changed
    # Format: (branch ±files+untracked/+added -removed) with colored lines
    esc=$'\033'
    lines_colored="${esc}[38;5;82m+${lines_added} ${esc}[38;5;196m-${lines_removed}${esc}[38;5;226m"
    if [ -n "$status_parts" ]; then
        git_info="(${branch} ${status_parts}/${lines_colored})"
    else
        git_info="(${branch}/${lines_colored})"
    fi
else
    esc=$'\033'
    lines_colored="${esc}[38;5;82m+${lines_added} ${esc}[38;5;196m-${lines_removed}${esc}[38;5;226m"
    git_info="(${lines_colored})"
fi

# Function to get theme data for ALL teams
get_theme_data() {
    local theme_code="$1"

    case "$theme_code" in
        # iOS (TNG) themes
        CMD|BRIDGE)
            echo "88:88:⭐:MAIN BRIDGE"
            ;;
        ENG|ENGINEERING)
            echo "136:136:⚙️:MAIN ENGINEERING"
            ;;
        MED|SICKBAY)
            echo "37:37:⚕️:SICKBAY"
            ;;
        HOL|HOLODECK)
            echo "136:136:🎮:HOLODECK"
            ;;
        OBS|OBSERVATION)
            echo "37:37:📚:OBSERVATION LOUNGE"
            ;;
        SCI|STELLAR)
            echo "136:136:🔬:STELLAR CARTOGRAPHY"
            ;;
        # Academy (32nd Century) themes
        CHANCELLOR)
            echo "160:196:🎓:CHANCELLOR"
            ;;
        ENGINEERING)
            echo "178:184:🔧:ENGINEERING"
            ;;
        MEDICAL)
            echo "33:39:📚:MEDICAL"
            ;;
        TRAINING)
            echo "178:184:🎯:TRAINING"
            ;;
        # Command (DSC) themes
        COMMAND|ADMIRAL)
            echo "27:33:⭐:STARFLEET COMMAND"
            ;;
        OPERATIONS)
            echo "178:184:⚙️:OPERATIONS"
            ;;
        STRATEGIC)
            echo "160:196:🎯:STRATEGIC"
            ;;
        COMMUNICATIONS)
            echo "51:45:📡:COMMUNICATIONS"
            ;;
        INTELLIGENCE)
            echo "240:250:🔍:INTELLIGENCE"
            ;;
        # MainEvent (VOY) themes
        VOY-COMMAND)
            echo "160:196:⭐:VOY COMMAND"
            ;;
        VOY-ENGINEERING)
            echo "178:184:⚙️:VOY ENGINEERING"
            ;;
        VOY-SCIENCE)
            echo "27:33:🔬:ASTROMETRICS"
            ;;
        VOY-SICKBAY)
            echo "37:45:⚕️:VOY SICKBAY"
            ;;
        VOY-TACTICAL)
            echo "178:184:🎯:VOY TACTICAL"
            ;;
        VOY-COMMS)
            echo "51:45:📡:VOY COMMS"
            ;;
        VOY-HELM)
            echo "178:184:🚀:VOY HELM"
            ;;
        # DNS Framework (Lower Decks) themes
        LD-COMMAND)
            echo "178:184:⭐:LD COMMAND"
            ;;
        LD-BUGBAY)
            echo "37:45:⚕️:BUG BAY"
            ;;
        LD-TESTING)
            echo "178:184:🛡️:TESTING"
            ;;
        LD-BUILD)
            echo "178:184:⚙️:BUILD"
            ;;
        LD-REFACTOR)
            echo "27:33:🔬:REFACTOR"
            ;;
        LD-APIDESIGN)
            echo "27:33:📐:API DESIGN"
            ;;
        LD-DOCS)
            echo "178:184:📚:DOCS"
            ;;
        # Firebase (DS9) themes
        OPS)
            echo "27:33:🔥:OPS CENTER"
            ;;
        # Android (TOS) themes
        TOS-BRIDGE)
            echo "220:226:⭐:TOS BRIDGE"
            ;;
        # Freelance (ENT) themes - Enterprise NX-01
        ENT-CMD|ENT-COMMAND)
            echo "27:33:🚀:ENT COMMAND"
            ;;
        ENT-ENG|ENT-ENGINEERING)
            echo "178:184:⚙️:ENT ENGINEERING"
            ;;
        ENT-SCI|ENT-SCIENCE)
            echo "30:37:🔬:ENT SCIENCE"
            ;;
        ENT-MED|ENT-SICKBAY)
            echo "30:37:⚕️:ENT SICKBAY"
            ;;
        ENT-TAC|ENT-TACTICAL)
            echo "178:184:🎯:ENT TACTICAL"
            ;;
        ENT-COM|ENT-COMMS)
            echo "30:37:📡:ENT COMMS"
            ;;
        ENT-HLM|ENT-HELM)
            echo "178:184:🚀:ENT HELM"
            ;;
        *)
            echo "240:250:💻:SYSTEM"
            ;;
    esac
}

# Function to detect current theme
detect_theme() {
    # Method 1: Check for ALL team environment variables (highest priority)
    if [ -n "$CLAUDE_ACADEMY_THEME" ]; then
        theme_data=$(get_theme_data "$CLAUDE_ACADEMY_THEME")
        if [ "$theme_data" != "240:250:💻:SYSTEM" ]; then
            echo "$theme_data"
            return
        fi
    fi

    if [ -n "$CLAUDE_COMMAND_THEME" ]; then
        theme_data=$(get_theme_data "$CLAUDE_COMMAND_THEME")
        if [ "$theme_data" != "240:250:💻:SYSTEM" ]; then
            echo "$theme_data"
            return
        fi
    fi

    if [ -n "$CLAUDE_MAINEVENT_THEME" ]; then
        theme_data=$(get_theme_data "VOY-$CLAUDE_MAINEVENT_THEME")
        if [ "$theme_data" != "240:250:💻:SYSTEM" ]; then
            echo "$theme_data"
            return
        fi
    fi

    if [ -n "$CLAUDE_DNS_THEME" ]; then
        theme_data=$(get_theme_data "LD-$CLAUDE_DNS_THEME")
        if [ "$theme_data" != "240:250:💻:SYSTEM" ]; then
            echo "$theme_data"
            return
        fi
    fi

    if [ -n "$CLAUDE_DS9_THEME" ]; then
        theme_data=$(get_theme_data "$CLAUDE_DS9_THEME")
        if [ "$theme_data" != "240:250:💻:SYSTEM" ]; then
            echo "$theme_data"
            return
        fi
    fi

    if [ -n "$CLAUDE_TOS_THEME" ]; then
        theme_data=$(get_theme_data "TOS-$CLAUDE_TOS_THEME")
        if [ "$theme_data" != "240:250:💻:SYSTEM" ]; then
            echo "$theme_data"
            return
        fi
    fi

    if [ -n "$CLAUDE_ENT_THEME" ]; then
        theme_data=$(get_theme_data "ENT-$CLAUDE_ENT_THEME")
        if [ "$theme_data" != "240:250:💻:SYSTEM" ]; then
            echo "$theme_data"
            return
        fi
    fi

    if [ -n "$CLAUDE_TNG_THEME" ]; then
        theme_data=$(get_theme_data "$CLAUDE_TNG_THEME")
        if [ "$theme_data" != "240:250:💻:SYSTEM" ]; then
            echo "$theme_data"
            return
        fi
    fi

    # Method 2: Check for session-specific theme files (if TERM_SESSION_ID exists)
    if [ -n "$TERM_SESSION_ID" ]; then
        for theme_file in "$HOME"/.claude_*_theme_${TERM_SESSION_ID}; do
            if [ -f "$theme_file" ]; then
                saved_theme=$(cat "$theme_file" 2>/dev/null | tr -d '\n\r' | tr '[:lower:]' '[:upper:]')
                theme_data=$(get_theme_data "$saved_theme")
                if [ "$theme_data" != "240:250:💻:SYSTEM" ]; then
                    echo "$theme_data"
                    return
                fi
            fi
        done
    fi

    # Method 3: Check git branch for hints
    if [ -n "$branch" ]; then
        case "$branch" in
            *"hotfix"*|*"bugfix"*)
                echo "37:37:⚕️:SICKBAY"
                return
                ;;
            *"feature"*)
                echo "136:136:⚙️:MAIN ENGINEERING"
                return
                ;;
        esac
    fi

    # Default fallback
    echo "240:250:💻:SYSTEM"
}

# Detect and parse theme
theme_data=$(detect_theme)
border_color=$(echo "$theme_data" | cut -d':' -f1)
accent_color=$(echo "$theme_data" | cut -d':' -f2)
emoji=$(echo "$theme_data" | cut -d':' -f3)
title=$(echo "$theme_data" | cut -d':' -f4)

# Build status line for Claude Code (points up to content above)
# Format: └─[emoji TITLE]─[📌ITEM]─[user@hostname]─[path](branch ±files/+added -removed)─[model:percent%indicator]
# Uses └─ (points up) instead of ┌─ (points down) since status line is at bottom
# Context indicator: 🟢 <50%, 🟡 50-75%, 🔴 >75%
# Working item: Only shown when workingOnId is set in kanban board

# Build working item segment (only if set)
working_item_segment=""
if [ -n "$working_item" ]; then
    working_item_segment="─[📌${working_item}]"
fi

# Use $'...' syntax for proper escape sequence handling
esc=$'\033'
printf "%s" "${esc}[38;5;${border_color}m└─["\
"${esc}[1;38;5;255m${emoji} ${title}"\
"${esc}[0;38;5;${border_color}m]"\
"${esc}[38;5;51m${working_item_segment}"\
"${esc}[38;5;${border_color}m─["\
"${esc}[38;5;226m${user}"\
"${esc}[38;5;${border_color}m@"\
"${esc}[38;5;51m${hostname}"\
"${esc}[38;5;${border_color}m]─["\
"${esc}[38;5;255m${short_dir}"\
"${esc}[38;5;${border_color}m]"\
"${esc}[38;5;226m${git_info}"\
"${esc}[38;5;${border_color}m─["\
"${esc}[38;5;255m${model}"\
"${esc}[38;5;${border_color}m:"\
"${esc}[38;5;${context_color}m${context_percent}%${context_indicator}"\
"${esc}[38;5;${border_color}m]"\
"${esc}[0m"
