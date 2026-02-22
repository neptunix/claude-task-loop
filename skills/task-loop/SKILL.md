---
name: task-loop
description: This skill should be used when the user asks to "run a headless loop", "set up autonomous task loop", "run Claude headlessly", "automate repetitive tasks with Claude", "run Claude in a bash loop", "configure task loop", "debug task loop", "task loop not making progress", "Claude stuck in loop", "what is sentinel-based completion", "check loop status", "loop metrics", "iteration metrics", or needs guidance on headless autonomous Claude Code execution patterns.
---

# Task Loop — Headless Autonomous Claude Code

Run any repeatable task — spec generation, test writing, doc generation, code gen — in a battle-tested bash while-loop that handles rate limits, timeouts, git safety, sentinel-based completion, iteration metrics, inter-iteration state, and post-iteration hooks.

## Architecture Overview

```
.task-loop.env          Config (bash KEY=VALUE)
TASK_PROMPT.md          Instructions Claude follows each iteration
TASK_PROGRESS.md        Checkbox queue with <-- NEXT marker
BLOCKERS.md             Halt file (STOP sentinel, optional RESUME_AFTER)
.task-loop-state.json   Inter-iteration state (optional)
                        ↓
┌─────────────────────────────────────────┐
│           run-task-loop.sh              │
│                                         │
│  1. Source .task-loop.env               │
│  2. Check sentinels (done? blocked?)    │
│  3. Auto-resume if RESUME_AFTER set     │
│  4. Run PRE_CONTEXT, inject output      │
│  5. Inject state file into prompt       │
│  6. Git stash uncommitted changes       │
│  7. Build prompt from files             │
│  8. claude --dangerously-skip-perms     │
│  9. Handle rate limits (sleep & retry)  │
│ 10. Validate (commits made?)            │
│ 11. Run POST_HOOK                       │
│ 12. Log metrics to summary.jsonl        │
│ 13. Sleep, repeat                       │
└─────────────────────────────────────────┘
```

Each iteration: Claude reads the prompt + progress + state, does exactly one unit of work, commits, and updates progress. The loop checks sentinels and continues. The "one item per iteration" contract is critical — it ensures clean commits and reliable progress tracking.

## When to Use

Use a task loop when:
- Work is divisible into independent, sequential units (specs, tests, docs)
- Each unit can be completed in one Claude session (~30 min)
- Progress is trackable via a checkbox queue
- Work should continue unattended

Do NOT use when:
- Tasks require interactive human decisions mid-stream
- Work items depend on each other in complex ways
- Output quality requires human review before continuing

## Quick Start

1. Run `/task-loop:init [description]` to scaffold files
2. Edit `TASK_PROMPT.md` with task-specific instructions
3. Edit `TASK_PROGRESS.md` with the work item queue
4. Run `/task-loop:run` to see the exact command, then execute it in a separate terminal

## Configuration

All config lives in `.task-loop.env` (bash-sourceable KEY=VALUE). Environment variables override file values.

### Core Settings

| Parameter | Default | Description |
|-----------|---------|-------------|
| `TASK_NAME` | *required* | Human-readable name |
| `PROMPT_FILE` | `TASK_PROMPT.md` | Prompt file path |
| `PROGRESS_FILE` | `TASK_PROGRESS.md` | Progress file path |
| `BLOCKERS_FILE` | `BLOCKERS.md` | Blockers file path |
| `COMPLETION_SENTINEL` | `ALL_TASKS_COMPLETE` | Done signal |
| `STOP_SENTINEL` | `STOP` | Halt signal |
| `OUTPUT_DIR` | `.` | Output directory |
| `LOG_DIR` | `.task-logs` | Log directory |
| `MAX_ITERATIONS` | `50` | Max iterations |
| `TIMEOUT` | `1800` | Seconds per iteration |
| `SLEEP_BETWEEN` | `10` | Seconds between iterations |
| `GIT_STASH` | `true` | Auto-stash before each iteration |
| `GIT_COMMIT_CHECK` | `true` | Warn on no commits |
| `SYSTEM_PROMPT_APPEND` | `""` | Extra system prompt text |

