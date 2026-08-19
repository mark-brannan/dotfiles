#!/usr/bin/env bash
# Tracks cherry-pick operations along with other session metrics.
#
# Fired on PostCommit to detect and log cherry-pick commits to a metrics file.
# Cherry-picks are identified by the `(cherry picked from` footer in the commit message.
#
# Logs to: .claude/metrics/cherry-picks.jsonl (one JSON object per line)

set -euo pipefail

METRICS_DIR="${PWD}/.claude/metrics"
CHERRY_PICKS_FILE="${METRICS_DIR}/cherry-picks.jsonl"

# Create metrics directory if needed
mkdir -p "$METRICS_DIR"

# Get the commit hash of HEAD (the commit we just made)
commit=$(git rev-parse HEAD 2>/dev/null || echo "")
if [ -z "$commit" ]; then
  exit 0
fi

# Check if this commit is a cherry-pick by looking for the cherry-pick footer
commit_msg=$(git log -1 --format=%B "$commit" 2>/dev/null || echo "")
is_cherry_pick=false

if printf '%s' "$commit_msg" | grep -q "^(cherry picked from commit"; then
  is_cherry_pick=true
fi

# If it's a cherry-pick, extract the original commit hash
original_commit=""
if [ "$is_cherry_pick" = "true" ]; then
  original_commit=$(printf '%s' "$commit_msg" | grep "^(cherry picked from commit" | sed 's/.*commit \([a-f0-9]*\).*/\1/' | head -1)
fi

# Log the event as JSON
timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
cat >> "$CHERRY_PICKS_FILE" <<EOF
{"timestamp":"$timestamp","commit":"$commit","is_cherry_pick":$is_cherry_pick,"original_commit":"$original_commit"}
EOF

exit 0
