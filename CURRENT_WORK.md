# Current Work

Updated: 2026-08-27

Status: **RELEASED LOCALLY** as `secondopinion--v1.0.2`. No Git remote is
configured, so this is a local release commit/tag and has not been pushed.

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
for this release. If publishing is later desired, configure an approved Git
remote and push the release commit plus `secondopinion--v1.0.2` tag.
