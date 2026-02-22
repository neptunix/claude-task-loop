# claude-task-loop

Reusable headless autonomous loop for Claude Code. Run any repeatable task — spec generation, test writing, doc generation, code gen — in a battle-tested bash while-loop.

## Features

- **Rate limit handling** — detects API usage limits, parses reset time, sleeps until reset, retries automatically
- **Timeout protection** — each iteration has a configurable timeout via `timeout --foreground`
- **Git safety** — auto-stashes uncommitted changes before each iteration, tracks commit counts
- **Sentinel-based completion** — stops when a configurable sentinel appears in the progress file
- **Blocker detection** — halts when `STOP` appears in the blockers file for human intervention
- **Auto-resume blockers** — `RESUME_AFTER=<seconds>` in the blockers file sleeps and continues (e.g., waiting for PR review)
- **Iteration metrics** — JSON-lines log of every iteration with duration, result, commit count; summary on exit
- **Inter-iteration state** — JSON state file passed between iterations for context continuity (branch, PR number, etc.)
- **Pre-iteration context** — inject environment info (git branch, PR status) into the prompt automatically
- **Post-iteration hooks** — run validation commands after each iteration with configurable failure behavior
- **Configurable everything** — all paths, limits, and behaviors controlled via `.task-loop.env`

## Install

```bash
# Add the marketplace (one-time)
claude plugin marketplace add neptunix/claude-task-loop

# Install the plugin
claude plugin install claude-task-loop
```

## Quick Start

1. **Scaffold a new loop** in your project:

   ```
   /task-loop:init generate PRD specs for trading bot
   ```

   This creates `.task-loop.env`, a prompt file, and a progress file.

2. **Edit the generated files:**
   - `.task-loop.env` — configure task name, paths, limits
   - `TASK_PROMPT.md` — write the instructions Claude follows each iteration
   - `TASK_PROGRESS.md` — list the work items as a checkbox queue

3. **Run the loop** — use `/task-loop:run` inside Claude Code to get the exact command, then run it in a separate terminal.

4. **Monitor** — use `/task-loop:status` to see a dashboard of iteration metrics, progress, and blockers.

## How It Works

```
┌─────────────────────────────────────────┐
│           run-task-loop.sh              │
│                                         │
│  1. Load .task-loop.env config          │
│  2. Check sentinels (done? blocked?)    │
│  3. Auto-resume if RESUME_AFTER set     │
│  4. Run PRE_CONTEXT, inject output      │
│  5. Inject state file into prompt       │
│  6. Git stash uncommitted changes       │
│  7. Build prompt from files             │
│  8. Run claude --dangerously-skip-...   │
│  9. Handle rate limits (sleep & retry)  │
│ 10. Validate (commits made?)            │
│ 11. Run POST_HOOK                       │
│ 12. Log metrics to summary.jsonl        │
│ 13. Sleep, repeat                       │
└─────────────────────────────────────────┘
```

Each iteration runs Claude Code headlessly with `--dangerously-skip-permissions`. Claude reads the prompt file, progress file, and state file, does one unit of work, commits, and updates progress. The loop checks sentinels and continues.

## Configuration Reference

All config lives in `.task-loop.env` (bash-sourceable KEY=VALUE). Every parameter can also be set as an environment variable.

### Core

| Parameter | Default | Required | Description |
|-----------|---------|----------|-------------|
| `TASK_NAME` | — | **Yes** | Human-readable name for log output |
| `PROMPT_FILE` | `TASK_PROMPT.md` | No | Path to the prompt file |
| `PROGRESS_FILE` | `TASK_PROGRESS.md` | No | Path to the progress/queue file |
| `BLOCKERS_FILE` | `BLOCKERS.md` | No | Path to the blockers file |
| `COMPLETION_SENTINEL` | `ALL_TASKS_COMPLETE` | No | Line in progress file that signals done |
| `STOP_SENTINEL` | `STOP` | No | Line in blockers file that signals halt |
| `OUTPUT_DIR` | `.` | No | Directory for task output files |
| `LOG_DIR` | `.task-logs` | No | Directory for iteration log files |
| `MAX_ITERATIONS` | `50` | No | Maximum loop iterations |
| `TIMEOUT` | `1800` | No | Seconds per iteration before timeout |
| `SLEEP_BETWEEN` | `10` | No | Seconds to sleep between iterations |
| `GIT_STASH` | `true` | No | Auto-stash uncommitted changes |
| `GIT_COMMIT_CHECK` | `true` | No | Warn if no commits made per iteration |
| `SYSTEM_PROMPT_APPEND` | `""` | No | Extra text appended to --append-system-prompt |

### Observability & Hooks (v0.2)

| Parameter | Default | Required | Description |
|-----------|---------|----------|-------------|
| `STATE_FILE` | `.task-loop-state.json` | No | JSON state file passed between iterations |
| `PRE_CONTEXT` | `""` | No | Bash command whose stdout is injected into the prompt |
| `POST_HOOK` | `""` | No | Bash command to run after each iteration |
| `POST_HOOK_FAIL_ACTION` | `warn` | No | On hook failure: `warn`, `retry`, or `stop` |

### Metrics Output

After each iteration, a JSON-lines entry is appended to `$LOG_DIR/summary.jsonl`:

```json
{"iteration":3,"timestamp":"2026-02-22 15:21:55","duration_s":842,"exit_code":0,"result":"success","new_commits":2}
```

Result values: `success`, `timeout`, `error`, `rate_limited`, `no_commits`, `hook_failed`.

## Commands

| Command | Description |
|---------|-------------|
| `/task-loop:init [description]` | Scaffold `.task-loop.env`, prompt file, and progress file |
| `/task-loop:run` | Show current config and the exact bash command to run |
| `/task-loop:status` | Dashboard: metrics, progress, blockers, state, recommendations |

## Prompt Recipes

See `skills/task-loop/references/prompt-recipes.md` for copy-paste-ready prompt blocks:

- **PR-Review-Fix-Merge Cycle** — create PR, wait for review, fix feedback, merge
- **Multi-Branch Workflow** — phase-based branching with state tracking
- **Smoke Test with Retry** — validate after each item, retry on failure
- **Quality Gate with Follow-Up** — batch quality scan with follow-up task creation

## License

MIT
