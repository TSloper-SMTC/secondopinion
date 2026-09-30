# Current Work

## 1.2.3 — published to GitHub main and installed here (2026-09-30 03:06 UTC)

Tim authorized publication and local update with "push it and update to 1.2.3".
Release commit **`313d0259361739716b97112a04068e9144116478`** was pushed without
force to `https://github.com/TSloper-SMTC/secondopinion`, branch **main**
(previous `8f02c30`). Independent `git ls-remote` and GitHub API reads confirmed
that exact commit at 03:06:25 UTC. Receipt: `out/release-1.2.3-publication.json`.
No tag or GitHub Release. This host then ran the plain installer (its Claude side
was already empty and stays so): `--check` reports `installed=yes`, Codex plugin
1.2.3, `codex_runtime: codex_managed` 0.159.2; the wakeup service restarted with
no enabled routes or unconsumed deliveries; Codex's managed server was untouched.
Restart Codex sessions to load the 1.2.3 plugin/skill.

Owner reported that Codex did not offer GPT-6.1-Sol. Root cause, proven on this
host: Codex windows take their model list from the shared app server, which
calls `/backend-api/codex/models?client_version=<server version>`; the backend
offers new models only to new enough clients. The server was the 1.1.0-era
`codex-local-app-server.service`, pinned to the npm Codex 0.156.1 found at
install time. The CLI had moved to standalone 0.159.2 and the npm files were
deleted, but the unit kept the old image running. Codex reuses any server on
its socket without a version check and auto-updates only servers it started
(Codex source at tag `rust-v0.159.2`: `tui/src/startup_orchestration.rs`,
`app-server-daemon/src/lib.rs`, `update_loop.rs`; hourly checks, 60 s drain).
So the unit blocked Codex's own updater. Supersedes the 1.1.0 note that vendor
daemon management needed an unavailable standalone install: current Codex
builds its managed server from the calling CLI's package.

Host remediation (owner-approved): unit stopped, disabled and deleted; then
`codex app-server daemon start` installed Codex's managed server with its
`pid-update-loop`. `daemon version` reports CLI = server = 0.159.2 with
backend `pid`; `model/list` over the socket lists `gpt-6.1-sol` first;
`secondopinion-wakeup.service` untouched and `check` reports ready.

Change: `wake_service.py` no longer writes or supervises any Codex unit. Install
retires the exact unit earlier releases wrote (header match; a same-named user
unit is preserved), then runs `codex app-server daemon start`; failure installs
nothing and foreground delegation remains. `check` stays read-only and reports
Codex versions, warning on an unmanaged or older server or a leftover unit.
Deliberately NOT done: starting Codex's server from the wakeup service at boot.
It would run inside that service's cgroup (killed on every reinstall/restart)
and inherit `NoNewPrivileges`; it is also unneeded, because return targets only
conversations open in a Codex window, and opening one starts the server.

Evidence: 7 of the new wake-service tests fail on the 1.2.2 code and all 19
pass on 1.2.3. Final 1.2.3-tree regression **1236/1236**, exit 0, at
`out/release-1.2.3/regression.log`. `docs/release-1.2.3.sha256` binds the same
51 product/test files as 1.2.2. Share archive `out/secondopinion-1.2.3.tar.gz`
(`git archive` of the release commit) with a bare-filename sidecar; the 1.2.2
sidecar recorded `out/...`, so its documented `sha256sum -c` fails beside the
archive. Live `check` and install's
`daemon start` path verified against the running managed server. Untested: an
npm-installed Codex host (Codex may refuse to build its server without a local
package; install then reports the error and foreground mode remains).

Next action: none for this host. A peer on 1.1.0-1.2.2 runs `git pull --ff-only`
and `install.sh --claude` (or uses the 1.2.3 share archive), which retires the
pinned unit; Codex windows open during that update must be restarted. First real
proof of Codex's hourly server updater arrives with the next Codex release:
`codex app-server daemon version` should then show both versions advanced.

## 1.2.2 — published to GitHub main (2026-09-17 16:02 UTC)

Owner asked to correct and thoroughly test the peer incident in
`/mnt/hgfs/Downloads/secondopinion-delivery-issue-20260916.md`. The candidate is
implemented on published 1.2.1 base `d10b4d4`; all version surfaces are dated
**1.2.2**. Tim explicitly authorized publication with "push it". Release commit
**`af3e38f803d85cedcbb328ce1fe228137297c8f4`** was pushed without force to
`https://github.com/TSloper-SMTC/secondopinion`, branch **main**. Independent
`git ls-remote` and GitHub API reads confirmed that exact remote commit at
16:02:47 UTC. Receipt: `out/release-1.2.2-publication.json`. No tag, GitHub
Release, active installation, live mailbox, or peer host was changed.

The repair adds prominent uncertain-delivery warnings and task-status alerts,
message-relay structured diagnostics, compare-and-swap receipt protection,
audited bound-lead reconciliation, and explicit full-set supersession. One
complete correction atomically replaces the exact ordered unresolved set named
by `--expect-superseded`; stale content leaves worker queues but remains audited.
Late receipts/acks remain visible, replaced-attempt receipts are retained, and a
failed correction delivery reports that supersession committed. Schema 3 and
versioned hook registration make old clients/routes fail closed.

Final regression: **1231/1231**, exit 0, at
`out/delivery-recovery-1.2.2/regression.log`. Native Claude Code 2.1.274 local-API
fixtures passed **8/8** hook/outage and **15/15** interactive task/conversation
checks. Two adversarial reviews found and drove closure of race, exact-incident,
worker-visibility, mixed-version, provenance, idempotency and audit gaps. Details:
`docs/delivery-recovery-1.2.2.md`. The candidate manifest remains as historical
qualification evidence; `docs/release-1.2.2.sha256` binds the dated release
product/test files (**51/51** verified in source and the extracted release).
The exported release's fresh installer passed **129/129** and its plugin/package
suite passed **132/132**. Shareable archive: `out/secondopinion-1.2.2.tar.gz`,
with adjacent SHA-256 sidecar.

No release implementation or publication step remains. Recipient next action:
run `git pull --ff-only`, then
`./plugins/secondopinion/scripts/install.sh --claude` and
`./plugins/secondopinion/scripts/install.sh --check`; start a new Codex thread
and restart/resume existing Claude workers. Update all participating
installations together; schema 3 is intentionally incompatible with 1.2.1
clients. Peer-host acceptance and real-provider behavior remain rollout checks.

## 1.2.1 — published to GitHub main (2026-09-11 20:06 UTC)

