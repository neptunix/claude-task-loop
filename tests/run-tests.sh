#!/bin/bash
# Test suite for run-task-loop.sh
# Mocks the `claude` CLI and validates all loop features.
#
# Usage: ./tests/run-tests.sh
#
# Each test runs in an isolated temp directory with a mock git repo.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_SCRIPT="$(cd "$SCRIPT_DIR/.." && pwd)/scripts/run-task-loop.sh"
PASS_COUNT=0
FAIL_COUNT=0
TESTS_RUN=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# ─── Helpers ─────────────────────────────────────────────────────────────────

setup_test_dir() {
    TEST_DIR=$(mktemp -d)
    cd "$TEST_DIR"

    # Clean env from previous tests
    unset POST_HOOK POST_HOOK_FAIL_ACTION PRE_CONTEXT CONFIG_FILE STATE_FILE 2>/dev/null || true
    unset TASK_NAME MAX_ITERATIONS TIMEOUT SLEEP_BETWEEN GIT_STASH 2>/dev/null || true

    # Create a mock git repo
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "init" > init.txt
    git add init.txt
    git commit -q -m "init"

    # Create mock claude that succeeds and makes a commit
    mkdir -p bin
    cat > bin/claude << 'MOCK_CLAUDE'
#!/bin/bash
# Mock claude — makes a commit and outputs success JSON
echo "mock work" >> work.txt
git add work.txt
git commit -q -m "mock: iteration work"
echo '{"type":"result","subtype":"success"}'
MOCK_CLAUDE
    chmod +x bin/claude
    export PATH="$TEST_DIR/bin:$PATH"

    # Create minimal config files
    echo '# Test prompt' > TASK_PROMPT.md
    cat > TASK_PROGRESS.md << 'EOF'
# Test Progress
- [ ] Task 1 <-- NEXT
- [ ] Task 2
EOF
}

cleanup_test_dir() {
    cd /
    rm -rf "$TEST_DIR"
}

run_loop() {
    # Run the loop with 1 iteration, short timeout, no sleep
    # All env vars are inherited from the caller
    export TASK_NAME="${TASK_NAME:-test}"
    export MAX_ITERATIONS="${MAX_ITERATIONS:-1}"
    export TIMEOUT="${TIMEOUT:-10}"
    export SLEEP_BETWEEN="${SLEEP_BETWEEN:-0}"
    export GIT_STASH="${GIT_STASH:-false}"
    [ -n "${POST_HOOK+x}" ] && export POST_HOOK
    [ -n "${POST_HOOK_FAIL_ACTION+x}" ] && export POST_HOOK_FAIL_ACTION
    [ -n "${PRE_CONTEXT+x}" ] && export PRE_CONTEXT
    [ -n "${CONFIG_FILE+x}" ] && export CONFIG_FILE
    "$LOOP_SCRIPT" "$@" 2>&1
}

assert_contains() {
    local output="$1"
    local expected="$2"
    local test_name="$3"
    if echo "$output" | grep -q "$expected"; then
        return 0
    else
        echo -e "${RED}FAIL:${NC} $test_name"
        echo "  Expected output to contain: $expected"
        echo "  Actual output (last 10 lines):"
        echo "$output" | tail -10 | sed 's/^/    /'
        return 1
    fi
}

assert_not_contains() {
    local output="$1"
    local unexpected="$2"
    local test_name="$3"
    if echo "$output" | grep -q "$unexpected"; then
        echo -e "${RED}FAIL:${NC} $test_name"
        echo "  Expected output NOT to contain: $unexpected"
        return 1
    else
        return 0
    fi
}

assert_file_exists() {
    local file="$1"
    local test_name="$2"
    if [ -f "$file" ]; then
        return 0
    else
        echo -e "${RED}FAIL:${NC} $test_name"
        echo "  Expected file to exist: $file"
        return 1
    fi
}

assert_file_contains() {
    local file="$1"
    local expected="$2"
    local test_name="$3"
    if [ -f "$file" ] && grep -q "$expected" "$file"; then
        return 0
    else
        echo -e "${RED}FAIL:${NC} $test_name"
        echo "  Expected $file to contain: $expected"
        [ -f "$file" ] && echo "  Actual: $(cat "$file")"
        return 1
    fi
}

