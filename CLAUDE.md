# Claude Task Loop

## Versioning

The plugin version lives in `.claude-plugin/plugin.json`. When making changes that warrant a version bump (bug fixes, new features, behavior changes), increment the `version` field there before committing. Use semver patch bumps (e.g. 0.1.2 → 0.1.3) unless the change is breaking.

Do NOT add a version to `.claude-plugin/marketplace.json` — for URL-sourced plugins, Claude Code reads the version from `plugin.json` only.