Release commit **`f07ecd1e6ece74f6a4d5e666dc8421ff2fdcca77`** was pushed to
`https://github.com/TSloper-SMTC/secondopinion`, branch **main**, without force.
Fresh `git ls-remote origin refs/heads/main` confirmed that exact commit at
20:06:53 UTC. Receipt: `out/release-1.2.1-publication.json`. This subsequent
documentation-only handoff records the verified publication.

Tim explicitly authorized publication with "ok push it" after reviewing
readiness. Preflight confirmed local HEAD and upstream main both `44e6806`,
the expected 28 reviewed files, all 51 release hashes in staged and committed
content, matching dated changelogs and no whitespace errors. The **1213/1213**
regression, **129/129** fresh installer, **132/132** fresh package, **8/8** native
stream and **15/15** native interactive checks remain applicable. Publishing
changed only release dates and documentation. `docs/release-1.2.1.sha256` binds
the release product/test bytes; its only difference from the retained candidate
manifest is the plugin changelog's release date.

Publication used the existing SSH key authenticated as `TSloper-SMTC`; origin
and credentials were not changed. Git LFS required an unsandboxed push to write
its local lock cache. No tag or GitHub Release was created. The release archive
is `out/secondopinion-1.2.1.tar.gz` with its SHA-256 sidecar, refreshed with this
publication record. The earlier candidate archive and test evidence are retained.

No release implementation or owner approval step remains. Recipient next action:
run `git pull --ff-only`, `./plugins/secondopinion/scripts/install.sh --claude`,
then `./plugins/secondopinion/scripts/install.sh --check`; start a new Codex
thread and restart/resume the original Claude workers. Retain `--claude` on
future updates and retry interrupted delegations with their original task IDs.
Peer-host acceptance and real-provider/model behavior remain rollout checks.
The owner's active plugin cache and worker sessions were not refreshed during
publication. Details: `docs/install-shared-candidate.md` and
`docs/delivery-relay-1.2.1.md`. The records below are historical and do not
supersede this publication receipt.

## 1.2.1 delivery repair — qualified local candidate, awaiting publication (2026-09-11)

Owner requested review and resolution of the peer's
`SECONDOPINION_DELIVERY_RELAY_PATH_ISSUE.md`. Base checkout was clean at
`44e6806`. The report exposes a real dependency: notifying an existing worker
requires a new relay inference. API retries can prevent any native tool call.
Raw peer logs were not supplied beyond the report; the precise API cause remains
unproven. Review, implementation, limits and peer steps:
`docs/delivery-relay-1.2.1.md`.

Implemented optional Claude `asyncRewake` worker hooks, durable typed pre-claim
`task available` notices, structured relay diagnostics, reliable failed-relay
exchange-ID capture, and separate queued/accepted/worker-claimed reporting.
Worker hooks also discover unread conversation messages. Merely drafting a task
does not notify; eligibility follows requester/return-registration checks.
Claims, authority, message acknowledgment, task revisions and native receipts
remain separate. All version surfaces are **1.2.1**, marked unreleased.

Runtime/test files are bound by `docs/candidate-1.2.1.sha256` (51 files).
New deterministic tests pass **21/21**. Native source-plugin qualification on
Claude Code **2.1.268** passes **8/8** using a persistent stream session and an
isolated local fake API: the reminder reaches the idle session before its next
request receives an injected 503. No real model-executed job is claimed by this
test. Evidence: `out/delivery-relay-investigation/native-async/summary.json`.
Its owned runtime/watcher were stopped. Exported-package install checks pass
**132/132** in `out/delivery-relay-investigation/package-install.log`.

Owner challenged certainty and regression coverage. Added
`tests/native_interactive_delivery.py`, which passed **15/15** on the unchanged
production bytes in `out/delivery-relay-investigation/interactive-v4/summary.json`.
This uses an actual interactive Claude PTY, actual public worker discovery,
production `delegate`/message commands and permitted native Bash tool execution.
The hook delivered during an injected 503; the worker claimed/completed two
successive tasks; same-ID retries preserved single execution; a follow-up was
consumed, acknowledged and answered without reopening completed work. A trap
proved no headless relay launched. The runtime and watcher were stopped.
API responses are controlled fixture responses, so this qualifies transport,
tool execution and mailbox integration, not real-model interpretation or the
peer's environment. The first three harness runs stopped at fresh-fixture UI
setup (theme/API-key confirmation), before exercising delegation; these are
retained and are not product failures. No transport or mailbox runtime repair was
needed after the 1213-check gate; later changes added the interactive test,
updated documentation and clarified installer status wording.

Final full regression passed **1213/1213**, exit 0:
`out/delivery-relay-investigation/regression-final.log` and
`regression-summary.json` (129 install + 170 parity + 132 package + 565 ordinary
usage + 61 conversation + 21 delivery/hook + 55 mailbox + 46 wakeup/wire + 13
service + 21 directory checks). Earlier failed fixture assertions were corrected;
their logs remain in the investigation directory. The final native hook run and
exported-package checks cover the final hook configuration, including explicit
`async=true` to avoid blocking on runtimes without `asyncRewake` support.
Plugin, skill, Bash syntax and whitespace checks passed. No active owner/peer worker, credentials,
global configuration, installed cache, Git commit, push, tag or release was changed.
The default CLI symlink may read the working source; active sessions were not
restarted or enrolled in worker hooks.

Shareable candidate: `out/secondopinion-1.2.1-candidate.tar.gz`, with adjacent
SHA-256 sidecar. It contains source/tests/docs only, excluding Git history,
private stores, raw native sessions, caches and generated evidence. Exported
product/test bytes match all 51 hashes in the candidate manifest. The archive
was refreshed to include the additional interactive test and the readiness audit.

Publication-readiness audit (2026-09-11): corrected the active install guide's
stale 1.2.0 instructions, documented retaining `--claude` on updates, and aligned
worker/message success semantics with queued versus accepted notifications.
README, technical reference, both matching changelogs and all version metadata
now describe 1.2.1. All relative Markdown file links resolve. The installer now
says removing the optional Claude plugin disables worker hooks. Fresh installer
checks pass **129/129** and refreshed exported-package checks pass **132/132**:
`out/delivery-relay-investigation/readiness-install.log` and
`readiness-package-install.log`. Native qualification's recorded runtime hashes
still match; all 51 current candidate hashes match source and exported files.
Whitespace and Bash syntax checks pass. Read-only `git ls-remote` confirmed
upstream main still equals local HEAD `44e68064322539621b8309a37e19a4175226877f`.
The candidate is ready to commit/push; no publication has occurred.