run_test() {
    local test_name="$1"
    local test_fn="$2"
    TESTS_RUN=$((TESTS_RUN + 1))

    setup_test_dir
    local result=0
    $test_fn || result=$?
    cleanup_test_dir

    if [ "$result" -eq 0 ]; then
        echo -e "${GREEN}PASS:${NC} $test_name"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# ─── Test Cases ──────────────────────────────────────────────────────────────

test_basic_backward_compat() {
    # Existing config with no new features should work identically
    OUTPUT=$(run_loop)

    assert_contains "$OUTPUT" "Task Loop: test" "shows task name" || return 1
    assert_contains "$OUTPUT" "Iteration 1 / 1" "shows iteration" || return 1
    assert_contains "$OUTPUT" "New commits this iteration" "detects commits" || return 1
    assert_contains "$OUTPUT" "Loop Summary" "prints summary" || return 1
}

test_summary_jsonl_written() {
    OUTPUT=$(run_loop)

    assert_file_exists ".task-logs/summary.jsonl" "summary.jsonl created" || return 1
    assert_file_contains ".task-logs/summary.jsonl" '"result":"success"' "records success result" || return 1
    assert_file_contains ".task-logs/summary.jsonl" '"iteration":1' "records iteration number" || return 1
    assert_file_contains ".task-logs/summary.jsonl" '"new_commits":1' "records commit count" || return 1
    assert_file_contains ".task-logs/summary.jsonl" '"duration_s":' "records duration" || return 1

    # Validate it's valid JSON
    local line
    line=$(cat .task-logs/summary.jsonl)
    if ! echo "$line" | python3 -m json.tool > /dev/null 2>&1; then
        echo -e "${RED}FAIL:${NC} summary.jsonl is not valid JSON: $line"
        return 1
    fi
}

test_summary_counts_multiple_iterations() {
    MAX_ITERATIONS=3
    OUTPUT=$(run_loop)
    unset MAX_ITERATIONS

    local line_count
    line_count=$(wc -l < .task-logs/summary.jsonl | tr -d ' ')
    if [ "$line_count" -ne 3 ]; then
        echo -e "${RED}FAIL:${NC} expected 3 lines in summary.jsonl, got $line_count"
        return 1
    fi
    assert_contains "$OUTPUT" "Total iterations: 3" "summary shows 3 iterations" || return 1
}

test_state_file_injection() {
    # Create a state file
    echo '{"branch": "feature/test", "pr_number": 42}' > .task-loop-state.json

    # Replace mock claude to capture the prompt it receives
    cat > bin/claude << 'MOCK_CLAUDE'
#!/bin/bash
# Capture the prompt passed via -p
while [ $# -gt 0 ]; do
    case "$1" in
        -p) echo "$2" > /tmp/test-prompt-capture.txt; shift 2;;
        *) shift;;
    esac
done
echo "mock" >> work.txt
git add work.txt
git commit -q -m "mock"
echo '{"type":"result","subtype":"success"}'
MOCK_CLAUDE
    chmod +x bin/claude

    OUTPUT=$(run_loop)

    if [ -f /tmp/test-prompt-capture.txt ]; then
        assert_file_contains /tmp/test-prompt-capture.txt "State From Previous Iteration" "state section injected" || return 1
        assert_file_contains /tmp/test-prompt-capture.txt '"branch": "feature/test"' "state content injected" || return 1
        assert_file_contains /tmp/test-prompt-capture.txt '.task-loop-state.json' "state file path mentioned" || return 1
        rm -f /tmp/test-prompt-capture.txt
    else
        echo -e "${RED}FAIL:${NC} prompt not captured"
        return 1
    fi
}

test_state_file_not_injected_when_missing() {
    # No state file exists — should not inject
    cat > bin/claude << 'MOCK_CLAUDE'
#!/bin/bash
while [ $# -gt 0 ]; do
    case "$1" in
        -p) echo "$2" > /tmp/test-prompt-capture.txt; shift 2;;
        *) shift;;
    esac
done
echo "mock" >> work.txt
git add work.txt
git commit -q -m "mock"
echo '{"type":"result","subtype":"success"}'
MOCK_CLAUDE
    chmod +x bin/claude

    OUTPUT=$(run_loop)

    if [ -f /tmp/test-prompt-capture.txt ]; then
        assert_not_contains "$(cat /tmp/test-prompt-capture.txt)" "State From Previous Iteration" "no state section when file missing" || return 1
        rm -f /tmp/test-prompt-capture.txt
    fi
}

