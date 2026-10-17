#!/usr/bin/env bash

mac_release_notes_html() {
  local subject
  printf '<ul>\n'
  while IFS= read -r subject || [ -n "$subject" ]; do
    [ -n "$subject" ] || continue
    subject="${subject//$'\r'/}"
    subject="${subject//&/\&amp;}"
    subject="${subject//</\&lt;}"
    subject="${subject//>/\&gt;}"
    printf '  <li>%s</li>\n' "$subject"
  done
  printf '</ul>\n'
}
