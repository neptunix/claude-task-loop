#!/bin/bash
# Generic Autonomous Task Loop for Claude Code
# Runs Claude headlessly in a while-loop with rate limit handling,
# timeouts, git safety, and sentinel-based completion.
#
# Usage:
#   ./run-task-loop.sh                          # Run from project root (reads .task-loop.env)
#   TASK_NAME="my-task" ./run-task-loop.sh      # Override config via env vars
#   MAX_ITERATIONS=5 ./run-task-loop.sh         # Limit iterations
#
# The loop stops when:
#   - COMPLETION_SENTINEL appears in PROGRESS_FILE
#   - STOP_SENTINEL appears in BLOCKERS_FILE
#   - MAX_ITERATIONS reached

set -eo pipefail

# ─── Load config ────────────────────────────────────────────────────────────────
# Source .task-loop.env if it exists. Uses grep to extract only KEY=VALUE lines
# (no commands, no injection risk). Env vars override file values.
CONFIG_FILE="${CONFIG_FILE:-.task-loop.env}"
if [ -f "$CONFIG_FILE" ]; then
    # Save current env overrides, source config, then restore overrides
    _saved_TASK_NAME="${TASK_NAME:-}"
    _saved_PROMPT_FILE="${PROMPT_FILE:-}"
    _saved_PROGRESS_FILE="${PROGRESS_FILE:-}"
    _saved_BLOCKERS_FILE="${BLOCKERS_FILE:-}"
    _saved_COMPLETION_SENTINEL="${COMPLETION_SENTINEL:-}"
    _saved_STOP_SENTINEL="${STOP_SENTINEL:-}"
    _saved_OUTPUT_DIR="${OUTPUT_DIR:-}"
    _saved_LOG_DIR="${LOG_DIR:-}"
    _saved_MAX_ITERATIONS="${MAX_ITERATIONS:-}"
    _saved_TIMEOUT="${TIMEOUT:-}"
    _saved_SLEEP_BETWEEN="${SLEEP_BETWEEN:-}"
    _saved_GIT_STASH="${GIT_STASH:-}"
    _saved_GIT_COMMIT_CHECK="${GIT_COMMIT_CHECK:-}"
    _saved_SYSTEM_PROMPT_APPEND="${SYSTEM_PROMPT_APPEND:-}"

    source <(grep -E '^\s*[A-Z_]+=.*$' "$CONFIG_FILE")

    # Env vars take precedence over file values
    [ -n "$_saved_TASK_NAME" ] && TASK_NAME="$_saved_TASK_NAME"
    [ -n "$_saved_PROMPT_FILE" ] && PROMPT_FILE="$_saved_PROMPT_FILE"
    [ -n "$_saved_PROGRESS_FILE" ] && PROGRESS_FILE="$_saved_PROGRESS_FILE"
    [ -n "$_saved_BLOCKERS_FILE" ] && BLOCKERS_FILE="$_saved_BLOCKERS_FILE"
    [ -n "$_saved_COMPLETION_SENTINEL" ] && COMPLETION_SENTINEL="$_saved_COMPLETION_SENTINEL"
    [ -n "$_saved_STOP_SENTINEL" ] && STOP_SENTINEL="$_saved_STOP_SENTINEL"
    [ -n "$_saved_OUTPUT_DIR" ] && OUTPUT_DIR="$_saved_OUTPUT_DIR"
    [ -n "$_saved_LOG_DIR" ] && LOG_DIR="$_saved_LOG_DIR"
    [ -n "$_saved_MAX_ITERATIONS" ] && MAX_ITERATIONS="$_saved_MAX_ITERATIONS"
    [ -n "$_saved_TIMEOUT" ] && TIMEOUT="$_saved_TIMEOUT"
    [ -n "$_saved_SLEEP_BETWEEN" ] && SLEEP_BETWEEN="$_saved_SLEEP_BETWEEN"
    [ -n "$_saved_GIT_STASH" ] && GIT_STASH="$_saved_GIT_STASH"
    [ -n "$_saved_GIT_COMMIT_CHECK" ] && GIT_COMMIT_CHECK="$_saved_GIT_COMMIT_CHECK"
    [ -n "$_saved_SYSTEM_PROMPT_APPEND" ] && SYSTEM_PROMPT_APPEND="$_saved_SYSTEM_PROMPT_APPEND"
fi

