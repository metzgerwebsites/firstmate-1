Mode: Hermes foreground checkpoint with a gated cron bridge.

A Hermes primary is a turn-driven agent: it runs a turn when the captain
messages it, when a cron job fires, or when a delegated call returns. It has no
Stop hook that can block a turn from ending, so supervision must never depend on
the current turn still being alive.

Two independent supervisors cover that gap, and exactly one owns each layer.

1. Foreground checkpoint, for a turn that is already running.
   Same shape as the Codex checkpoint, because the hazard is identical: the
   agent cannot reason while a foreground tool call runs, and a long turn must
   still return control so queued wakes are handled.
2. The gated cron bridge, for a fleet that is quiet and the captain is silent.
   This is the layer no other harness needs, and it is what keeps idle cost at
   zero.

## The gated cron bridge

`bin-local/fm-wake-gate.sh` is the zero-token pre-check. It runs on every cron
tick BEFORE the model and prints the firstmate drain digest only when
`state/.wake-queue` holds an actionable row. When the fleet is quiet it prints
nothing at all, so Hermes' monitor hash-suppression skips the model run entirely
and the tick costs one `bash` invocation and zero tokens.

Create it once per profile:

    hermes -p firstmate cron create "every 2m" \
      --name firstmate-wake \
      --monitor-script fm-wake-gate.sh \
      --workdir <firstmate home> \
      --deliver telegram:<chat_id> \
      --model <model> --provider <provider> \
      "You are the first mate. The MONITOR CHANGE DETECTED block is a firstmate
       wake drain. Handle every actionable item using bin/ and .agents/skills/.
       Run the printed WAKE_ACK_REQUIRED command after handling. Reply to the
       captain with the plain outcome and address them as captain."

Monitor scripts must live in `<profile home>/scripts/` and be referenced by bare
filename. A monitor script's output must be stable: no timestamps, no churning
pids, because every unstable byte would look like a change and burn tokens on a
quiet fleet.

Delivery uses `telegram:<chat_id>`. `platform:<chat_id>` is not a valid cron
target and is refused before dispatch, with no LLM call made.

Latency is the cadence plus one drain, so a 2-minute schedule meets the
60-second captain-latency target only with a shorter cadence; set the schedule to
the captain's real latency budget rather than to this example.

## Cycle

When this session owns supervision and away mode is not active:

1. Drain first with `bin/fm-wake-drain.sh`.
   After handling every emitted wake and reconciling open decisions and unread
   status lines, run the exact `--ack-through` command printed as
   `WAKE_ACK_REQUIRED`; until then the work stays durable for idempotent
   re-handling after interruption.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. First cycle: run one foreground watcher checkpoint with
   `bin/fm-watch-checkpoint.sh --seconds "${FM_HERMES_WATCH_CHECKPOINT:-180}"`.
4. Ordinary wake: if the command prints `signal:`, `stale:`, `check:`, or
   `heartbeat`, drain queued wakes, handle that wake, then start the next
   checkpoint.
5. If the command prints `checkpoint:` or exits 124 with no wake, drain queued
   wakes anyway, process any queued user message now visible to Hermes, then
   start the next checkpoint.
6. Never use shell `&` for firstmate watcher supervision.
7. When the captain is silent and no turn is running, the cron bridge above is
   the supervisor. The checkpoint is not armed across turns.
8. Failure or missing cycle only: drain queued wakes, inspect the failure, then
   start a fresh foreground checkpoint.

## Single lock owner

The fleet session lock is held by the process that owns the fleet. A Telegram
turn and a cron turn share one Hermes gateway process tree, so they share one
ancestry and therefore one lock verdict: whichever runs first holds it, and the
other reports `another live firstmate session holds the lock` and stays
read-only. That is the intended single-owner guarantee, not a fault.

Never run a second Hermes process against one FM_HOME to "get around" a lock
refusal. Two owners of one home compound memory and race every gate.