#!/usr/bin/env bash
# fm-wake-gate.sh - the zero-token pre-check that gates the firstmate wake cron.
#
# Contract (docs/parity.md row "wake bridge"):
#   - Runs every cron tick BEFORE the model. Prints NOTHING when the fleet is
#     quiet, so Hermes' --monitor-script hash-suppression skips the model run
#     entirely. That is what makes idle supervision free.
#   - Prints a compact digest ONLY when bin/fm-wake-drain.sh has actionable
#     content, which is what makes the next agent turn do real supervision work.
#   - Output MUST be stable (no timestamps, no pids that churn) or every tick
#     would look like a change and burn tokens while idle.
#
# Exit 0 always: a broken gate must not wedge the cron scheduler.
set -uo pipefail

FM_ROOT="${FM_ROOT_OVERRIDE:-$HOME/Projects/firstmate}"
export FM_HOME="$FM_ROOT"
QUEUE="$FM_ROOT/state/.wake-queue"

# Quiet fleet: no queue file, or it holds nothing actionable.
if [ ! -s "$QUEUE" ]; then
  exit 0
fi

# Let firstmate itself decide what is actionable and render it. Its drain owns
# OPEN DECISIONS / UNREAD STATUS / RECORD DIVERGENCE semantics; we never
# re-implement them here.
digest=$(cd "$FM_ROOT" && bash bin/fm-wake-drain.sh 2>&1)
status=$?

if [ $status -ne 0 ]; then
  # A drain failure is itself captain-relevant, but must stay stable in wording
  # so it does not re-trigger on identical bytes.
  printf 'FIRSTMATE DRAIN ERROR (exit %s)\n' "$status"
  exit 0
fi

# Empty drain output means nothing needs the captain or the supervisor.
if [ -z "${digest//[[:space:]]/}" ]; then
  exit 0
fi

printf '%s\n' "$digest"
exit 0