# ─── Apply defaults ─────────────────────────────────────────────────────────────
PROMPT_FILE="${PROMPT_FILE:-TASK_PROMPT.md}"
PROGRESS_FILE="${PROGRESS_FILE:-TASK_PROGRESS.md}"
BLOCKERS_FILE="${BLOCKERS_FILE:-BLOCKERS.md}"
COMPLETION_SENTINEL="${COMPLETION_SENTINEL:-ALL_TASKS_COMPLETE}"
STOP_SENTINEL="${STOP_SENTINEL:-STOP}"
OUTPUT_DIR="${OUTPUT_DIR:-.}"
LOG_DIR="${LOG_DIR:-.task-logs}"
MAX_ITERATIONS="${MAX_ITERATIONS:-50}"
TIMEOUT="${TIMEOUT:-1800}"
SLEEP_BETWEEN="${SLEEP_BETWEEN:-10}"
GIT_STASH="${GIT_STASH:-true}"
GIT_COMMIT_CHECK="${GIT_COMMIT_CHECK:-true}"
SYSTEM_PROMPT_APPEND="${SYSTEM_PROMPT_APPEND:-}"

# ─── Validate required config ──────────────────────────────────────────────────
if [ -z "${TASK_NAME:-}" ]; then
    echo "ERROR: TASK_NAME is required. Set it in $CONFIG_FILE or as an env var."
    exit 1
fi

ITERATION=0

echo "=== Task Loop: $TASK_NAME ==="
echo "Prompt file:    $PROMPT_FILE"
echo "Progress file:  $PROGRESS_FILE"
echo "Blockers file:  $BLOCKERS_FILE"
echo "Output dir:     $OUTPUT_DIR"
echo "Log dir:        $LOG_DIR"
echo "Max iterations: $MAX_ITERATIONS"
echo "Timeout:        ${TIMEOUT}s"
echo "Completion:     $COMPLETION_SENTINEL"
echo "Stop:           $STOP_SENTINEL"
echo ""

# ─── Check prerequisites ────────────────────────────────────────────────────────
if ! command -v claude &> /dev/null; then
    echo "ERROR: claude CLI not found. Install it first."
    exit 1
fi

if [ ! -f "$PROMPT_FILE" ]; then
    echo "ERROR: Prompt file not found: $PROMPT_FILE"
    exit 1
fi

if [ ! -f "$PROGRESS_FILE" ]; then
    echo "ERROR: Progress file not found: $PROGRESS_FILE"
    exit 1
fi

# Ensure output and log directories exist
mkdir -p "$OUTPUT_DIR"
mkdir -p "$LOG_DIR"

# ─── Main loop ──────────────────────────────────────────────────────────────────
while [ $ITERATION -lt $MAX_ITERATIONS ]; do
    ITERATION=$((ITERATION + 1))
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    LOG_FILE="$LOG_DIR/iteration-${ITERATION}.log"

    echo "================================================"
    echo "Iteration $ITERATION / $MAX_ITERATIONS  [$TIMESTAMP]"
    echo "================================================"

    # Check for completion sentinel
    if grep -q "^${COMPLETION_SENTINEL}$" "$PROGRESS_FILE" 2>/dev/null; then
        echo ""
        echo "$COMPLETION_SENTINEL found in $PROGRESS_FILE"
        echo "All tasks complete."
        exit 0
    fi

    # Check for stop sentinel in blockers file
    if [ -f "$BLOCKERS_FILE" ] && grep -q "^${STOP_SENTINEL}$" "$BLOCKERS_FILE"; then
        echo ""
        echo "$STOP_SENTINEL found in $BLOCKERS_FILE"
        echo "Human intervention required. Read $BLOCKERS_FILE for details."
        echo ""
        cat "$BLOCKERS_FILE"
        exit 0
    fi

    # Show current progress
    echo ""
    echo "--- Current next topic ---"
    grep -n "<-- NEXT" "$PROGRESS_FILE" 2>/dev/null || echo "(no NEXT marker found)"
    echo ""

    # Git stash (safety)
    if [ "$GIT_STASH" = "true" ] && [ -n "$(git status --porcelain 2>/dev/null)" ]; then
        echo "Stashing uncommitted changes..."
        git stash push -m "task-loop-auto-stash iteration $ITERATION"
    fi

    # Record commit count before this iteration
    COMMITS_BEFORE=$(git rev-list --count HEAD 2>/dev/null || echo 0)

    # Build the full prompt
    PROMPT="$(cat "$PROMPT_FILE")

---

## Current Progress

$(cat "$PROGRESS_FILE")

---

## Blockers