test_pre_context_injection() {
    cat > bin/claude << 'MOCK_CLAUDE'
#!/bin/bash
while [ $# -gt 0 ]; do
    case "$1" in
        -p) echo "$2" > /tmp/test-prompt-capture.txt; shift 2;;
        *) shift;;
    esac
done
echo "mock" >> work.txt
git add work.txt
git commit -q -m "mock"
echo '{"type":"result","subtype":"success"}'
MOCK_CLAUDE
    chmod +x bin/claude

    PRE_CONTEXT="echo 'hello from pre-context'"
    OUTPUT=$(run_loop)
    unset PRE_CONTEXT

    if [ -f /tmp/test-prompt-capture.txt ]; then
        assert_file_contains /tmp/test-prompt-capture.txt "Current Environment" "environment section injected" || return 1
        assert_file_contains /tmp/test-prompt-capture.txt "hello from pre-context" "pre-context output injected" || return 1
        rm -f /tmp/test-prompt-capture.txt
    else
        echo -e "${RED}FAIL:${NC} prompt not captured"
        return 1
    fi
}

test_post_hook_warn() {
    # Hook that fails — warn should log and continue
    POST_HOOK="exit 1"
    POST_HOOK_FAIL_ACTION="warn"
    OUTPUT=$(run_loop)
    unset POST_HOOK POST_HOOK_FAIL_ACTION

    assert_contains "$OUTPUT" "Post hook FAILED" "reports hook failure" || return 1
    assert_contains "$OUTPUT" "warn — continuing" "warns and continues" || return 1
    assert_file_contains ".task-logs/summary.jsonl" '"result":"hook_failed"' "records hook_failed result" || return 1
}

test_post_hook_stop() {
    POST_HOOK="echo 'build broken'; exit 1"
    POST_HOOK_FAIL_ACTION="stop"
    OUTPUT=$(run_loop)
    local exit_code=$?
    unset POST_HOOK POST_HOOK_FAIL_ACTION

    assert_contains "$OUTPUT" "Post hook FAILED" "reports hook failure" || return 1
    assert_contains "$OUTPUT" "stop — halting loop" "reports stop action" || return 1
    if [ "$exit_code" -ne 1 ]; then
        echo -e "${RED}FAIL:${NC} expected exit code 1, got $exit_code"
        return 1
    fi
}

test_post_hook_retry_with_limit() {
    # Hook always fails — retry should cap at MAX_POST_HOOK_RETRIES (3)
    cat > bin/claude << 'MOCK_CLAUDE'
#!/bin/bash
echo "mock" >> work.txt
git add work.txt
git commit -q -m "mock" --allow-empty
echo '{"type":"result","subtype":"success"}'
MOCK_CLAUDE
    chmod +x bin/claude

    # MAX_ITERATIONS=1 means only 1 real iteration. With 3 retries, that's 4 claude runs.
    MAX_ITERATIONS=1
    POST_HOOK="exit 1"
    POST_HOOK_FAIL_ACTION="retry"
    TIMEOUT=5
    OUTPUT=$(run_loop)
    unset POST_HOOK POST_HOOK_FAIL_ACTION MAX_ITERATIONS TIMEOUT

    # Should see retry messages and eventually hit the limit
    assert_contains "$OUTPUT" "max retries" "hits retry limit" || return 1
    assert_contains "$OUTPUT" "Loop Summary" "loop completes" || return 1
}

test_post_hook_success() {
    POST_HOOK="echo 'all good'"
    OUTPUT=$(run_loop)
    unset POST_HOOK

    assert_contains "$OUTPUT" "Post hook passed" "reports hook success" || return 1
    assert_contains "$OUTPUT" "all good" "shows hook output" || return 1
    assert_file_contains ".task-logs/summary.jsonl" '"result":"success"' "records success" || return 1
}

test_completion_sentinel() {
    # Pre-populate completion sentinel
    cat > TASK_PROGRESS.md << 'EOF'
ALL_TASKS_COMPLETE
# Done
- [x] Task 1
EOF

    OUTPUT=$(run_loop)

    assert_contains "$OUTPUT" "All tasks complete" "detects completion" || return 1
    assert_contains "$OUTPUT" "Loop Summary" "prints summary on completion" || return 1
}

