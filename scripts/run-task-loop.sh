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
#   - STOP_SENTINEL appears in BLOCKERS_FILE (unless RESUME_AFTER is set)
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
    _saved_STATE_FILE="${STATE_FILE:-}"
    _saved_POST_HOOK="${POST_HOOK:-}"
    _saved_POST_HOOK_FAIL_ACTION="${POST_HOOK_FAIL_ACTION:-}"
    _saved_PRE_CONTEXT="${PRE_CONTEXT:-}"

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
    [ -n "$_saved_STATE_FILE" ] && STATE_FILE="$_saved_STATE_FILE"
    [ -n "$_saved_POST_HOOK" ] && POST_HOOK="$_saved_POST_HOOK"
    [ -n "$_saved_POST_HOOK_FAIL_ACTION" ] && POST_HOOK_FAIL_ACTION="$_saved_POST_HOOK_FAIL_ACTION"
    [ -n "$_saved_PRE_CONTEXT" ] && PRE_CONTEXT="$_saved_PRE_CONTEXT"
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
STATE_FILE="${STATE_FILE:-.task-loop-state.json}"
POST_HOOK="${POST_HOOK:-}"
POST_HOOK_FAIL_ACTION="${POST_HOOK_FAIL_ACTION:-warn}"
PRE_CONTEXT="${PRE_CONTEXT:-}"

# ─── Validate required config ──────────────────────────────────────────────────
if [ -z "${TASK_NAME:-}" ]; then
    echo "ERROR: TASK_NAME is required. Set it in $CONFIG_FILE or as an env var."
    exit 1
fi

ITERATION=0
PREV_ITERATION=-1
SUMMARY_FILE="$LOG_DIR/summary.jsonl"
SUCCESS_COUNT=0
FAIL_COUNT=0
POST_HOOK_RETRIES=0
MAX_POST_HOOK_RETRIES=3

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
[ -n "$POST_HOOK" ] && echo "Post hook:      $POST_HOOK (on fail: $POST_HOOK_FAIL_ACTION)"
[ -n "$PRE_CONTEXT" ] && echo "Pre context:    $PRE_CONTEXT"
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

# Find a working timeout command (GNU coreutils: 'timeout' on Linux, 'gtimeout' on macOS)
if command -v timeout &> /dev/null; then
    TIMEOUT_CMD="timeout"
elif command -v gtimeout &> /dev/null; then
    TIMEOUT_CMD="gtimeout"
else
    echo "WARNING: Neither 'timeout' nor 'gtimeout' found. Install GNU coreutils. Running without timeout protection."
    TIMEOUT_CMD=""
fi

# ─── Summary helper ─────────────────────────────────────────────────────────────
print_summary() {
    echo ""
    echo "=== Loop Summary ==="
    echo "Total iterations: $ITERATION"
    echo "Successes:        $SUCCESS_COUNT"
    echo "Failures:         $FAIL_COUNT"
    if [ -f "$SUMMARY_FILE" ]; then
        echo "Metrics:          $SUMMARY_FILE"
    fi
}

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
        print_summary
        exit 0
    fi

    # Check for stop sentinel in blockers file
    if [ -f "$BLOCKERS_FILE" ] && grep -q "^${STOP_SENTINEL}$" "$BLOCKERS_FILE"; then
        # Check for RESUME_AFTER=<seconds> line
        RESUME_SECS=$(sed -n 's/^RESUME_AFTER=\([0-9][0-9]*\)$/\1/p' "$BLOCKERS_FILE" 2>/dev/null | head -1)
        if [ -n "$RESUME_SECS" ]; then
            echo ""
            echo "$STOP_SENTINEL found with RESUME_AFTER=${RESUME_SECS}s"
            echo "Sleeping ${RESUME_SECS}s before auto-resume..."
            sleep "$RESUME_SECS"
            # Continue to next iteration — Claude decides whether to clear the blocker
        else
            echo ""
            echo "$STOP_SENTINEL found in $BLOCKERS_FILE"
            echo "Human intervention required. Read $BLOCKERS_FILE for details."
            echo ""
            cat "$BLOCKERS_FILE"
            print_summary
            exit 0
        fi
    fi

    # Start timing after blocker sleep (so duration reflects actual work, not wait time)
    ITER_START=$(date +%s)

    # Reset post-hook retry counter only for genuinely new iterations (not retries)
    if [ "$ITERATION" -ne "$PREV_ITERATION" ]; then
        POST_HOOK_RETRIES=0
        PREV_ITERATION=$ITERATION
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

    # ─── Build the full prompt ───────────────────────────────────────────────
    PROMPT="$(cat "$PROMPT_FILE")

---

## Current Progress

$(cat "$PROGRESS_FILE")

---

## Blockers