$(cat "$BLOCKERS_FILE" 2>/dev/null || echo 'No blockers.')
"

    # Build system prompt append
    SYS_APPEND="You are running in HEADLESS AUTONOMOUS mode. There is NO user to interact with. Do NOT use AskUserQuestion or any interactive skill. Use Task sub-agents (subagent_type: Explore or general-purpose) for research and reasoning instead."
    if [ -n "$SYSTEM_PROMPT_APPEND" ]; then
        SYS_APPEND="$SYS_APPEND $SYSTEM_PROMPT_APPEND"
    fi

    # Run Claude
    echo "Running Claude (iteration $ITERATION)..."
    echo "  Watch progress: tail -f $LOG_FILE"
    set +eo pipefail
    timeout --foreground "$TIMEOUT" env -u CLAUDECODE claude \
        --dangerously-skip-permissions \
        --disable-slash-commands \
        --verbose \
        --output-format stream-json \
        --append-system-prompt "$SYS_APPEND" \
        -p "$PROMPT" \
        < /dev/null \
        > "$LOG_FILE" 2>&1
    CLAUDE_EXIT=$?
    set -eo pipefail

    if [ "$CLAUDE_EXIT" -eq 124 ]; then
        echo "WARNING: Iteration timed out after ${TIMEOUT}s"
    elif [ "$CLAUDE_EXIT" -ne 0 ]; then
        echo "WARNING: Claude exited with code $CLAUDE_EXIT"
    fi

    # Check for rate limit / usage exhaustion — sleep until reset, then retry.
    # NOTE: We must NOT grep the full log — stream-json output contains conversation
    # content that often mentions "rate limit" in project docs, causing false positives.
    RATE_LIMITED=false
    LAST_LINE=$(tail -1 "$LOG_FILE" 2>/dev/null)

    if [ "$CLAUDE_EXIT" -eq 0 ] && echo "$LAST_LINE" | grep -q '"subtype":\s*"success"'; then
        # Successful run — no rate limit, skip detection
        :
    elif echo "$LAST_LINE" | grep -q "out of extra usage\|quota exceeded\|usage limit"; then
        RATE_LIMITED=true
    elif [ "$CLAUDE_EXIT" -ne 0 ] && [ "$CLAUDE_EXIT" -ne 124 ]; then
        # Non-zero, non-timeout exit — check last few lines for rate limit stderr
        if tail -3 "$LOG_FILE" 2>/dev/null | grep -q "out of extra usage\|quota exceeded\|usage limit"; then
            RATE_LIMITED=true
        fi
    fi

    if [ "$RATE_LIMITED" = "true" ]; then
        echo ""
        echo "API usage limit hit."

        # Try to parse reset time from "resets 4pm (Europe/London)" format
        RESET_INFO=$(grep -oP "resets \K[^\"]*" "$LOG_FILE" 2>/dev/null | head -1)
        RESET_TIME=$(echo "$RESET_INFO" | grep -oP "^[^ ]+")
        RESET_TZ=$(echo "$RESET_INFO" | grep -oP "\(([^)]+)\)" | tr -d '()')

        if [ -n "$RESET_TIME" ] && [ -n "$RESET_TZ" ]; then
            RESET_EPOCH=$(TZ="$RESET_TZ" date -d "$RESET_TIME" +%s 2>/dev/null)
            NOW_EPOCH=$(date +%s)
            if [ -n "$RESET_EPOCH" ] && [ "$RESET_EPOCH" -gt "$NOW_EPOCH" ]; then
                WAIT_SECS=$(( RESET_EPOCH - NOW_EPOCH + 60 ))
            else
                WAIT_SECS=3600
            fi
        else
            WAIT_SECS=3600
        fi

        echo "Sleeping $(( WAIT_SECS / 60 )) minutes until usage resets..."
        sleep $WAIT_SECS

        # Retry the same iteration
        ITERATION=$((ITERATION - 1))
        continue
    fi

    # Post-iteration validation
    echo ""
    echo "--- Post-iteration validation ---"

    # Check if new commits were made this iteration
    if [ "$GIT_COMMIT_CHECK" = "true" ]; then
        COMMITS_AFTER=$(git rev-list --count HEAD 2>/dev/null || echo 0)
        NEW_COMMITS=$((COMMITS_AFTER - COMMITS_BEFORE))
        if [ "$NEW_COMMITS" -gt 0 ]; then
            echo "New commits this iteration: $NEW_COMMITS"
            git log --oneline -"$NEW_COMMITS"
        else
            echo "WARNING: No commits made this iteration"
        fi
    fi

    # Check if completion sentinel was added during this iteration
    if grep -q "^${COMPLETION_SENTINEL}$" "$PROGRESS_FILE" 2>/dev/null; then
        echo ""
        echo "$COMPLETION_SENTINEL detected!"
        echo "All tasks complete."
        exit 0
    fi

    # Check if stop sentinel was added during this iteration
    if [ -f "$BLOCKERS_FILE" ] && grep -q "^${STOP_SENTINEL}$" "$BLOCKERS_FILE"; then
        echo ""
        echo "$STOP_SENTINEL added during iteration $ITERATION"
        cat "$BLOCKERS_FILE"
        exit 0
    fi

    echo ""
    echo "Sleeping ${SLEEP_BETWEEN}s before next iteration..."
    sleep "$SLEEP_BETWEEN"
done

echo ""
echo "Completed $MAX_ITERATIONS iterations"
echo "Check $PROGRESS_FILE for current status"
