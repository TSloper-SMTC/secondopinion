# Lead/worker conversation qualification

This records the initial conversation candidate. The subsequent
[1.2.0 robustness audit](robustness-validation.md) supersedes its release-readiness
assessment and adds recovery, load and full-workflow qualification.

Status: **implemented, installed and validated locally** on 2026-09-09.

Candidate: **1.2.0+codex.20260909181322**. Product and test identity is bound by
`conversation-1.2.0.sha256`. Qualified host uses Linux/user-systemd, Codex 0.153.4
and Claude Code 2.1.266. Source and installed plugin are byte-identical.

Scope: the existing Codex lead and its assigned Claude workers can exchange
questions, replies, progress and direction on the same durable task. This does
not interchange Claude/Codex lead and worker roles. No publication is implied.

## Contract

- Each message binds task, message ID, sender, recipient, reply target and exact
  UTF-8 body with SHA-256. Retries preserve the same record. Message history and
  recipient consumption are independent of task revisions and terminal reports.
- Lead delivery revalidates the same worker UUID, unique name and checkout,
  serializes sends per task, and records a native receipt separately from consumption.
  Newer lead messages cannot overtake earlier queued or uncertain delivery.
  Unconfirmed attempts are retained for explicit reconciliation. No relay inbox
  is needed for worker replies.
- Worker messages notify only the task's bound registered lead. The durable
  message outbox uses the existing public Codex transport and history-based
  reconciliation; messages cannot be superseded by later task progress/completion.
- Foreground delegation/task collection returns exit 4 with pending messages.
  Reading does not consume; message acknowledgments require the exact recipient
  and message hash. Outcome acknowledgment remains separate.
- Messages can discuss terminal results but never reopen tasks, grant a new
  execution claim, or override repository authority, sandbox or approval policy.

## Final-source evidence

| Evidence | Result |
| --- | --- |
| `out/conversation-regression-v2-summary.json` and corresponding log | **1,167/1,167**, zero failures: 50 conversation, 129 installation, 166 parity, 126 packaging, 563 ordinary usage, 53 mailbox, 46 notification/wire, 13 service and 21 directory checks |
| `out/conversation-live-v2/summary.json` | **25/25**: real Codex lead, two native Claude workers, two question/reply rounds each, automatic idle notification, service restart between rounds, exact reports/history and single task execution |
| `out/conversation-fallback-v1/summary.json` | **7/7**: real worker, isolated store, foreground question pickup with exit 4, native lead reply and exact final report |
| `out/conversation-natural-v1/summary.json` | **11/11**: ordinary installed delegation by name, idle wakeup, visible result and model-issued acknowledgment |
| `out/conversation-direct-v2-summary.json` | Real foreground ask returned `SECONDOPINION_DIRECT_FINAL_OK`; response hash/token validated and exchange archived |
| `out/conversation-install-check-final.log` | Installed=yes, automatic return ready |
| `out/conversation-final-live-audit.json` | Live source hashes match; final reports visible in attached Codex; owned processes reaped; test threads archived; zero enabled notification routes |
| `out/conversation-package-check.log` | **126/126** installation/packaging checks from the exported archive extraction |

The 50 conversation tests cover immutable IDs and reply binding, content and
identity corruption, UTF-8 bounds, recipient/hash acknowledgments, concurrent
writers, unsafe/contended delivery locks, ordered lead sends, lost/late receipts,
explicit retry, wrong/replaced workers, service restart, permission/closed-session
waits, independent workers, outcome/message separation and legacy task collection.

The initial standalone mailbox test run exposed a test-loader import-path
failure. Its loader was corrected; all 53 mailbox tests passed in the full run.
The first live run encountered a transient Claude authentication-refresh
collision at one worker's startup; that worker subsequently claimed its task
and sent its question without any credential change or manual message forwarding.

`out/conversation-legacy-regression.log` retains the failing reproducer for an
old task with identical worker/requester IDs. The final fix restricts two-party
identity only when posting a new conversation message; ordinary legacy collection
still works. The final regression contains that test. First full/live runs passed
1,160 and 25 checks respectively on their earlier recorded bytes; they are not
substitutes for the final-source gates above.

Final archive: `out/secondopinion-1.2.0+codex.20260909181322.tar.gz` and checksum
sidecar. Its product/test bytes match the tested extraction; final handoff docs
record completed qualification. It excludes private stores, raw conversations,
generated out/ content, caches and Git history. Failed logs remain retained.
No implementation, validation or packaging work remains for the qualified local
configuration. No publication or colleague-host validation was performed.

## Reproduction

```bash
bash tests/run.sh
python3 -B tests/live_conversation.py --output out/conversation-live-UNIQUE
python3 -B tests/live_conversation_fallback.py --output out/conversation-fallback-UNIQUE
python3 -B tests/live_natural_worker.py --output out/conversation-natural-UNIQUE
```

Live tests require an installed matching plugin, a configured local Codex server,
Claude authentication and native worker messaging. They create only owned test
conversations/workers. The conversation test restarts the plugin-owned return
service between rounds; it preserves the shared Codex server. Unique output
directories retain source/harness identities, task IDs, public event logs and
cleanup receipts. They are opt-in, outside the deterministic suite.

## Limits

This remains a cooperating same-user mailbox on a local filesystem. Delivery is
not exactly-once downstream execution or a security boundary against malicious
same-user processes. Closed or approval-waiting Codex sessions retain messages;
they are not forcibly resumed or approved. An unreachable worker leaves its
message queued, and uncertain delivery requires explicit inspection/retry.
Message retention is explicit: no automatic task/conversation pruning is added.
