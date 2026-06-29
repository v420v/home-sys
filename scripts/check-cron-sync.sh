#!/usr/bin/env bash
# Verify that the cron schedule lists in the three files that must stay in sync
# actually agree.  Run from the repo root.  Exits non-zero and prints a diff on
# any mismatch so CI catches drift before it silently breaks the scheduler.
#
# Sources of truth compared:
#   infra/scheduler/src/index.ts  — SCHEDULES map keys
#   infra/terraform/main.tf       — cron_schedules list
#   .github/workflows/slack.yml   — cron field in each workflows=() entry
set -euo pipefail

ts_file="infra/scheduler/src/index.ts"
tf_file="infra/terraform/main.tf"
slack_file=".github/workflows/slack.yml"

# Keys of the SCHEDULES object in index.ts.
# Matches lines like:  "*/15 * * * *": [
ts_crons=$(
  sed -n '/^const SCHEDULES/,/^};/p' "$ts_file" \
    | grep -oP '"[^"]*"\s*:' \
    | grep -oP '"[^"]*"' \
    | tr -d '"' \
    | sort
)

# Items of the cron_schedules list in main.tf.
tf_crons=$(
  sed -n '/cron_schedules[[:space:]]*=/,/]/p' "$tf_file" \
    | grep -oP '"[^"]+"' \
    | tr -d '"' \
    | sort
)

# Unique non-empty cron values (third pipe-delimited field) from the
# workflows=(...) array in slack.yml.
slack_crons=$(
  sed -n '/workflows=(/,/^\s*)/p' "$slack_file" \
    | grep -oP '\|[^|"]*"$' \
    | tr -d '"|' \
    | grep -v '^$' \
    | sort -u
)

fail=0
check() {
  local label_a="$1" crons_a="$2" label_b="$3" crons_b="$4"
  if [ "$crons_a" != "$crons_b" ]; then
    echo "❌ Cron mismatch between $label_a and $label_b"
    diff <(echo "$crons_a") <(echo "$crons_b") \
      | sed "s/^</ in $label_a only:/; s/^>/ in $label_b only:/"
    fail=1
  fi
}

check "index.ts" "$ts_crons" "main.tf"    "$tf_crons"
check "index.ts" "$ts_crons" "slack.yml"  "$slack_crons"

if [ "$fail" -eq 0 ]; then
  echo "✅ Cron schedules are in sync across $ts_file, $tf_file, and $slack_file"
  echo "   Schedules: $(echo "$ts_crons" | tr '\n' ' ')"
fi

exit "$fail"
