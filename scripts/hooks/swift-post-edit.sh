#!/usr/bin/env bash
# PostToolUse hook entry for Edit/Write/MultiEdit. Runs the two Swift hooks in order:
#   1. format-swift.sh  — swift-format the file in place (never fails the tool call)
#   2. lint-swift.sh    — report violations the edit added (exit 2 sends them back to the agent)
# Claude Code runs separate hooks of one matcher in parallel, so they are chained here to make sure
# the formatter has finished before the linter reads the file.
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
input="$(cat)"

printf '%s' "$input" | "$dir/format-swift.sh"
printf '%s' "$input" | "$dir/lint-swift.sh"