Exact next action: owner reviews and approves publication. Publication is a
separate owner approval step, consistent with prior releases. After approval, recheck
upstream/dirty ownership, date the 1.2.1 changelog entries, update unpublished
status text and candidate hashes/archive for the publication, commit only this
reviewed change, and push without force. Record the verified remote commit.
The peer then runs `install.sh --claude` and restarts/resumes workers
with their original UUIDs; use `--claude` on subsequent updates too. Retrying
the original task IDs preserves single-claim execution. Peer-host acceptance
and real-provider/model behavior remain rollout checks. No regressions were
detected in the covered workflows; neither the test count nor local native
qualification establishes universal correctness across every host/runtime.

## 1.2.0 — published to GitHub main (2026-09-09 19:48 UTC)

Release commit **`6742ff9c6aef77c277aaf59e40b6be4fc551b989`** was pushed to
`https://github.com/TSloper-SMTC/secondopinion.git`, branch **main**, without force.
Fresh `git ls-remote origin refs/heads/main` confirmed that exact commit at
19:48:15 UTC. Receipt: `out/release-1.2.0-publication.json`. This subsequent
documentation-only handoff records the verified publication.

Tim explicitly approved with "push it" after reviewing readiness. Preflight
confirmed local HEAD and upstream main both `772b36e`, the expected 28 owned
files, all 44 release-manifest hashes (also checked against the staged content),
matching changelogs and no whitespace errors. The existing **1186/1186**
regression, live workflow qualification and two Claude Code **APPROVE** reviews
remain applicable. Publication changed only approval/install/handoff text;
runtime, test and installed plugin bytes remain bound by
`docs/release-1.2.0.sha256`. No additional tag or GitHub Release was created.

No implementation or release-push work remains. Recipient next action: from an
existing clone, run `git pull --ff-only`, then
`./plugins/secondopinion/scripts/install.sh`, and start a new Codex thread.
Update participating installations together; 1.1.0 clients cannot use a migrated
schema-2 mailbox. Details: `docs/install-shared-candidate.md` and
`docs/robustness-validation.md`. The qualified archive in out/ retains its
pre-publication handoff text and unchanged product/test bytes.
The records below are historical and do not supersede this publication receipt.

## 1.2.0 — robust, reviewed, installed; awaiting publication approval (2026-09-09)

Owner requested bidirectional Codex-lead/Claude-worker communication, all known
workflow checks, and a final adversarial Claude Code review before any Git push.
Work is complete for the qualified Linux/user-systemd + Codex 0.153.4 and
Claude Code 2.1.266 setup. All version surfaces are **1.2.0**. No commit, push,
tag or release has been made. **Do not publish until Tim explicitly approves.**

Final evidence:

- `out/robustness-regression-v5-summary.json`: **1186 passed / 0 failed**, exit 0.
- `out/robustness-conversation-v2/summary.json`: **25/25** on final runtime,
  two real workers, two question/reply rounds, idle lead return, service restart,
  exact consumption/results, original binding and single execution.
- Existing live workflow audit: **49/49** four-worker/service-crash checks,
  **36/36** mixed-outcome/caller-death/duplicate/continuation/reuse checks,
  **23/23** ordinary native request lifecycle and **8/8** async-to-foreground
  fallback. Separate real Sonnet selection/reporting passed. Evidence retains
  each run's actual source identity; final suite/live conversation cover the
  subsequently reviewed changes.
- `out/robustness-package-check-v4.log`: **126/126** from the exported package.
- Claude Code **APPROVE** twice; final exchange
  `2026-09-09T191753Z-adversarial-review` independently verifies all five original
  findings are resolved and reruns the full suite successfully. Reports:
  `out/robustness-claude-review-v1.md` and `out/robustness-claude-review-v2.md`.

Repairs cover ordering and uncertain delivery, idle history polling, SQLite
rollback/commit failures, model reporting and capability-probe SIGPIPE. Review
follow-ups add actionable lock errors, safe model metadata, unread counts and
schema-2 migration. Actual 1.1.0 code verified migration preserves a task/claim
and then rejects the upgraded store. Update participating installations together;
opening the mailbox (including status/service startup) migrates it. Do not
use 1.1.0 clients on that store. A nested-transaction error introduced while
adding counts was caught and fixed before final gates; failed logs are retained.

`docs/release-1.2.0.sha256` binds product/tests. Runtime/test bytes are the reviewed
ones; final guide/handoff clarifications address the informational review notes.
Shareable archive: `out/secondopinion-1.2.0.tar.gz`, checksum sidecar beside it.
It contains source/tests/docs, excluding out/, private stores, raw conversations,
caches and Git history. Installed source/cache match; install check reports ready.
Owned live-test workers/TUIs are reaped, test threads archived, and no test return
routes remain enabled. The shared Codex server was preserved; both services run.

Detailed qualification, limits and every review disposition:
`docs/robustness-validation.md`. Current installation guide:
`docs/install-shared-candidate.md`. Exact next action: Tim reviews the result and
provides the separate commit/push go-ahead. Then recheck upstream/dirty ownership,
commit only this qualified change set, and push without force if still current.
The prior records below are historical and do not supersede this checkpoint.

## 1.2.0 conversation — implemented and validated locally (2026-09-09)

Owner requested ongoing lead/worker communication and thorough testing. Final
local/installed candidate is **`1.2.0+codex.20260909181322`**. Codex leads and their
existing Claude workers can exchange questions, updates, direction and correlated
replies within the same task. Message history, hashes and recipient consumption
are independent of task revisions/results. Lead sends are serialized per task,
revalidate the same worker identity, and preserve ambiguous delivery for explicit
reconciliation. Worker messages wake the original lead automatically; foreground
collection returns exit 4 with messages. Existing execution/approval boundaries
remain intact. No role interchange or cross-host transport was added.

Final-source gates passed:

- `out/conversation-regression-v2.log`: **1167/1167**, zero failures (50 new
  conversation + 129 installation + 166 parity + 126 packaging + 563 ordinary
  usage + 53 mailbox + 46 notification/wire + 13 service + 21 directory checks).
- `out/conversation-live-v2/summary.json`: **25/25**, real Codex lead and two
  existing interactive Claude workers, two question/reply rounds per worker,
  automatic idle return, plugin-service restart between rounds, exact final
  reports, original identity/request preservation and one execution per task.
- `out/conversation-fallback-v1/summary.json`: **7/7**, a real native worker and
  production foreground CLI with an isolated store, exit-4 question pickup,
  lead reply delivery, worker consumption and exact final result.
- `out/conversation-natural-v1/summary.json`: **11/11**, ordinary installed
  delegation by name, idle wakeup, visible result consumption and model-issued ack.
- `out/conversation-direct-v2-summary.json`: real ordinary foreground ask passed;
  response hash/token checked and exchange archived in its isolated test store.