### Observability & Hooks (v0.2)

| Parameter | Default | Description |
|-----------|---------|-------------|
| `STATE_FILE` | `.task-loop-state.json` | JSON state passed between iterations |
| `PRE_CONTEXT` | `""` | Bash command injected into prompt as "Current Environment" |
| `POST_HOOK` | `""` | Bash command run after each iteration |
| `POST_HOOK_FAIL_ACTION` | `warn` | On hook failure: `warn`, `retry`, or `stop` |

### Metrics

After each iteration, a JSON-lines entry is appended to `$LOG_DIR/summary.jsonl`:

```json
{"iteration":3,"timestamp":"2026-02-22 15:21:55","duration_s":842,"exit_code":0,"result":"success","new_commits":2}
```

Result values: `success`, `timeout`, `error`, `rate_limited`, `no_commits`, `hook_failed`.

A summary is printed when the loop exits (total iterations, successes, failures).

## Key Hardened Features

**Rate limit handling:** Detects "out of extra usage", "rate limit", "quota exceeded", "billing" in logs. Parses reset time from "resets 4pm (Europe/London)" format. Sleeps until reset + 60s, then retries the same iteration.

**Timeout protection:** Each iteration runs under `timeout --foreground $TIMEOUT`. Timed-out iterations are logged as warnings and the loop continues.

**Git safety:** Auto-stashes uncommitted changes before each iteration (`git stash push -m "task-loop-auto-stash iteration N"`). Tracks commit counts to warn when Claude doesn't commit.

**Clean environment:** Uses `env -u CLAUDECODE` to prevent nested Claude detection. Passes `--dangerously-skip-permissions --disable-slash-commands` for headless operation.

**Sentinel-based flow control:**
- Completion: loop exits when `COMPLETION_SENTINEL` appears as a standalone line in `PROGRESS_FILE`
- Blocking: loop exits when `STOP_SENTINEL` appears as a standalone line in `BLOCKERS_FILE`
- Auto-resume: if `RESUME_AFTER=<seconds>` appears in the blockers file alongside STOP, the loop sleeps and continues

**Inter-iteration state:** The state file is injected into the prompt each iteration. Claude can write to it to pass context forward (current branch, PR number, fix cycle count).

**Post-iteration hooks:** Run a command after each iteration as a safety net. Configure failure behavior with `POST_HOOK_FAIL_ACTION` (warn, retry, stop).

**Pre-iteration context:** Inject environment info (git branch, recent logs, PR status) into the prompt automatically, saving Claude startup time.

## Troubleshooting

**Loop exits immediately:** Check that `PROMPT_FILE` and `PROGRESS_FILE` exist. Check `.task-loop.env` has `TASK_NAME` set.

**Claude makes no progress:** Check the log file (`tail -f .task-logs/iteration-N.log`). Common causes: prompt too vague, progress file has no `<-- NEXT` marker, Claude is asking interactive questions.

**Rate limit loop:** Normal behavior — the script sleeps until reset. Check `WAIT_SECS` in logs. Default fallback is 1 hour if reset time can't be parsed.

**Git stash conflicts:** Run `git stash list` to see auto-stashes. Apply with `git stash pop` after the loop finishes.

**Iteration times out:** Increase `TIMEOUT` in `.task-loop.env`. Default is 1800s (30 min). Complex tasks may need 3600s.

**Post hook keeps failing:** Check the hook command manually. Set `POST_HOOK_FAIL_ACTION="warn"` to continue past failures while debugging.

**State file not injected:** Verify `STATE_FILE` path is correct and the file exists. The loop only injects it if the file is present and non-empty.

## Reference Files

For detailed guidance on specific aspects:
- **`references/prompt-authoring.md`** — Writing effective headless prompts: preamble structure, sub-agent architecture, verification steps, state file patterns, hook guidance
- **`references/progress-conventions.md`** — Sentinel patterns, checkbox queue format, NEXT markers, RESUME_AFTER, completion flow
- **`references/prompt-recipes.md`** — Copy-paste prompt blocks for PR review cycles, multi-branch workflows, smoke tests, quality gates
