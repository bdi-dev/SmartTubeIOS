#!/usr/bin/env bash
# PostToolUse hook: after an Edit/Write/MultiEdit of a .swift file in this repo, run swift-format
# (lint --strict) and SwiftLint on it and report any violation the edit ADDED compared with the
# committed (HEAD) version of the same file. Pre-existing violations are not reported, so old files
# do not nag. Reads the tool-input JSON from stdin.
#
# Exit 0: nothing new (or nothing to check). Exit 2: new violations; the message on stderr goes back
# to the agent. Any tool problem (SwiftLint missing, SourceKit crash) exits 0 silently.
#
# Run it after format-swift.sh (see swift-post-edit.sh) so auto-fixable format issues are gone first.
set -uo pipefail

input="$(cat)"
path="$(printf '%s' "$input" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("tool_input",{}).get("file_path",""))' 2>/dev/null || true)"

[[ -n "$path" && "$path" == *.swift && -f "$path" ]] || exit 0

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
case "$path" in
    "$root"/*) ;;
    *) exit 0 ;; # only files of this checkout
esac
rel="${path#"$root"/}"

# SwiftLint needs Xcode's SourceKit when xcode-select points at the Command Line Tools.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
command -v swiftlint >/dev/null 2>&1 || exit 0

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# The committed version of the file, at the same relative path so path-scoped rules behave the same.
# A file that is not in HEAD yet (new) has no baseline: every violation in it counts as new.
mkdir -p "$tmp/base/$(dirname "$rel")"
cp "$root/.swiftlint.yml" "$tmp/base/.swiftlint.yml"
if git -C "$root" cat-file -e "HEAD:$rel" 2>/dev/null; then
    git -C "$root" show "HEAD:$rel" >"$tmp/base/$rel"
else
    : >"$tmp/base/$rel"
fi

# SwiftLint lines look like: file:12:5: error: Message (rule_id). Keep the rule id.
lint_rules() { # $1 = working dir, $2 = file relative to it
    (cd "$1" && swiftlint lint --quiet --config "$1/.swiftlint.yml" "$2" 2>&1) |
        sed -nE 's/^.*:[0-9]+:[0-9]+: (error|warning): .*\(([a-z_]+)\)$/\2/p'
}
# swift-format lines look like: file:12:5: error: [RuleName] message
format_rules() { # $1 = file
    xcrun swift-format lint --strict --configuration "$root/.swift-format" "$1" 2>&1 |
        sed -nE 's/^.*:[0-9]+:[0-9]+: (error|warning): \[([A-Za-z]+)\].*$/\2/p'
}

# SwiftLint prints a fatal error (and no violations) when SourceKit cannot load; skip then.
if (cd "$root" && swiftlint lint --quiet --config "$root/.swiftlint.yml" "$rel" 2>&1) | grep -q "Fatal error"; then
    exit 0
fi

lint_now="$(lint_rules "$root" "$rel")"
lint_base="$(lint_rules "$tmp/base" "$rel")"
fmt_now="$(format_rules "$path")"
fmt_base="$(format_rules "$tmp/base/$rel")"

# Rules whose count went up: "rule +N (now M)".
increases() { # $1 = now list, $2 = base list
    local rule now base
    printf '%s\n' "$1" | sort -u | while read -r rule; do
        [[ -n "$rule" ]] || continue
        now="$(printf '%s\n' "$1" | grep -cx "$rule")"
        base="$(printf '%s\n' "$2" | grep -cx "$rule")"
        if ((now > base)); then
            echo "  $rule: +$((now - base)) (now $now, was $base)"
        fi
    done
}

lint_up="$(increases "$lint_now" "$lint_base")"
fmt_up="$(increases "$fmt_now" "$fmt_base")"

[[ -z "$lint_up" && -z "$fmt_up" ]] && exit 0

{
    echo "This edit added Swift lint violations in $rel (counts compared with the committed version):"
    [[ -n "$lint_up" ]] && printf 'SwiftLint:\n%s\n' "$lint_up"
    [[ -n "$fmt_up" ]] && printf 'swift-format:\n%s\n' "$fmt_up"
    echo "Fix them (do not baseline or suppress). To see the lines:"
    echo "  DEVELOPER_DIR=$DEVELOPER_DIR swiftlint lint --quiet --config .swiftlint.yml $rel 2>&1 | grep -E 'error:|warning:'"
    echo "  xcrun swift-format lint --strict --configuration .swift-format $rel"
} >&2
exit 2