`docs/conversation-1.2.0.sha256` binds final product/test files. Source and installed
cache are byte-identical. `install.sh --check` reports installed=yes and automatic
return ready; both user services are active. `out/conversation-final-live-audit.json`
confirms source-correspondent live runs, visible conversation results, owned
processes reaped, test threads archived and **zero enabled notification routes**.
The shared Codex server was preserved. Failed/earlier evidence remains retained.
A reproduced legacy-task collection regression and test-loader import-path error
were corrected before final gates. A transient Claude login-refresh collision in
the first live run recovered without credential edits or manual message forwarding.

Exported-package installation passed **126/126** in
`out/conversation-package-check.log`, from `out/conversation-package-fixture/`.
The final shareable archive is
`out/secondopinion-1.2.0+codex.20260909181322.tar.gz`, with a `.sha256` sidecar.
It includes source/tests/docs and excludes private stores, raw conversations,
generated out/ content, caches and Git history. Product/test bytes match the
tested export and `docs/conversation-1.2.0.sha256`; final docs record completion.

Implementation is uncommitted; **no GitHub push, tag or release** was made.
No engineering step remains for the qualified Linux/user-systemd + Codex 0.153.4
and Claude Code 2.1.266 configuration. Exact next action: owner review/publication
decision. If publication is requested, review this recorded dirty change set,
preserve the tested runtime bytes, and align any chosen release metadata before
committing/pushing. The installed feature is usable now in a new Codex thread.
Detailed contracts, evidence and limits: `docs/conversation-validation.md`.

## Peer request: ongoing lead/worker communication — assessed 2026-09-09

Owner reports that the colleague using the latest secondopinion wants
bidirectional communication between a lead and workers. Current source at
`772b36e` was inspected; the checkout was clean before this handoff note.

1.1.0 already delivers an assignment to an existing Claude worker and returns
terminal outcomes or `needs_attention` to its Codex requester. Workers can record
ordinary progress, but `codex_wakeup.py:collect` only notifies terminal/attention
states. `task_mailbox.py:parser` exposes no general task-message/reply command;
`delegate` preserves the original request and does not send follow-up content
after delivery/claim. `ask --follow-up` creates a separate review exchange and
does not implement an ongoing conversation with the assigned worker.

Proposed next feature: a durable conversation attached to the existing task,
allowing worker questions/updates and lead answers/direction, with delivery to
the same bound participants, explicit message consumption, and retained history.
Preserve the distinction between receiving a message and completing work.
The existing worker guide mentions continuation delivery, but the ordinary task
CLI does not provide a first-class reply operation.

Scope clarification was asked: ongoing conversation with the current Codex lead
and Claude workers, or also interchangeable Claude/Codex lead and worker roles.
No answer was available when this note was written. Exact next action: incorporate
the owner's clarification and define the message/reply and delivery contract
before implementation. No runtime changes or live-worker messages were made;
no tests were run for this source inspection. Existing release evidence below
remains historical qualification of 1.1.0.

## 1.1.0 — published to GitHub main (2026-09-09 05:29 UTC)

Release commit **`7cb3a1ba9184ab1639f7e6abda7f396698c3f6f2`** was pushed to
`https://github.com/TSloper-SMTC/secondopinion.git`, branch **main**, without force.
Fresh `git ls-remote origin refs/heads/main` confirmed that exact release commit
at 05:29 UTC. This subsequent documentation-only handoff records the publication;
runtime/installer bytes remain bound by `docs/release-1.1.0.sha256`.

Owner asked to promote the validated functionality and push so the colleague can
git pull and update. Fresh preflight confirmed HEAD and origin/main both ce14ec2,
and all seven implementation/installer hashes matched the previously qualified
candidate. No unrelated dirty changes were found. Promoted to plain **1.1.0**
in CLI/manifests/Claude marketplace/changelogs; this is a real feature-release
increment, not another development cachebuster. Runtime logic remains unchanged.

Fresh 1.1.0 gates all passed:

- `out/release-1.1.0-regression-20260909.log`: **1115/1115**, zero failures
  (129 installation + 166 parity + 124 packaging + 563 ordinary usage + 53 mailbox
  + 46 wakeup/wire + 13 service lifecycle + 21 worker directory).
- `out/release-1.1.0-natural-20260909/summary.json`: **11/11** with the real installed
  1.1.0 skill, name-only worker resolution, model-issued delegation/registration,
  idle wakeup, exact result consumption and model-issued acknowledgment. Test
  thread `01a0849e-1718-78e3-9c23-40b3fe9c8ac5` archived; owned processes reaped.
- `out/release-1.1.0-package-install-20260909.log`: **124/124** from the rebuilt
  archive extraction at `out/secondopinion-1.1.0-install.83PUxB/secondopinion`.
- Actual installation check reports 1.1.0, installed=yes and automatic return
  ready. Source/cache are byte-identical; plugin/skill/schema validators and
  diff checks passed. Both services active; fresh audit found zero enabled test
  routes. Historical four-real-worker crash-recovery and normal-ask evidence
  remains applicable to unchanged runtime logic; do not relabel its old build ID.

Release runtime/installer identity is checked in at `docs/release-1.1.0.sha256`.
Shareable archive: `out/secondopinion-1.1.0.tar.gz`, SHA-256
`5b5d3024fbf3fe139bfeee72edd5f4e66f1b7ae4769d0a5cc0bb5a77d82768c0`.
Its checksum sidecar and selected evidence are retained locally; neither private
stores/raw conversations nor generated out files are staged for Git publication.

Exact next action: the colleague can update from main. No further release
implementation/testing is pending for the qualified configuration. No GitHub
Release object, new release tag, colleague-host mutation or changes to unrelated
conversations were made. The recipient runs `git pull --ff-only`, then
`./plugins/secondopinion/scripts/install.sh`, then starts a new Codex thread.
No watcher/UUID setup. Preserve documented Linux/runtime/approval/closed-session
boundaries. The records below retain the prior candidate's historical identity.

## Release version correction needed — 2026-09-09

Owner questioned the missing version bump. Fresh inspection confirms that the
CLI, both plugin manifests, Claude marketplace and changelogs still use base
`1.0.2` with only a newer `+codex` development-build suffix. The latest local
release tag remains `secondopinion--v1.0.2`. That suffix refreshed the development
cache; it was not a proper feature-release increment. The prior completion
record below qualifies that exact candidate, not completed release numbering.

Recommended next release: **1.1.0** for the additive worker/mailbox/automatic-return
features (or `1.1.0-rc.1` if retaining explicit candidate status). No runtime,
version metadata, installed cache, archive or tag was changed during this review.
Exact next action when directed to correct it: align all current version surfaces
and current handoff references, reinstall using the prescribed plugin workflow,
rebuild the shareable archive and checksums, and rerun packaging/install checks.
Preserve historical test identities and do not publish/tag without authorization.

