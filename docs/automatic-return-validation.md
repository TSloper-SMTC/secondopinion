# Automatic worker return — qualification

Release version: **1.1.0**. The implementation was originally qualified as
`1.0.2+codex.20260909025954` on Linux, Codex **0.153.4**, Claude Code **2.1.266**.
Promotion changes version metadata and release documentation, not runtime logic.
Historical run identities below are preserved. Fresh release-version gates and
publication status are recorded in `CURRENT_WORK.md`; this is not a claim that
every Codex host/version supports idle notification.

## Acceptance contract

The coworker's arrangement is retained: existing named interactive Claude
workers receive assignments through temporary headless Claude messengers. The
messengers exit. Workers claim/report into a durable same-user mailbox, and the
installed return service delivers results into the original saved Codex
conversation, including while idle. Codex consumes and explicitly acknowledges
the result. A messenger receipt is never presented as worker completion.

The installer provisions a separate `codex-local-app-server.service` using public
`codex app-server --listen unix://`, or reuses an existing server, and supervises
`secondopinion-wakeup.service`. No manual socket, watcher, UUID registration,
worker environment flag, private inbox edit, Codex upgrade or permission override
is needed. The public service lists Claude workers for PID-namespaced callers;
name-only delegation verifies uniqueness, UUID and exact checkout automatically.
Freshly started workers get a bounded five-second discovery-refresh window.

The ordinary `ask`/`review` path remains foreground and separate. `delegate --async`
automatically falls back to foreground collection if automatic return is known
to be unavailable. The installer never overrides an explicitly disabled network
setting. Working CLI authentication and the user's existing execution permissions
remain prerequisites, not capabilities the plugin can grant.

## Evidence

All paths below are repository-relative. Counts include setup/assertion checks;
repeated live runs are not distinct feature counts.

| Run | Result | What was actually exercised |
| --- | --- | --- |
| `out/release-1.1.0-regression-20260909.log` | **1,115 passed, zero failed** | Fresh complete gate with CLI, both manifests, marketplace and changelogs at release version 1.1.0 |
| `out/release-1.1.0-natural-20260909/summary.json` | **11/11 passed** | Fresh installed 1.1.0, real model-selected skill, name-only delegation, automatic idle return, model-issued exact-revision acknowledgment and single worker execution |
| `out/natural-worker-20260909-v3-final/summary.json` | **11/11 passed** | Final frozen candidate; second successful real-model name-only delegation, idle result consumption and model-issued acknowledgment, all visible in the ordinary terminal |
| `out/regression-wake-20260909-v4.log` | **1,115 passed, zero failed** | Final frozen-source gate: 129 installation + 166 parity + 124 packaging + 563 ordinary workflow + 53 mailbox + 46 wakeup/wire + 13 service + 21 directory checks |
| `out/installed-workers-20260909-v3-names/summary.json` | **49/49 passed** | Final candidate; four names with no UUID arguments, ordinary attached Codex, two installed-service crash/recoveries, exact results and one execution each, real ordinary foreground ask |
| `out/regression-wake-20260909-v3.log` | 1,112 passed, zero failed | Installation, parity, packaging, ordinary workflows, mailbox, wakeup, service ownership and public worker discovery before the final startup-race fix |
| `out/natural-worker-20260909-v2/summary.json` | 11/11 passed | Real sandboxed Codex selected the installed skill, resolved the user-supplied name, delegated, yielded, then consumed and acknowledged the exact result visibly in its ordinary terminal; controller did not delegate/register/watch/ack |
| `out/installed-workers-20260909-v1/summary.json` | 49/49 passed | Actual installed services, four real workers, two supervisor-recovered crashes, four correctly bound results, single fixture executions and a real ordinary foreground ask |
| `out/automatic-workers-20260909-v2-no-worker-env/summary.json` | 49/49 passed | Production CLI/service fixture, four ordinary named workers without an experimental startup variable; completion while the bridge was stopped and recovery after restart |

