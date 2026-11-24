@AGENTS.md

## Claude Code specifics
- Use `superpowers:brainstorming` before new features and `superpowers:writing-plans` before multi-step work; plans go to docs/superpowers/plans/.
- For concurrency questions load the `swift-concurrency` skill; for architecture work load `improve-codebase-architecture`.
- After editing Swift files, run the checks in AGENTS.md "Lint and format on every code change" before reporting done, and include them in the brief for any subagent that edits Swift.
- Machine-specific paths and simulator names live in CLAUDE.local.md (gitignored), not here.