$(cat "$BLOCKERS_FILE" 2>/dev/null || echo 'No blockers.')"

    # Inject pre-iteration context (#5)
    if [ -n "$PRE_CONTEXT" ]; then
        PRE_CONTEXT_OUTPUT=$(eval "$PRE_CONTEXT" 2>&1 || true)
        if [ -n "$PRE_CONTEXT_OUTPUT" ]; then
            PROMPT="$PROMPT

---

## Current Environment

\`\`\`
$PRE_CONTEXT_OUTPUT
\`\`\`"
        fi
    fi

    # Inject inter-iteration state (#2)
    if [ -n "$STATE_FILE" ] && [ -f "$STATE_FILE" ]; then
        STATE_CONTENTS=$(cat "$STATE_FILE" 2>/dev/null)
        if [ -n "$STATE_CONTENTS" ]; then
            PROMPT="$PROMPT

---

## State From Previous Iteration

\`\`\`json
$STATE_CONTENTS
\`\`\`

You can update this state by writing to \`$STATE_FILE\`. It will be passed to the next iteration."
        fi
    fi

    # Build system prompt append
    SYS_APPEND="You are running in HEADLESS AUTONOMOUS mode. There is NO user to interact with. Do NOT use AskUserQuestion or any interactive skill. Use Task sub-agents (subagent_type: Explore or general-purpose) for research and reasoning instead."
    if [ -n "$SYSTEM_PROMPT_APPEND" ]; then
        SYS_APPEND="$SYS_APPEND $SYSTEM_PROMPT_APPEND"
    fi

    # Run Claude
    echo "Running Claude (iteration $ITERATION)..."
    echo "  Watch progress: tail -f $LOG_FILE"
    set +eo pipefail
    if [ -n "$TIMEOUT_CMD" ]; then
        $TIMEOUT_CMD --foreground "$TIMEOUT" env -u CLAUDECODE claude \
            --dangerously-skip-permissions \
            --disable-slash-commands \
            --verbose \
            --output-format stream-json \
            --append-system-prompt "$SYS_APPEND" \
            -p "$PROMPT" \
            < /dev/null \
            > "$LOG_FILE" 2>&1
    else
        env -u CLAUDECODE claude \
            --dangerously-skip-permissions \
            --disable-slash-commands \
            --verbose \
            --output-format stream-json \
            --append-system-prompt "$SYS_APPEND" \
            -p "$PROMPT" \
            < /dev/null \
            > "$LOG_FILE" 2>&1
    fi
    CLAUDE_EXIT=$?
    set -eo pipefail

    ITER_END=$(date +%s)
    DURATION_S=$((ITER_END - ITER_START))

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

        # Log metric for rate-limited iteration
        COMMITS_AFTER=$(git rev-list --count HEAD 2>/dev/null || echo 0)
        NEW_COMMITS=$((COMMITS_AFTER - COMMITS_BEFORE))
        echo "{\"iteration\":$ITERATION,\"timestamp\":\"$TIMESTAMP\",\"duration_s\":$DURATION_S,\"exit_code\":$CLAUDE_EXIT,\"result\":\"rate_limited\",\"new_commits\":$NEW_COMMITS}" >> "$SUMMARY_FILE"
        FAIL_COUNT=$((FAIL_COUNT + 1))

        # Try to parse reset time from "resets 4pm (Europe/London)" format
        # Use sed instead of grep -P for macOS compatibility
        RESET_INFO=$(sed -n 's/.*resets \([^"]*\).*/\1/p' "$LOG_FILE" 2>/dev/null | head -1)
        RESET_TIME=$(echo "$RESET_INFO" | awk '{print $1}')
        RESET_TZ=$(echo "$RESET_INFO" | sed -n 's/.*(\([^)]*\)).*/\1/p')

        if [ -n "$RESET_TIME" ] && [ -n "$RESET_TZ" ]; then
            # GNU date uses -d, BSD/macOS date uses -j -f — try both
            RESET_EPOCH=$(TZ="$RESET_TZ" date -d "$RESET_TIME" +%s 2>/dev/null || TZ="$RESET_TZ" date -j -f "%I%p" "$RESET_TIME" +%s 2>/dev/null || echo "")
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

    # Determine result and commit count
    COMMITS_AFTER=$(git rev-list --count HEAD 2>/dev/null || echo 0)
    NEW_COMMITS=$((COMMITS_AFTER - COMMITS_BEFORE))
    ITER_RESULT="success"

    if [ "$CLAUDE_EXIT" -eq 124 ]; then
        ITER_RESULT="timeout"
    elif [ "$CLAUDE_EXIT" -ne 0 ]; then
        ITER_RESULT="error"
    elif [ "$GIT_COMMIT_CHECK" = "true" ] && [ "$NEW_COMMITS" -eq 0 ]; then
        ITER_RESULT="no_commits"
    fi

    # Check if new commits were made this iteration
    if [ "$GIT_COMMIT_CHECK" = "true" ]; then
        if [ "$NEW_COMMITS" -gt 0 ]; then
            echo "New commits this iteration: $NEW_COMMITS"
            git log --oneline -"$NEW_COMMITS"
        else
            echo "WARNING: No commits made this iteration"
        fi
    fi

    # Run post-iteration hook (#3)
    if [ -n "$POST_HOOK" ]; then
        echo ""
        echo "--- Running post hook ---"
        set +eo pipefail
        POST_HOOK_OUTPUT=$(eval "$POST_HOOK" 2>&1)
        POST_HOOK_EXIT=$?
        set -eo pipefail

        if [ "$POST_HOOK_EXIT" -ne 0 ]; then
            echo "Post hook FAILED (exit $POST_HOOK_EXIT):"
            echo "$POST_HOOK_OUTPUT"
            ITER_RESULT="hook_failed"

            case "$POST_HOOK_FAIL_ACTION" in
                retry)
                    POST_HOOK_RETRIES=$((POST_HOOK_RETRIES + 1))
                    if [ "$POST_HOOK_RETRIES" -ge "$MAX_POST_HOOK_RETRIES" ]; then
                        echo "POST_HOOK_FAIL_ACTION=retry — max retries ($MAX_POST_HOOK_RETRIES) reached, continuing"
                    else
                        echo "POST_HOOK_FAIL_ACTION=retry — will retry this iteration ($POST_HOOK_RETRIES/$MAX_POST_HOOK_RETRIES)"
                        # Log the failed attempt
                        echo "{\"iteration\":$ITERATION,\"timestamp\":\"$TIMESTAMP\",\"duration_s\":$DURATION_S,\"exit_code\":$CLAUDE_EXIT,\"result\":\"hook_failed\",\"new_commits\":$NEW_COMMITS}" >> "$SUMMARY_FILE"
                        FAIL_COUNT=$((FAIL_COUNT + 1))
                        ITERATION=$((ITERATION - 1))
                        sleep "$SLEEP_BETWEEN"
                        continue
                    fi
                    ;;
                stop)
                    echo "POST_HOOK_FAIL_ACTION=stop — halting loop"
                    echo "{\"iteration\":$ITERATION,\"timestamp\":\"$TIMESTAMP\",\"duration_s\":$DURATION_S,\"exit_code\":$CLAUDE_EXIT,\"result\":\"hook_failed\",\"new_commits\":$NEW_COMMITS}" >> "$SUMMARY_FILE"
                    FAIL_COUNT=$((FAIL_COUNT + 1))
                    print_summary
                    exit 1
                    ;;
                *)
                    echo "POST_HOOK_FAIL_ACTION=warn — continuing"
                    ;;
            esac
        else
            echo "Post hook passed"
            [ -n "$POST_HOOK_OUTPUT" ] && echo "$POST_HOOK_OUTPUT"
        fi
    fi

    # Log iteration metric (#1)
    echo "{\"iteration\":$ITERATION,\"timestamp\":\"$TIMESTAMP\",\"duration_s\":$DURATION_S,\"exit_code\":$CLAUDE_EXIT,\"result\":\"$ITER_RESULT\",\"new_commits\":$NEW_COMMITS}" >> "$SUMMARY_FILE"
    if [ "$ITER_RESULT" = "success" ]; then
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi

    # Check if completion sentinel was added during this iteration
    if grep -q "^${COMPLETION_SENTINEL}$" "$PROGRESS_FILE" 2>/dev/null; then
        echo ""
        echo "$COMPLETION_SENTINEL detected!"
        echo "All tasks complete."
        print_summary
        exit 0
    fi

    # Check if stop sentinel was added during this iteration
    if [ -f "$BLOCKERS_FILE" ] && grep -q "^${STOP_SENTINEL}$" "$BLOCKERS_FILE"; then
        # Check for RESUME_AFTER=<seconds> line
        RESUME_SECS=$(sed -n 's/^RESUME_AFTER=\([0-9][0-9]*\)$/\1/p' "$BLOCKERS_FILE" 2>/dev/null | head -1)
        if [ -n "$RESUME_SECS" ]; then
            echo ""
            echo "$STOP_SENTINEL added during iteration $ITERATION with RESUME_AFTER=${RESUME_SECS}s"
            echo "Sleeping ${RESUME_SECS}s before auto-resume..."
            sleep "$RESUME_SECS"
        else
            echo ""
            echo "$STOP_SENTINEL added during iteration $ITERATION"
            cat "$BLOCKERS_FILE"
            print_summary
            exit 0
        fi
    fi

    echo ""
    echo "Sleeping ${SLEEP_BETWEEN}s before next iteration..."
    sleep "$SLEEP_BETWEEN"
done

echo ""
echo "Completed $MAX_ITERATIONS iterations"
echo "Check $PROGRESS_FILE for current status"
print_summary
