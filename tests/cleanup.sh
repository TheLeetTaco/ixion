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

# Find candidates
SANDBOXES=$(find "$TMPDIR_RESOLVED" -maxdepth 2 -type d -name 'flywheel-int-*' 2>/dev/null)
PANE_HISTORIES=$(find /tmp -maxdepth 1 -type f -name 'flywheel-int-*.pane.txt' 2>/dev/null)
LOGS=$(find /tmp -maxdepth 1 -type f -name 'yolo-test*.log' 2>/dev/null)

if [ -z "$SANDBOXES" ] && [ -z "$PANE_HISTORIES" ] && [ -z "$LOGS" ]; then
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

if [ -n "$LOGS" ]; then
  echo "Test logs:"
  echo "$LOGS" | while read -r f; do
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
[ -n "$LOGS" ] && echo "$LOGS" | xargs -I{} rm -f "{}"
echo "Done."
