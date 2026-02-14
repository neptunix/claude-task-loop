---
description: Scaffold a new task loop in the current project
argument-hint: [task description]
allowed-tools: Read, Write, Edit, Glob, Grep, AskUserQuestion
---

Scaffold the files needed to run an autonomous headless Claude Code task loop in this project.

## Arguments

`$ARGUMENTS` is a short description of what the loop should do (e.g., "generate PRD specs" or "write unit tests for src/").

If no argument was provided, use AskUserQuestion to ask what the loop should do.

## Step 1: Read Templates

Read all three templates from the plugin:
- @${CLAUDE_PLUGIN_ROOT}/templates/task-loop.env.template
- @${CLAUDE_PLUGIN_ROOT}/templates/TASK_PROMPT.md.template
- @${CLAUDE_PLUGIN_ROOT}/templates/TASK_PROGRESS.md.template

## Step 2: Create `.task-loop.env`

Derive a slug from the description (e.g., "generate PRD specs" becomes `prd-spec-gen`).

Write `.task-loop.env` based on the template. Replace `{{TASK_NAME}}` with the slug. Uncomment and set any values that differ from defaults based on the user's description. For example, if the user mentions an output directory, set `OUTPUT_DIR`.

## Step 3: Create Prompt File

Write `TASK_PROMPT.md` based on the template. Replace all `{{...}}` placeholders:
- `{{TASK_NAME}}` — the human-readable task name
- `{{TASK_DESCRIPTION}}` — the user's description expanded into a clear sentence
- `{{PROGRESS_FILE}}` — `TASK_PROGRESS.md` (or value from config)
- `{{COMPLETION_SENTINEL}}` — `ALL_TASKS_COMPLETE` (or value from config)

Customize the "Do the Work" and "What Makes Good Output" sections for the specific task type. For spec generation, add writing tone guidelines. For test writing, add test structure conventions. For doc generation, add formatting standards.

## Step 4: Create Progress File

Write `TASK_PROGRESS.md` based on the template. Replace `{{TASK_NAME}}` and `{{COMPLETION_SENTINEL}}`.

If the user described specific work items, populate the queue. Otherwise, leave placeholder items.

## Step 5: Update `.gitignore`

Use Glob to check if `.gitignore` exists. If it does, read it and check whether `.task-logs/` is already listed. If not, append:

```
# Task loop logs
.task-logs/
```

If `.gitignore` does not exist, create it with that content.

## Step 6: Report to User

Tell the user:

1. **Files created** — list each file and what it's for
2. **What to edit** — especially `TASK_PROGRESS.md` (they need to fill in the queue)
3. **How to run** — the exact command:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/run-task-loop.sh
```

Run this from the project root directory in a separate terminal.

Remind them: "Edit TASK_PROMPT.md to customize the instructions and TASK_PROGRESS.md to list your work items before running the loop."