## Install-and-use candidate — completed (2026-09-09 03:09 UTC)

Local/installed candidate **`1.0.2+codex.20260909025954` is ready to share** for the
qualified Linux/user-systemd + Codex 0.153.4 + Claude Code 2.1.266 setup. Source
and installed plugin are byte-identical. No commit, GitHub push or published
release was made; preserve the dirty tree. README is 61 lines.

Deliverable: `out/secondopinion-1.0.2+codex.20260909025954.tar.gz` (204117 bytes).
SHA-256: `0ef2578b554bf24340052bcd6b94732e5b35be9b3af215eb7daa3bccb903662d`.
Sidecar: same archive path plus `.sha256`. Includes source, tests, concise README,
installation guide, qualification report, selected final evidence and
`SOURCE_SHA256SUMS`; excludes private stores, raw conversations, caches and git
history. Extract to a permanent tools location and run
`./plugins/secondopinion/scripts/install.sh`, then start a fresh Codex thread.
No manual worker UUID, watcher, socket, registration or environment-flag setup.
Full user handoff: `docs/install-shared-candidate.md`.

Final qualification (all passed; repeated checks are not unique feature counts):

| Evidence | Result |
| --- | --- |
| `out/regression-wake-20260909-v4.log` | **1115 passed / 0 failed**: 129 installation + 166 parity + 124 packaging + 563 ordinary workflow + 53 mailbox + 46 wakeup/wire + 13 lifecycle + 21 worker directory |
| `out/installed-workers-20260909-v3-names/summary.json` | **49/49**: four real named workers without UUID arguments, messengers exit first, exact results consumed visibly in ordinary idle Codex, two bridge crashes automatically recovered, no duplicate fixture execution, genuine normal foreground ask |
| `out/natural-worker-20260909-v3-final/summary.json` | **11/11**: real workspace-write Codex selects installed skill and independently resolves/delegates by NAME, registers automatic return, ends its turn, later consumes and itself acknowledges the exact result; controller does not delegate/register/watch/ack |
| `out/package-install-20260909.log` | **124/124** from the actual archive extraction, real Codex/Claude local plugin installation and cache checks using isolated fixture homes |

Natural v2 previously passed the same 11 checks. Other earlier production/PoC
evidence remains in `docs/automatic-return-validation.md` and linked records.
Final implementation checksums: `out/automatic-return-source-20260909-final.sha256`;
verified again after testing and against the archive extraction at
`out/packaged-install.dz7ii4/secondopinion`. Official plugin + both skill validators,
strict marketplace checks, both systemd unit validations and `git diff --check`
passed. Actual installer `--check` reports installed=yes and automatic return ready.

Two usability faults were found by real-model tests and fixed: sandbox-hidden
worker discovery (public host listing now published by the installed service),
and a just-started-worker refresh race (bounded five-second absent-name wait).
Ambiguous names, wrong checkouts and retargeted task IDs fail closed. Failed
runs are retained, never counted as passes. A generated source Python bytecode
cache was moved recoverably to `out/recovered-generated-cache/`; CLI imports now
disable bytecode creation and the shipped plugin contains no Python cache files.

Both installed user services remain enabled/active as requested:
`codex-local-app-server.service` uses public `codex app-server --listen unix://`
(no vendor bootstrap/standalone install or CLI upgrade), and
`secondopinion-wakeup.service` supervises notification and public name discovery.
The plugin service automatically recovered twice in the final pool test; the
shared Codex server was never stopped. No test harnesses or fixture executors
remain; owned workers/TUIs were reaped, own saved threads archived, and the fresh
read-only mailbox audit found **zero enabled test routes**. Test records retained
for audit. No existing user conversation, backup, router or network setting was
changed by this qualification work.

Exact next action: give the colleague the archive and installation guide, or
obtain explicit publication direction if a GitHub release is wanted. No further
engineering step remains for this qualified candidate. A different host/runtime
must be checked against the documented prerequisites; do not promise universal
flawless behavior, unlimited live-worker capacity, or exactly-once external
effects. Closed/unloaded threads are not forcibly resumed, approval waits are
not bypassed, and unconfirmed notification sends are retained for reconciliation.
Uninstall stops the plugin bridge but retains the shared Codex server to avoid
interrupting other conversations. All sections below are historical checkpoints,
superseded by this completion record.

## Install-and-use completion — historical implementation checkpoint (2026-09-09 UTC)

Owner explicitly requested completion while asleep: existing-worker workflow
should work after installation without manual watcher/connection commands, and
ordinary second-opinion usage must remain working. No backups/network changes.
Filesystem permission was changed by the owner to unrestricted; continue to
preserve existing sessions and unrelated settings. No commit/push/release yet.

New production modules: `codex_rpc.py`, `codex_wakeup.py`, `wake_service.py` in
the plugin scripts. `delegate --async` now verifies/automatically registers its
calling `CODEX_THREAD_ID`, exact checkout and selected task with the running
service BEFORE worker delivery. It returns delivery acceptance separately from
worker completion. The service reconciles durable notifications against public
Codex history; never resumes arbitrary threads, changes permissions, executes
workers, or acknowledges consumption implicitly. Foreground delegate/ask unchanged.

`tests/live_codex_default_endpoint.py`, v4, passed: an ordinary `codex resume`
with no endpoint/config overrides receives tool-output wakeup through an already
running default local server. v1-v3 were harness trust/controlling-terminal
failures, retained as failed evidence. Fixed PTY controlling-terminal setup.
`tests/live_automatic_workers.py`, `out/automatic-workers-20260909-v1`, passed
with four real interactive workers and PRODUCTION async CLI/service. All four
messengers exited before completion; killing the service, completing workers,
and restarting recovered all four outcomes automatically into the idle normal
TUI. Exact result/context/worker binding, single fixture executions, explicit
acks and no notification replay after a second service restart passed. All
owned processes reaped; only the new test conversation archived.

27 deterministic wakeup tests and 11 service-lifecycle tests passed separately.
Initial full regression log `out/regression-wake-20260909-v1.log` has all 1025
existing checks passing; the new suite caught a transient indentation error
while the source was being edited. That error was fixed and 27/27 passed again;
this is NOT a completed final frozen-source gate. Do not call that run green.

Installer now calls the new service helper: on supported Linux/user-systemd,
public `codex app-server daemon bootstrap` provisions Codex's own management and
a separately owned `secondopinion-wakeup.service` supervises the bridge. This
REAL installer/bootstrap path remains UNTESTED. Isolated test HOME must never
contact the real user manager. Uninstall stops only the plugin bridge; shared
Codex daemon retained. Non-systemd/legacy skill installs keep foreground mode.

