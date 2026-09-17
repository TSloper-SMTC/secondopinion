# Uncertain message recovery — 1.2.2

Status: published to GitHub `main` on 2026-09-17 as release commit
`af3e38f803d85cedcbb328ce1fe228137297c8f4`. Not installed locally or on the
peer host. Base: published 1.2.1 at `d10b4d4`.

## Incident addressed

The peer report in
`/mnt/hgfs/Downloads/secondopinion-delivery-issue-20260916.md` records an
uncertain lead-to-worker commit notice. The existing ordering guard correctly
blocked a later clearance notice, but the unresolved state was too easy to miss
and the only available recovery forced delivery of the stale hold before its
correction. The report does not contain the retained relay log, so the original
transport failure's precise cause remains unproven.

## Release behavior

- An uncertain `task message` or `message-retry` prints a prominent warning with
  the exact task, message, attempt, inspection command, evidence-based reconcile
  command, and explicit non-delivery retry command.
- `task status` reports every unresolved worker-message delivery, including on a
  terminal task, with its error and structured relay diagnostics.
- Message relays now use the same failed-exchange ID capture and bounded
  structured log analysis as initial task delivery.
- `message-reconcile` lets the bound lead assert a real native receipt obtained
  from independent evidence. Its provenance is recorded as `lead_asserted`; it
  does not resend content or imply consumption.
- `message-supersede` atomically records a full correction and suppresses every
  unresolved lead message already ahead of it. Stale content remains auditable
  but is excluded from unread worker work and cannot be retried. Late receipts
  or acknowledgments remain visible without reactivating it.
- Supersession requires the exact ordered unresolved set from status; a changed
  set fails before mutation. If correction delivery then fails, JSON and stderr
  both state that supersession committed and the correction remains queued.
- Active sends, confirmed-delivered messages, and consumed messages cannot be
  superseded. A `sending` state orphaned by a killed sender is recoverable after
  its OS lock disappears. The correction has independent delivery and acknowledgment.
- Schema 3 makes 1.2.1 and older clients refuse the upgraded store instead of
  silently ignoring supersession semantics. Versioned worker-hook registrations
  also force already-running older watchers to exit and prevent their recent
  notices from being mistaken for a usable 1.2.2 route.

## Preserved boundaries

Queued, native-accepted, worker-acknowledged, consumed, and task-complete remain
different states. Missing receipts never prove non-delivery. There is no blind
retry, fabricated receipt, implicit worker acknowledgment, task reopening, or
new execution authority. Explicit supersession acknowledges that an ambiguous
old send may already have arrived; the correction is what resolves that risk.

## Qualification

Focused tests cover uncertain delivery, warnings, terminal-task status, relay
diagnostics, evidence-based reconciliation, retry ordering, atomic supersession,
idempotence, active/delivered/consumed rejection, stale-work exclusion, hook
discovery, late receipts, schema migration, and old-client refusal. Final full
regression passed **1231/1231** with exit 0 in
`out/delivery-recovery-1.2.2/regression.log`: 129 installer, 170 parity, 132
plugin/package, 565 ordinary exchange, 55 task, 77 conversation, 23 delivery/hook,
46 wakeup/wire, 13 service, and 21 directory checks.

Native Claude Code **2.1.274** fixture qualification also passed:

- `native-hook/summary.json`: **8/8**, exact-session hook delivery during an
  injected API outage, no relay tools, single claim permission.
- `native-interactive/summary.json`: **15/15**, public worker discovery, two
  task completions, same-ID retries with single execution, outage notification,
  and a consumed/replied follow-up, with no relay or fabricated receipt.

These use a controlled local API and qualify runtime integration, not provider
availability or arbitrary model interpretation. Both watchers stopped.

Two adversarial reviews reproduced the original candidate's concurrency and
incident-shape gaps. Exchange `2026-09-17T130428Z-adversarial-review` found the
receipt/retry race, one-message replacement mismatch, missing stale-arrival
visibility, old-watcher route issue, and unaudited reconciliation. Exchange
`2026-09-17T131828Z-adversarial-review` verified those corrections and found
final idempotency/audit hardening items; all were corrected, including explicit
expected-set validation and retained stale-attempt receipts. The final delta's
focused suites passed before the complete gate.

`docs/candidate-1.2.2.sha256` preserves the qualified candidate hashes.
`docs/release-1.2.2.sha256` binds the 51 dated release product/test files and
verifies cleanly in both the source tree and extracted release. The shareable
archive is `out/secondopinion-1.2.2.tar.gz`, with an adjacent SHA-256 sidecar.
From the extracted release archive, the fresh installer suite passed **129/129**
and the plugin/package suite passed **132/132**. The archive contains source,
tests, and documentation only; it excludes Git history, private stores, native
session captures, caches, and generated test evidence.