The checked-in [1.1.0 implementation hashes](release-1.1.0.sha256) bind the release
to its fresh gates; from the repository root run `sha256sum -c docs/release-1.1.0.sha256`.
Installed 1.1.0 plugin contents match source byte-for-byte, and the real installer
check reports `installed=yes` and `automatic_worker_return: ready`.
`out/automatic-return-source-20260909-final.sha256` retains the earlier candidate's
identity. Release promotion changed only the CLI VERSION line, manifests and
release documentation; Python runtime/installer hashes are unchanged. The shared
archive includes `SOURCE_SHA256SUMS` and selected evidence in `qualification/`.
Other historical artifacts remain in the originating repository. Archive identity,
extraction/install verification and publication status are recorded in `CURRENT_WORK.md`.
See [installation and updating](install-shared-candidate.md).

Deterministic tests cover concurrent creation/claim/acknowledgment, a 32-worker /
64-task mixed-outcome stress fixture, immutable bindings and snapshots, stale
claims, report corruption, unsafe filesystem objects, revision races, out-of-order
collection, refusal/attention and later continuation, explicit consumption,
overload, unknown send outcomes, service restart/history reconciliation, duplicate
watchers, disabled routes, closed conversations, approval waits, malformed wire
frames, deadlines, lifecycle ownership and fresh/absent/ambiguous worker discovery.

The earlier [mailbox qualification](worker-delegation-validation.md) includes a
real four-interactive-worker mixed-outcome/continuation run (36/36). The earlier
[wakeup PoC](codex-wakeup-poc.md) separately qualified busy-turn merging and
same-UUID saved-thread recovery. Those are supplemental evidence, not substitutes
for the production installed-service runs above.

## Failures found and fixed

- Natural v1 refused delegation because sandboxed `claude agents --json` was
  empty. The real model did not invent a UUID or launch a replacement. Added a
  narrowly scoped service publication of the public host listing; natural v2
  subsequently passed the entire workflow.
- Installed pool v2-name-only caught a just-started-worker refresh race. Its
  `pool-d.stderr` records the absent-name refusal. The run was interrupted after
  diagnosing this failure, not counted as passing; its owned sessions were
  stopped and its route disabled. Added a bounded discovery-refresh wait and
  regression tests; ambiguity and wrong-checkout errors remain immediate. The
  subsequent final name-only four-worker v3 passed all 49 checks.
- Initial full-suite runs exposed a transient indentation error during editing
  and mismatched local packaging versions; these were fixed. Failed logs are
  retained and are not included in passing counts.
- Vendor daemon bootstrap required an unavailable standalone installation.
  No standalone package was installed; the separate user service uses the public
  server command supported by the already installed CLI.

## Boundaries

- Qualified live capacity is **four concurrent interactive workers**, not an
  unlimited promise. The 32-worker stress test is deterministic, not 32 live
  Claude instances. No hardware/bench execution was undertaken.
- Automatic idle return is for saved conversations connected to the configured
  local CLI server on Linux/user-systemd. Installation requires starting a new
  Codex thread/reopening the client; a running pre-install client cannot have its
  transport changed silently. Other clients retain foreground collection when
  their permissions/runtime support delegation.
- Public tool-output turns use the current experimental app-server API. See the
  [official app-server documentation](https://learn.chatgpt.com/docs/app-server).
  Runtime upgrades need requalification; this is not vendor-certified support.
- The bridge does not resume unloaded conversations or answer approval prompts.
  Reopening the original saved conversation permits retained results to arrive.
  It does not bypass the worker's own authorization requirements.
- A committed mailbox report survives relay/worker/service exit. A recorded
  notification proves presence in Codex history, not semantic consumption. Only
  explicit task acknowledgment records consumption. A lost send reply with no
  confirming history remains ambiguous and is not blindly retried. Arbitrary
  crashes do not permit an exactly-once delivery or external-effect guarantee.
- A task ID prevents cooperative duplicate execution of that same assignment;
  it cannot atomically cover hardware effects or different task IDs. Same-user
  metadata is not an authentication boundary against a malicious local process.
- Uninstall stops the plugin bridge. The shared Codex server is retained so that
  other conversations are not interrupted. No backups, network infrastructure,
  existing user conversations or unrelated projects were changed for these tests.

## Reproduce

Run `bash tests/run.sh` for the deterministic/CLI/packaging gate. After installation,
use the two live commands in the [technical reference](reference.md). They use
real model requests and fresh owned fixture sessions; the installed pool test
deliberately crashes the plugin bridge only when no unrelated enabled routes exist.
Inspect each `summary.json`, exact result tokens, receipt-versus-result timing,
task revisions and cleanup records. Do not infer pass from a process exit alone.