Currently running: `tests/live_automatic_workers.py --output
out/automatic-workers-20260909-v2-no-worker-env` (unified exec session 7646;
consult process/summary if the handle is unavailable). This repeat
removes the worker-startup experimental-team environment flag; only the internal
relay sets its own flag. Do not stop unrelated sessions or a foreign default socket.

Exact next actions: finish that live repeat; harden/test service installation
crash/ownership handling and protocol transport; add async-registration tests;
update concise README/worker skill/help; validate packaging; use prescribed
cachebuster/reinstall flow; test REAL installer service startup/restart/ordinary
Codex integration plus ordinary real ask; run full tests again on frozen source.
Before handoff record definitive counts, hashes, process cleanup, installed vs
released status and any platform limitations. Do not promise universal flawless
behavior or present ambiguous delivery as exactly-once consumption.

## Wakeup integration — started, not yet qualified (2026-09-09 UTC)

After the router-restart pause, the owner said resume. Integration work added
`scripts/codex_rpc.py`, `scripts/codex_wakeup.py` under the plugin and a CLI
`wake` dispatch. These are local, uncommitted implementation drafts: no tests
have yet been run on this new integration. Earlier passing wakeup runs below
used prototype watchers and do NOT qualify these new modules. No installed
cache, release, existing user conversation, backup or network setting changed.

The draft requires explicit saved-thread/private-endpoint/task registration and
a separately running foreground watcher. It persists notification state and
attempts history-based reconciliation instead of blindly retrying ambiguous
sends. It never implicitly acknowledges task consumption or approves work.
The owner asked what opt-in means, then whether the coworker's workflow would
work with installation alone. Current answer: no; the draft still requires
connection/watcher setup. An automatic return path after ordinary session
startup/delegation is a desired usability target, not a completed capability.

Exact next action: inspect the installed app-server ThreadItemEntry schema against
the draft reconciliation parser, then add deterministic tests for registration,
identity boundaries, duplicate watchers, lost acknowledgments, restart recovery,
permission waits and disable races. Review how to remove manual watcher setup
without targeting unrelated conversations. Qualify the production `wake` CLI
with four real interactive workers and an idle attached Codex terminal; the
existing prototype live harness must not stand in for this integration test.
Then update concise usage/skill guidance, packaging tests and run the full gate.
README should remain installation/general usage only. No new test processes are
running at this handoff. Earlier completed PoC evidence remains valid for its
recorded source and scope only.

## Resumed wakeup qualification — all scoped live tests passed (2026-09-09 UTC)

Owner said to return to testing and declined any backup/network intervention.
Saved-thread test `tests/live_codex_wakeup_saved.py` passed **42/42**, including
`codex queue`, automatic visible result delivery into an attached terminal, a real
interactive Claude task after messenger exit, and same-UUID/context recovery after
restarting the private server and reopening the terminal. Evidence:
`out/wake-saved-20260909-v1/summary.json`, 01:29:45–01:31:52 UTC.
`tests/live_codex_wakeup_burst.py` passed **34/34** with four independent synthetic
completion clients, both idle and busy, exact result binding and visible terminal
acknowledgments. Evidence: `out/wake-burst-20260909-v1/summary.json`,
01:33:04–01:33:48 UTC. Test threads were archived and all owned processes reaped.
The 51 mailbox regression tests passed again. Production plugin hashes unchanged.

The final combined `tests/live_codex_wakeup_pool.py` run passed **42/42**, combining
four real interactive Claude workers, departed temporary messengers and separate
mailbox watchers into the idle saved Codex terminal. All four randomized results
were consumed with original context, displayed automatically, bound to the correct
worker and acknowledged; all four execution fixtures ran once. Evidence:
`out/wake-native-pool-20260909-v1/summary.json`, 01:36:22–01:38:53 UTC. All fourteen
owned processes stopped/reaped; only the newly created test thread was archived.
The four native results arrived over two automatic turns in the same conversation.

Exact next action if wakeup integration is authorized: implement an opt-in watcher
with explicit endpoint/thread registration and durable delivery reconciliation;
then qualify watcher crashes/retries, permission/cancellation boundaries and its
installation lifecycle. Current one-shot test watchers are NOT a released plugin
feature and do not promise exactly-once notification delivery. The requested PoC
and these live extensions are complete; do not repeat them as unfinished work.
No installed plugin, release, network or backup configuration was changed. Existing
user conversations were untouched. Full details: `docs/codex-wakeup-poc.md`.

## Related slowdown check — diagnosis only (2026-09-09 01:18–01:22 UTC)

Owner asked whether machine/network slowness affected the PoC. Host-wide checks
on `p16s-vmware-ubuntu` found 8 CPUs, load 0.31, 97–99% CPU idle, ~12 GiB available
RAM, no active swapping, negligible pressure and 67 GiB disk free. No recent
kernel warnings. The four final PoC process IDs were independently absent.

Network delays were reproduced: five router pings averaged 1.65 seconds; ten
later pings averaged 3.24 seconds (max 4.69). Simultaneous Internet pings averaged
3.05 seconds. Initial HTTPS connects to three separate sites timed out; later
IPv4 probes succeeded but timing varied. A six-second ens192 sample measured
9.44 Mbit/s transmit, 0.263 Mbit/s receive and no new interface drops/errors.
`ss -tinp` showed active Kopia uploads from PIDs 1233 and 2438287 with ~2.3–2.5 MB
send queues and ~4.4-second RTTs. Codex and LAN SSH sockets also had seconds of RTT.
Backup uploads are a leading congestion suspect, not a demonstrated sole cause;
the Windows host/VM bridge, local link and router are not isolated by these checks.
No backup, network setting or unrelated process was changed/stopped.

Owner subsequently declined pausing backups; diagnosis is parked. Do not change
backups/network or resume this detour while testing the plugin. A future diagnostic
action, only if explicitly reopened and approved, is to briefly pause or constrain the
identified uploads and repeat simultaneous router/Internet pings and HTTPS timing,
then restore the exact prior state. If latency persists, compare from Windows host
to distinguish its physical link/router from the VM bridge. This incidental check
does not alter the passed wakeup PoC or authorize backup maintenance.

## Idle wakeup proof of concept — passed, not integrated (2026-09-09 UTC)

Owner authorized the isolated PoC. `tests/live_codex_wakeup.py` passed **22/22**
checks with real Codex 0.153.4 and Claude Code 2.1.266 at 01:14:24–01:16:14 UTC.
A real interactive Claude worker completed after its temporary messenger exited;
a separate one-shot mailbox watcher woke the same confirmed-idle Codex thread
using public `turn/start.toolOutput`, and Codex acknowledged the exact result
while retaining earlier conversation context. Controlled busy-turn delivery also
passed with the same active turn ID. Full evidence and limitations are recorded
in `docs/codex-wakeup-poc.md` and `out/wake-poc-20260909-v7/summary.json`.

