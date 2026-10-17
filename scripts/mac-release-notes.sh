#!/usr/bin/env bash

mac_release_notes_html() {
  local subject
  printf '<ul>\n'
  while IFS= read -r subject || [ -n "$subject" ]; do
    [ -n "$subject" ] || continue
    subject="${subject//$'\r'/}"
    subject="$(printf '%s' "$subject" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')"
    printf '  <li>%s</li>\n' "$subject"
  done
  printf '</ul>\n'
}
