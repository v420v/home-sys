#!/usr/bin/env bash
# Verify that the cron schedules in the three files that must stay in sync
# actually agree.  Run from the repo root.  Exits non-zero and prints a diff on
# any mismatch so CI catches drift before it silently breaks the scheduler.
#
# Sources of truth compared:
#   infra/scheduler/src/index.ts  — SCHEDULES map: cron → [workflow files]
#   infra/terraform/main.tf       — cron_schedules list
#   .github/workflows/slack.yml   — workflows=() array: name|file|cron entries
#
# Checks performed:
#   1. Set of cron expressions: index.ts == main.tf  (set-level only; main.tf
#      has no per-workflow mapping)
#   2. Per-workflow cron mapping: for each workflow tracked in slack.yml with a
#      non-empty cron, that cron must match what index.ts schedules for it.
#      Workflows with an empty cron in slack.yml (chain-triggered) are excluded.
#      Workflows in index.ts that slack.yml does not track are also excluded.
set -euo pipefail

ts_file="infra/scheduler/src/index.ts"
tf_file="infra/terraform/main.tf"
slack_file=".github/workflows/slack.yml"

# --------------------------------------------------------------------------
# Cron set from index.ts (keys of the SCHEDULES object).
# --------------------------------------------------------------------------
ts_crons=$(
  sed -n '/^const SCHEDULES/,/^};/p' "$ts_file" \
    | grep -oP '"[^"]*"\s*:' \
    | grep -oP '"[^"]*"' \
    | tr -d '"' \
    | sort
)

# --------------------------------------------------------------------------
# Cron set from main.tf (items of the cron_schedules list).
# --------------------------------------------------------------------------
tf_crons=$(
  sed -n '/cron_schedules[[:space:]]*=/,/]/p' "$tf_file" \
    | grep -oP '"[^"]+"' \
    | tr -d '"' \
    | sort
)

# --------------------------------------------------------------------------
# Per-workflow file=cron pairs from index.ts.
# Expands each SCHEDULES cron key over its workflow-file array.
# --------------------------------------------------------------------------
ts_pairs=$(
  awk '
    /^const SCHEDULES/ { in_block=1; cur_cron=""; next }
    in_block && /^\};/ { exit }
    in_block {
      line = $0
      if (line ~ /"[^"]*"\s*:/) {
        gsub(/^[^"]*"/, "", line)
        gsub(/".*$/, "", line)
        cur_cron = line
        line = $0
      }
      if (cur_cron != "" && line ~ /\.yml/) {
        while (match(line, /"[^"]*\.yml"/)) {
          seg = substr(line, RSTART+1, RLENGTH-2)
          print seg "=" cur_cron
          line = substr(line, RSTART + RLENGTH)
        }
      }
    }
  ' "$ts_file" | sort
)

# --------------------------------------------------------------------------
# Per-workflow file=cron pairs from slack.yml.
# Parses the workflows=() array; entries with an empty cron are excluded.
# --------------------------------------------------------------------------
slack_pairs=$(
  sed -n '/workflows=(/,/^\s*)/p' "$slack_file" \
    | grep -oP '"[^|"]+\|[^|"]+\|[^"]*"' \
    | while IFS='|' read -r name file cron; do
        name="${name#\"}"
        cron="${cron%\"}"
        if [ -n "$cron" ]; then echo "$file=$cron"; fi
      done \
    | sort
)

# --------------------------------------------------------------------------
# Comparisons
# --------------------------------------------------------------------------

fail=0
check() {
  local label_a="$1" data_a="$2" label_b="$3" data_b="$4"
  if [ "$data_a" != "$data_b" ]; then
    echo "❌ Cron mismatch between $label_a and $label_b"
    diff <(echo "$data_a") <(echo "$data_b") \
      | sed "s/^</ in $label_a only:/; s/^>/ in $label_b only:/"
    fail=1
  fi
}

# Check 1: cron set in index.ts must equal cron set in main.tf.
check "index.ts" "$ts_crons" "main.tf" "$tf_crons"

# Check 2: per-workflow cron mapping between index.ts and slack.yml.
# Filter ts_pairs to only the files tracked by slack.yml (with non-empty cron)
# so that self-tracking exclusions (e.g. slack.yml itself) don't produce false
# failures.
ts_pairs_for_slack=$(
  awk -F= 'NR==FNR { files[$1]=1; next } $1 in files { print }' \
    <(echo "$slack_pairs") \
    <(echo "$ts_pairs") \
  | sort
)
check "index.ts (file→cron)" "$ts_pairs_for_slack" "slack.yml (file→cron)" "$slack_pairs"

if [ "$fail" -eq 0 ]; then
  echo "✅ Cron schedules are in sync across $ts_file, $tf_file, and $slack_file"
  echo "   Cron set:          $(echo "$ts_crons" | tr '\n' ' ')"
  echo "   Workflow mappings: $(echo "$ts_pairs" | tr '\n' ' ')"
fi

exit "$fail"