All test-owned processes stopped/reaped; no persistent service, existing-session
message, plugin-cache change, release or production plugin edit occurred. Codex's
ordinary runtime index was used, but the target thread was new/ephemeral and its
control socket private. `codex queue` rejects ephemeral threads; saved-thread queue
behavior and an attached terminal/app UI were not tested. The experimental API
route is proven for this controlled setup, not arbitrary existing conversations.
Python compilation, diff checks and unchanged production hashes verified.

Exact next action if owner requests wakeup integration: design explicit opt-in
endpoint/thread registration and durable notification/reconciliation, then test
an attached user-facing Codex client, restarts, duplicate/retry handling, concurrent
workers and permission/cancellation boundaries. The previously qualified worker
release can proceed independently with foreground collection. Automatic idle
wakeup is now demonstrated by a test harness, but still absent from the plugin.

## Idle Codex wakeup feasibility — read-only investigation (2026-09-09 UTC)

Owner asked whether idle wakeup is possible; no implementation or live wakeup
test was authorized in this follow-up. Installed `codex-cli 0.153.4` exposes
`codex queue --thread <UUID or exact name> --message <text>`, but help alone
does not establish idle wakeup semantics. The default app-server control socket
was absent and `codex app-server daemon version` failed with ENOENT. No daemon
was started, message queued, or existing conversation resumed.

Official documentation at https://learn.chatgpt.com/docs/app-server describes
`thread/resume` plus `turn/start`, including starting a turn with standalone
tool output and queuing that output if a regular turn is active. It also labels
app-server and WebSocket transport experimental and unsupported for production.
This establishes an integration route, not qualification of this existing idle
conversation. Next action if the owner requests this extension: use an isolated
test conversation and explicitly provisioned local endpoint to establish whether
`queue` or `turn/start` wakes that same idle thread without user input; then test
busy delivery, duplicate events, concurrent workers and restart recovery before
connecting the durable mailbox. The already-qualified worker release below can
proceed independently; automatic idle wakeup remains unimplemented/unproven.

## Additional-worker qualification — complete, unreleased (2026-09-09 UTC)

Owner clarified that the extension means additional existing Claude workers,
not just extra fault variants. Added `task wait-any` to collect ready outcomes
from an explicit task set without waiting for the slowest worker. It preserves
explicit per-consumer acknowledgment and distinct attention/failure states.
New unit coverage includes 32 concurrent simulated workers, two assignments each,
mixed outcomes, same-worker multiple tasks, selected-task isolation and recovery.
`tests/live_worker_pool.py` exercises four real interactive PTY workers using
the temporary relay and public messaging path, not background-worker substitutes.
Final live run: `out/live-worker-pool-20260909-four-interactive-v4`, **36/36
checks passed**, Claude 2.1.266, 00:43:10–00:49:25 UTC. Public discovery proved
four interactive peers. Tests covered concurrent delivery; correct worker/result
binding; out-of-order collection; independent approval/refusal; caller SIGKILL
and replacement wait; native duplicate audit with execute=false; approval
continuation; same-worker reuse after refusal; absent-peer rejection; and five
outcomes recovered/acknowledged idempotently. All four owned PTYs/processes were
stopped/reaped, and all three execution fixtures ran once with no duplicate marker.
Production hashes matched at start, finish, and independent post-run verification:
CLI 895ac4fdc8c183ded1aa5c3e86e660ed1c377bd9e6fc434d71ca52c628963a5e;
mailbox 55852a1e71bb677d68d0663f8d9c3933dfbb6a264418fd948bfa5841c8faf15a.

Full gate: **1025/1025** (129 install, 166 parity, 116 packaging, 563 behavior,
51 mailbox). Five extra 32-worker/64-task stress repetitions passed. Logs are
in `out/live-worker-pool-20260909-four-interactive-v3/automated.log` and
`pool-stress.log`; final packaging rerun after guide edits passed 116/116 in
v4/installed-payload.log. Skill/plugin validation, Bash syntax and diff whitespace
checks passed. README remains 61 lines. The worker guide now includes named-session
setup, multi-worker collection and a harmless manual acceptance scenario.

Repeated load found/fixed a real journal-check TOCTOU (journal removed between
exists/is_file produced a false unsafe-object failure). A deterministic test
failed before the single-lstat fix and passed after it. Failed canary attempts
are retained: initial trust-prompt input, v2 plain-wait reading old attention,
v3 an overstrict duplicate log predicate. The final canary uses task-bound JSON
evidence. Details and boundaries are in docs/worker-delegation-validation.md.

All changes remain local/uncommitted/unreleased; no installation-cache refresh,
commit, tag, push or coworker delivery occurred. Idle Codex wakeup remains absent.
Exact next action: review/package a versioned candidate using the normal plugin
cachebuster/install workflow, then run the harmless acceptance scenario on the
coworker's host. Do not claim native 32-worker capacity (that pool was simulated),
unknown-host compatibility, automatic idle notification or transactional bench
side effects. No further required local testing is left for this scoped change.

## Initial delegated-worker implementation record (2026-09-08)

Follow-up complete: README reduced from 383 to 61 lines, covering installation
and general usage; detailed material moved to `docs/reference.md`. Owner then
requested especially thorough testing of the coworker's actual use case.
The optional `tests/live_delegation.py` canary passed 20 live checks with two
native workers on Claude 2.1.266, including delayed completion, a new waiter
recovering a late result, stop/respawn with the same UUID, no repeated fixture
execution, and idempotent consumption. Artifacts and source hashes are recorded
in `out/live-delegation-20260909-respawn/summary.json` and the validation doc.
The earlier --bg/--resume attempt allocated a different UUID and is preserved
as a failed test, not counted as supported recovery. All test workers were stopped.

Owner authorized implementing and thoroughly testing the coworker's existing
Claude-worker use case. Report read from
`/mnt/hgfs/Downloads/CLAUDE_CODEX_COMPLETION_REPORT.md`; it describes successful
relay delivery but no durable return channel or automatic Codex notification.

Implemented `delegate` plus the `task` mailbox commands. Task creation and
claiming are idempotent; progress uses revision checks; reports are snapshotted
and hash-validated; terminal outcomes cannot be overwritten; consumption is
explicit. `--worker-name` carries a verified name/UUID mapping across PID
namespace visibility differences. Missing native-session recovery now diagnoses
the failure and clears an obsolete session ID on fresh attach.