test_stop_sentinel_halts() {
    cat > BLOCKERS.md << 'EOF'
STOP

Need API key
EOF

    OUTPUT=$(run_loop)

    assert_contains "$OUTPUT" "Human intervention required" "reports blocker" || return 1
    assert_contains "$OUTPUT" "Need API key" "shows blocker content" || return 1
}

test_resume_after_sleeps_and_continues() {
    # Create blockers with RESUME_AFTER — mock claude removes it on run
    cat > BLOCKERS.md << 'EOF'
STOP

Waiting for review

RESUME_AFTER=1
EOF

    # Mock claude that clears the blocker
    cat > bin/claude << 'MOCK_CLAUDE'
#!/bin/bash
# Clear the blocker on first run
echo "No blockers." > BLOCKERS.md
echo "mock" >> work.txt
git add work.txt BLOCKERS.md
git commit -q -m "mock: cleared blocker"
echo '{"type":"result","subtype":"success"}'
MOCK_CLAUDE
    chmod +x bin/claude

    MAX_ITERATIONS=2
    OUTPUT=$(run_loop)
    unset MAX_ITERATIONS

    assert_contains "$OUTPUT" "RESUME_AFTER=1s" "detects RESUME_AFTER" || return 1
    assert_contains "$OUTPUT" "Sleeping 1s before auto-resume" "sleeps correct duration" || return 1
    assert_contains "$OUTPUT" "New commits this iteration" "runs iteration after resume" || return 1
}

test_resume_after_without_number_halts() {
    # STOP without RESUME_AFTER — should halt
    cat > BLOCKERS.md << 'EOF'
STOP

Blocker without resume
EOF

    OUTPUT=$(run_loop)

    assert_contains "$OUTPUT" "Human intervention required" "halts without RESUME_AFTER" || return 1
}

test_no_commits_result() {
    # Mock claude that doesn't commit
    cat > bin/claude << 'MOCK_CLAUDE'
#!/bin/bash
echo '{"type":"result","subtype":"success"}'
MOCK_CLAUDE
    chmod +x bin/claude

    OUTPUT=$(run_loop)

    assert_contains "$OUTPUT" "WARNING: No commits made" "warns about no commits" || return 1
    assert_file_contains ".task-logs/summary.jsonl" '"result":"no_commits"' "records no_commits result" || return 1
}

test_timeout_result() {
    # Mock claude that hangs
    cat > bin/claude << 'MOCK_CLAUDE'
#!/bin/bash
sleep 30
MOCK_CLAUDE
    chmod +x bin/claude

    TIMEOUT=1
    OUTPUT=$(run_loop)
    unset TIMEOUT

    assert_contains "$OUTPUT" "timed out" "reports timeout" || return 1
    assert_file_contains ".task-logs/summary.jsonl" '"result":"timeout"' "records timeout result" || return 1
}

test_error_result() {
    # Mock claude that errors
    cat > bin/claude << 'MOCK_CLAUDE'
#!/bin/bash
exit 2
MOCK_CLAUDE
    chmod +x bin/claude

    OUTPUT=$(run_loop)

    assert_contains "$OUTPUT" "exited with code 2" "reports error exit" || return 1
    assert_file_contains ".task-logs/summary.jsonl" '"result":"error"' "records error result" || return 1
}

test_env_vars_override_config() {
    # Create a config file with one value, override with env var
    cat > .task-loop.env << 'EOF'
TASK_NAME="from-file"
MAX_ITERATIONS=99
EOF

    TASK_NAME="from-env"
    MAX_ITERATIONS=1
    CONFIG_FILE=".task-loop.env"
    OUTPUT=$(run_loop)
    unset CONFIG_FILE

    assert_contains "$OUTPUT" "Task Loop: from-env" "env var overrides config file" || return 1
    assert_contains "$OUTPUT" "Max iterations: 1" "env var overrides numeric config" || return 1
}

