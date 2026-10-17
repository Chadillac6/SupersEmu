#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/mac-release-notes.sh
source "$(dirname "${BASH_SOURCE[0]}")/mac-release-notes.sh"

assert_notes() {
  local label="$1" subjects="$2" expected="$3" actual
  actual="$(printf '%s' "$subjects" | mac_release_notes_html)"
  if [ "$actual" != "$expected" ]; then
    printf 'FAIL: %s\nexpected:\n%s\ngot:\n%s\n' "$label" "$expected" "$actual" >&2
    return 1
  fi
  printf 'PASS: %s\n' "$label"
}

assert_notes "commit subjects become an HTML list" \
  $'Improve frame pacing (#52)\nFix sound & timing\n' \
  $'<ul>\n  <li>Improve frame pacing (#52)</li>\n  <li>Fix sound &amp; timing</li>\n</ul>'
assert_notes "HTML-sensitive subject characters are escaped" \
  $'Support <new> titles\n' \
  $'<ul>\n  <li>Support &lt;new&gt; titles</li>\n</ul>'
assert_notes "empty subject list is a valid HTML list" "" $'<ul>\n</ul>'
