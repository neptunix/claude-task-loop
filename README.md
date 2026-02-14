# claude-task-loop

Reusable headless autonomous loop for Claude Code. Run any repeatable task — spec generation, test writing, doc generation, code gen — in a battle-tested bash while-loop.

## Features

- **Rate limit handling** — detects API usage limits, parses reset time, sleeps until reset, retries automatically
- **Timeout protection** — each iteration has a configurable timeout via `timeout --foreground`
- **Git safety** — auto-stashes uncommitted changes before each iteration, tracks commit counts
- **Sentinel-based completion** — stops when a configurable sentinel appears in the progress file
- **Blocker detection** — halts when `STOP` appears in the blockers file for human intervention
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

3. **Run the loop** in a separate terminal:

   ```bash
   ~/.claude/plugins/claude-task-loop/scripts/run-task-loop.sh
   ```

   Or use `/task-loop:run` inside Claude Code to see the exact command.

## How It Works

```
┌─────────────────────────────────────────┐
│           run-task-loop.sh              │
│                                         │
│  1. Load .task-loop.env config          │
│  2. Check sentinels (done? blocked?)    │
│  3. Git stash uncommitted changes       │
│  4. Build prompt from files             │
│  5. Run claude --dangerously-skip-...   │
│  6. Handle rate limits (sleep & retry)  │
│  7. Validate (commits made?)            │
│  8. Sleep, repeat                       │
└─────────────────────────────────────────┘
```

Each iteration runs Claude Code headlessly with `--dangerously-skip-permissions`. Claude reads the prompt file and progress file, does one unit of work, commits, and updates progress. The loop checks sentinels and continues.

## Configuration Reference

All config lives in `.task-loop.env` (bash-sourceable KEY=VALUE). Every parameter can also be set as an environment variable.

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

## Commands

| Command | Description |
|---------|-------------|
| `/task-loop:init [description]` | Scaffold `.task-loop.env`, prompt file, and progress file |
| `/task-loop:run` | Show current config and the exact bash command to run |

## License

MIT
