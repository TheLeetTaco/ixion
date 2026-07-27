#!/usr/bin/env bash
# Manually clean up integration test artifacts.
#
# Tests no longer auto-delete on exit — sandboxes, pane histories, and
# logs are preserved so failures can be inspected. Run this script when
# you're done debugging and want to free disk space.
#
# Usage:
#   bash tests/cleanup.sh            # dry-run (lists what would be deleted)
#   bash tests/cleanup.sh --apply    # actually delete

set -u

TMPDIR_RESOLVED="${TMPDIR:-/tmp}"

# Find candidates. Pane histories are written to ${TMPDIR:-/tmp} (see
# lib/tmux.sh::pane_save_history) but older runs wrote to /tmp — search
# both and dedup. The pre-rename 'flywheel-int-*' patterns are matched
# too, so debris from runs before the ixion rename still gets cleaned.
SANDBOXES=$(find "$TMPDIR_RESOLVED" -maxdepth 2 -type d \( -name 'ixion-int-*' -o -name 'flywheel-int-*' \) 2>/dev/null)
PANE_HISTORIES=$(find "$TMPDIR_RESOLVED" /tmp -maxdepth 1 -type f \( -name 'ixion-int-*.pane.txt' -o -name 'flywheel-int-*.pane.txt' \) 2>/dev/null | sort -u)

if [ -z "$SANDBOXES" ] && [ -z "$PANE_HISTORIES" ]; then
  echo "Nothing to clean."
  exit 0
fi

echo "Test artifacts found:"
echo

if [ -n "$SANDBOXES" ]; then
  echo "Sandbox directories:"
  echo "$SANDBOXES" | while read -r d; do
    [ -n "$d" ] && echo "  $(du -sh "$d" 2>/dev/null | cut -f1)  $d"
  done
  echo
fi

if [ -n "$PANE_HISTORIES" ]; then
  echo "Pane history files:"
  echo "$PANE_HISTORIES" | while read -r f; do
    [ -n "$f" ] && echo "  $(du -sh "$f" 2>/dev/null | cut -f1)  $f"
  done
  echo
fi

if [ "${1:-}" != "--apply" ]; then
  echo "(dry run — pass --apply to delete)"
  exit 0
fi

# Apply: delete each
echo "Deleting..."
[ -n "$SANDBOXES" ] && echo "$SANDBOXES" | xargs -I{} rm -rf "{}"
[ -n "$PANE_HISTORIES" ] && echo "$PANE_HISTORIES" | xargs -I{} rm -f "{}"
echo "Done."