Validation: 129 install + 166 parity + 114 packaging + 563 existing behavioral
checks + 42 task tests = **1014 passed, 0 failed** across the full gate and
affected-suite reruns. Real Claude 2.1.263 tests proved worker completion about
27 seconds after relay exit, explicit refusal, and duplicate delivery returning
`execute=false`. Later inbox pickup and idempotent acknowledgment also passed.
The isolated native worker was stopped. Full evidence and limitations:
[`docs/worker-delegation-validation.md`](docs/worker-delegation-validation.md).
The expanded fault tests found and fixed a FIFO-report hang: request/report
inputs now have to be regular files, checked on the opened descriptor.

Supported boundary: foreground automatic result collection and durable later
pickup. **Idle Codex wakeup is not implemented**; this host had no app-server
control endpoint against which to qualify it. Native persistence and actual
external bench side effects are not made transactional by the task mailbox.

All changes are local and uncommitted. The installed plugin cache and published
version remain unchanged; the source-backed CLI exposes the new commands.
No Git push, release tag, cache refresh, or coworker delivery has occurred.

Exact next action: review the local diff and package a versioned release through
the repository's normal plugin cachebuster/install workflow. Qualify one harmless
delegated task on the coworker's host using its verified UUID/name/checkout
mapping, with Codex keeping the foreground wait active. Do not claim that host
is already tested or promise idle push notifications.

## Previous release record

Updated: 2026-08-27

Status: **RELEASED LOCALLY** as `secondopinion--v1.0.2`. `origin` is configured
as `https://github.com/TSloper-SMTC/secondopinion.git`; the authenticated
GitHub account (`TSloper-SMTC`) administers that public repository. The
unpublished branch also has `b67a223` (`docs: use canonical GitHub repository
URL`).

## Release

Installed Codex plugin payload: `1.0.2+codex.20260827162704`.

- Foreground execution is the only supported requester mode. `ask --background`
  and `review --background` fail before creating an exchange.
- Default progress is one short liveness line every 60 seconds. Detailed
  requests use a private `--file`; `--topic` is limited to one line and 120
  characters, and inline `--task` to one line and 240 characters.
- `--timeout` is the primary deadline and `--grace` is an unconditional grace
  window, defaulting to the primary timeout. Shutdown is then bounded by a
  ten-second TERM-to-SIGKILL interval without leaking Bash's `Killed (...)`
  notification.
- Foreground launches reserve a cryptographic run ID before starting Claude.
  Status reports the reservation as `launching`; unrelated manual claims and
  duplicate attaches are refused. An abandoned reservation becomes `exited`
  at age exactly five seconds and is recoverable.
- A responder remains observable through quiet heartbeats, `status`, and
  immutable per-run logs. Cross-session cancellation validates PID identity;
  cross-PID-namespace liveness uses the heartbeat and fails closed when
  identity cannot be proven.
- Process exit and answer completion are recorded independently. Exit code 0
  without a valid published answer is `no-valid-answer`; success requires a
  hash-validated prompt and response and records `validated-answer`.
- `show` refuses a published prompt whose header/hash validation fails.
  `read-response` and `result` independently refuse an invalid response.
- `ask --attach ID` safely recovers interrupted, exited, or timed-out work
  without overwriting foreign claims. Logs and prior-log metadata survive
  retries and archive relocation.
- `--max-turns` is opt-in; the mandatory wall-clock deadline remains the
  reliability bound. Headless Claude runs in safe mode and authentication
  failures provide exact login and attach-recovery instructions.

## Validation

- Full release gate: **957 passed, 0 failed**
  (129 install + 157 parity + 108 plugin + 563 behavioral).
- The behavioral suite includes real `unshare -Ur -pf` PID-namespace
  execution, a TERM-resistant responder, foreground claim/attach races,
  concurrent status reads, tamper rejection, immutable-log/archive checks,
  success-versus-exit classification, and a deterministic frozen-clock
  assertion that age 4 is `launching` while age 5 is `exited`.
- Bash syntax, `git diff --check`, both skill validators, Codex plugin
  validation, strict Claude plugin validation, and strict marketplace
  validation passed.
- `install.sh --check` reports Codex plugin
  `secondopinion@secondopinion 1.0.2+codex.20260827162704`; Claude-side
  interactive installation is intentionally absent because foreground
  headless requests require only the Claude CLI.
- Installed cache is byte-for-byte identical to `plugins/secondopinion`.
  SHA-256 values:
  - CLI: `7ad75b1fd1185673eb9b9ab34ec8fdcc35c11b9edc176ad9f30817cc6cbfe49d`
  - request skill: `dca67bfacb9faea046f5c82c40e6a495b5cb4f87be1b1200df30041f0a515630`
  - responder skill: `1e3f4f5e85fbe498ea28606b100866b16b93a849fb9c7eae4a776a92a4acd95c`

## Independent Qualification

- `2026-08-27T161823Z-secondopinion-1-0-2-final-release-audit` independently
  exercised all major lifecycle and integrity paths. It proved real PID
  namespace execution, bounded TERM-resistant cleanup with no leaked shell
  diagnostic, prompt/response tamper rejection, live foreground claim
  protection, no-answer classification, validated-answer completion, and
  installed/source equality. It found no code blocker and identified the
  then-uncommitted/tagged state plus a one-second launch-boundary issue.
- The boundary was changed from `> 5` to `>= 5` and the full gate passed again.
  `2026-08-27T163318Z-secondopinion-1-0-2-exact-boundary-audit` then proved live
  ages 3/4 remain `launching`, ages 5/6 are `exited`, recovery succeeds at age
  5, the installed payload matches source, and no code/behavior blocker
  remains.
- The focused audit suggested pinning both sides of the exact boundary. A
  frozen-clock regression now proves age 4 and age 5 deterministically; the
  behavioral suite passed **563/563** after that addition.
- All audit-created exchanges are archived and their private `/tmp` request
  files and harnesses were removed.

## Prior Findings

All actionable findings from the 1.0.1 adversarial audit are resolved:

- forced SIGKILL no longer leaks Bash's `Killed (...)` job notification;
- `show` no longer emits a hash-invalid published prompt;
- attach arbitration and prior-log metadata match actual lifecycle state;
- an unrelated manual claimant cannot steal a launching or live foreground
  request;
- real PID-namespace behavior is covered rather than only simulated;
- launch reservation and process completion now have explicit, non-successful
  states when no validated answer exists.

## Next Action

Restart any Codex session that was already open before installation so it loads
the `1.0.2+codex.20260827162704` request/respond skills. No code action remains
for this release. To publish, push `main` and `secondopinion--v1.0.2` to
`origin`.
