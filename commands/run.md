---
description: Show task loop config and run command
allowed-tools: Read, Glob, Grep
---

Read the task loop configuration and show the user the current state and the exact command to run the loop.

## Step 1: Find Config

Use Glob to check if `.task-loop.env` exists in the current directory.

If it does NOT exist, tell the user: "No `.task-loop.env` found. Run `/task-loop:init` first to scaffold a task loop."
Stop here.

## Step 2: Read Config Files

Read these files (all paths relative to project root):
1. `.task-loop.env` — the config file
2. The prompt file (default `TASK_PROMPT.md`, or whatever `PROMPT_FILE` is set to in the env)
3. The progress file (default `TASK_PROGRESS.md`, or whatever `PROGRESS_FILE` is set to in the env)
4. The blockers file if it exists (default `BLOCKERS.md`)

## Step 3: Show Config Summary

Display a summary table of the current configuration:

```
Task Loop: <TASK_NAME>
─────────────────────────
Prompt:     <PROMPT_FILE>
Progress:   <PROGRESS_FILE>
Blockers:   <BLOCKERS_FILE>
Output:     <OUTPUT_DIR>
Logs:       <LOG_DIR>
Sentinel:   <COMPLETION_SENTINEL>
Iterations: <MAX_ITERATIONS>
Timeout:    <TIMEOUT>s
```

## Step 4: Show Progress Status

From the progress file, show:
- How many items are checked vs total
- The current `<-- NEXT` item (if any)
- Whether the completion sentinel is present

If the blockers file exists and contains the stop sentinel, warn: "STOP sentinel found in blockers file. The loop will not start until it's removed."

## Step 5: Show Run Command

Display the exact command to start the loop:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/run-task-loop.sh
```

Remind: "Run this from the project root in a separate terminal. The loop runs headlessly — watch progress with `tail -f .task-logs/iteration-N.log`."