test_post_iteration_stop_with_resume_after() {
    # Claude adds STOP + RESUME_AFTER during the iteration, then clears it next time
    local run_count_file="$TEST_DIR/run-count"
    echo "0" > "$run_count_file"

    cat > bin/claude << MOCK_CLAUDE
#!/bin/bash
COUNT=\$(cat "$run_count_file")
COUNT=\$((COUNT + 1))
echo "\$COUNT" > "$run_count_file"
if [ "\$COUNT" -eq 1 ]; then
    # First run: add blocker with RESUME_AFTER
    cat > BLOCKERS.md << 'BLOCKER'
STOP

Waiting

RESUME_AFTER=1
BLOCKER
    git add BLOCKERS.md
    echo "work1" >> work.txt
    git add work.txt
    git commit -q -m "mock: added blocker"
elif [ "\$COUNT" -eq 2 ]; then
    # Second run: clear blocker
    echo "No blockers." > BLOCKERS.md
    git add BLOCKERS.md
    echo "work2" >> work.txt
    git add work.txt
    git commit -q -m "mock: cleared blocker"
fi
echo '{"type":"result","subtype":"success"}'
MOCK_CLAUDE
    chmod +x bin/claude

    MAX_ITERATIONS=3
    OUTPUT=$(run_loop)
    unset MAX_ITERATIONS

    assert_contains "$OUTPUT" "RESUME_AFTER=1s" "detects post-iteration RESUME_AFTER" || return 1
    assert_contains "$OUTPUT" "Iteration 2" "continues to iteration 2" || return 1
}

test_summary_jsonl_valid_json_lines() {
    MAX_ITERATIONS=3
    OUTPUT=$(run_loop)
    unset MAX_ITERATIONS

    # Every line should be valid JSON
    local line_num=0
    while IFS= read -r line; do
        line_num=$((line_num + 1))
        if ! echo "$line" | python3 -m json.tool > /dev/null 2>&1; then
            echo -e "${RED}FAIL:${NC} Line $line_num is not valid JSON: $line"
            return 1
        fi
    done < .task-logs/summary.jsonl
}

test_pre_context_failure_doesnt_crash() {
    # PRE_CONTEXT command that fails — should not crash the loop
    PRE_CONTEXT="false"
    OUTPUT=$(run_loop)
    unset PRE_CONTEXT

    assert_contains "$OUTPUT" "New commits this iteration" "loop continues after pre-context failure" || return 1
}

# ─── Run all tests ───────────────────────────────────────────────────────────

echo "=== Task Loop Test Suite ==="
echo "Script: $LOOP_SCRIPT"
echo ""

run_test "Basic backward compatibility" test_basic_backward_compat
run_test "Summary JSONL written after iteration" test_summary_jsonl_written
run_test "Summary counts multiple iterations" test_summary_counts_multiple_iterations
run_test "Summary JSONL is valid JSON lines" test_summary_jsonl_valid_json_lines
run_test "State file injected into prompt" test_state_file_injection
run_test "State file not injected when missing" test_state_file_not_injected_when_missing
run_test "Pre-context injected into prompt" test_pre_context_injection
run_test "Pre-context failure doesn't crash loop" test_pre_context_failure_doesnt_crash
run_test "Post hook warn on failure" test_post_hook_warn
run_test "Post hook stop on failure" test_post_hook_stop
run_test "Post hook retry with limit" test_post_hook_retry_with_limit
run_test "Post hook success" test_post_hook_success
run_test "Completion sentinel detected" test_completion_sentinel
run_test "Stop sentinel halts loop" test_stop_sentinel_halts
run_test "RESUME_AFTER sleeps and continues" test_resume_after_sleeps_and_continues
run_test "STOP without RESUME_AFTER halts" test_resume_after_without_number_halts
run_test "Post-iteration STOP with RESUME_AFTER" test_post_iteration_stop_with_resume_after
run_test "No commits recorded as no_commits" test_no_commits_result
run_test "Timeout recorded as timeout" test_timeout_result
run_test "Error exit recorded as error" test_error_result
run_test "Env vars override config file" test_env_vars_override_config

echo ""
echo "════════════════════════════════"
echo -e "Results: ${GREEN}$PASS_COUNT passed${NC}, ${RED}$FAIL_COUNT failed${NC} / $TESTS_RUN total"
echo "════════════════════════════════"

[ "$FAIL_COUNT" -eq 0 ] && exit 0 || exit 1
