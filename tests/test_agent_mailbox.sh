#!/bin/bash
# Behavioural tests for bin/agent-mailbox.
# Run: tests/test_agent_mailbox.sh   (exit 0 = all pass)
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AM="$HERE/../bin/agent-mailbox"
PASS=0; FAIL=0; CURRENT=""

# --- tiny harness -----------------------------------------------------------
t()      { CURRENT="$1"; }
ok()     { PASS=$((PASS+1)); }
fail()   { FAIL=$((FAIL+1)); echo "FAIL [$CURRENT] $*" >&2; }
assert_eq() { [ "$1" = "$2" ] && ok || fail "expected '$2' got '$1' ${3:-}"; }
assert_rc() { local want="$1"; shift; "$@" >/dev/null 2>&1; local rc=$?; [ "$rc" = "$want" ] && ok || fail "rc=$rc want=$want: $*"; }
assert_grep() { grep -q -- "$1" "$2" 2>/dev/null && ok || fail "'$1' not found in $2"; }
assert_not_grep() { grep -q -- "$1" "$2" 2>/dev/null && fail "'$1' unexpectedly found in $2" || ok; }
assert_file() { [ -f "$1" ] && ok || fail "missing file $1"; }
assert_nofile() { [ ! -e "$1" ] && ok || fail "unexpected file $1"; }
val() { awk -v k="$1" -F= '$1==k{sub(/^[^=]*=/,""); print; exit}' ; }  # key=value picker

# --- fixtures ---------------------------------------------------------------
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export AGENT_MAILBOX_DIR="$TMP/store"
export AGENT_MAILBOX_STALE_CLAIM_SECS=3600
unset CODEX_THREAD_ID

mkrepo() { # mkrepo <dir>
  git init -q -b main "$1" && git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
}
mkrepo "$TMP/repoA"; mkrepo "$TMP/repoB"
git -C "$TMP/repoA" worktree add -q "$TMP/repoA-wt" -b wt >/dev/null 2>&1
COMMON_A="$(cd "$TMP/repoA" && realpath "$(git rev-parse --git-common-dir)")"

new_in() { # new_in <dir> <topic> [extra args] -> prints exchange_id
  (cd "$1" && "$AM" new --topic "$2" "${@:3}") | val exchange_id
}
publish_prompt() { # publish_prompt <id> <body>  (fills the Task section like a real requester)
  local p; p="$("$AM" path "$1")/prompt.md"
  sed -i '/^<!-- Replace this section/,/-->$/d' "$p"
  printf '\n%s\n' "$2" >> "$p"
  "$AM" publish "$1" >/dev/null
}
write_response() { # write_response <id> <file> [responder]
  printf 'Exchange-ID: %s\nResponder: %s\n\nverdict: PROVEN ok\n' "$1" "${3:-Claude Code}" > "$2"
}

# ===========================================================================
t "empty store: list/status succeed and are empty"
out="$("$AM" list 2>&1)"; rc=$?
assert_eq "$rc" 0 "(list on missing store)"
assert_eq "$out" "" "(list output)"
assert_rc 0 "$AM" list --pending
assert_nofile "$AGENT_MAILBOX_DIR"   # list must not create the store

t "new: creates draft with grammar-valid ID, header, meta, private perms"
ID1="$(new_in "$TMP/repoA-wt" "First Review!")"
[[ "$ID1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z-first-review$ ]] && ok || fail "bad id '$ID1'"
D1="$("$AM" path "$ID1")"
assert_eq "$D1" "$AGENT_MAILBOX_DIR/exchanges/$ID1"
assert_file "$D1/prompt.md"
assert_grep "^Exchange-ID: $ID1\$" "$D1/prompt.md"
assert_grep "^Requester: Codex\$" "$D1/prompt.md"
assert_grep "^Target: Claude Code\$" "$D1/prompt.md"
assert_grep "^Repo: $TMP/repoA-wt\$" "$D1/prompt.md"
assert_grep "^Git-Common-Dir: $COMMON_A\$" "$D1/prompt.md"
assert_grep "^Branch: wt\$" "$D1/prompt.md"
assert_grep "^Dirty-State: clean\$" "$D1/prompt.md"
assert_grep "^Codex-Thread: (unset)\$" "$D1/prompt.md"
assert_eq "$("$AM" status "$ID1" | val state)" "draft"
assert_eq "$("$AM" status "$ID1" | val git_common_dir)" "$COMMON_A"
assert_eq "$(stat -c %a "$AGENT_MAILBOX_DIR")" "700"
assert_eq "$(stat -c %a "$D1/prompt.md")" "600"

t "new: records CODEX_THREAD_ID and non-git cwd gracefully"
ID_T="$(cd "$TMP" && CODEX_THREAD_ID=abc-123 "$AM" new --topic thread | val exchange_id)"
assert_grep "^Codex-Thread: abc-123\$" "$("$AM" path "$ID_T")/prompt.md"
assert_grep "^Repo: (none)\$" "$("$AM" path "$ID_T")/prompt.md"

t "new: two creators in the same second get distinct IDs"
(cd "$TMP/repoB" && "$AM" new --topic race >"$TMP/r1" 2>&1) &
(cd "$TMP/repoB" && "$AM" new --topic race >"$TMP/r2" 2>&1) &
wait
R1="$(val exchange_id <"$TMP/r1")"; R2="$(val exchange_id <"$TMP/r2")"
[ -n "$R1" ] && [ -n "$R2" ] && [ "$R1" != "$R2" ] && ok || fail "ids '$R1' '$R2'"

t "list: drafts are not pending; publish makes them pending; hash recorded"
assert_eq "$("$AM" list --pending | grep -c "$ID1")" "0"
publish_prompt "$ID1" "Task: review X"
assert_eq "$("$AM" list --pending | grep -c "$ID1")" "1"
assert_eq "$("$AM" status "$ID1" | val state)" "published"
SHA="$("$AM" status "$ID1" | val prompt_sha256)"
assert_eq "$SHA" "$(sha256sum "$D1/prompt.md" | cut -d' ' -f1)"
assert_rc 0 "$AM" publish "$ID1"          # idempotent

t "publish: prompt edited after publish is detected (prompt_ok=no)"
ID2="$(new_in "$TMP/repoB" second)"; publish_prompt "$ID2" "Task: Y"
chmod u+w "$("$AM" path "$ID2")/prompt.md"; echo "sneaky edit" >> "$("$AM" path "$ID2")/prompt.md"
assert_eq "$("$AM" status "$ID2" | val prompt_ok)" "no"
assert_rc 1 "$AM" claim "$ID2"           # cannot claim a tampered prompt

t "list --repo: matches by git common dir across worktrees, excludes other repos"
assert_eq "$("$AM" list --pending --repo "$TMP/repoA" | grep -c "$ID1")" "1"     # main checkout sees worktree's exchange
assert_eq "$("$AM" list --pending --repo "$TMP/repoA-wt" | grep -c "$ID1")" "1"
assert_eq "$("$AM" list --pending --repo "$TMP/repoB" | grep -c "$ID1")" "0"
assert_eq "$( (cd "$TMP/repoA" && "$AM" list --pending --here) | grep -c "$ID1")" "1"
assert_eq "$("$AM" list --pending --repo "$TMP/repoB" | grep -c "$ID2")" "0"    # ID2 is tampered → not offered as pending

t "list --json: valid JSON with expected keys"
if command -v python3 >/dev/null; then
  "$AM" list --json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d,list); assert all("exchange_id" in e and "state" in e and "repo" in e for e in d)' && ok || fail "list --json invalid"
else ok; fi

t "show: prints the prompt; path/status reject bad IDs"
assert_grep "Task: review X" <("$AM" show "$ID1")
assert_rc 1 "$AM" status "../etc"
assert_rc 1 "$AM" status "$ID1/../$ID2"
assert_rc 1 "$AM" path "no-such-id"
assert_rc 1 "$AM" show "$ID1;rm"

t "claim: first claimant wins, token issued, second claimant refused"
C1="$("$AM" claim "$ID1" --owner claude-A)"; rc=$?
assert_eq "$rc" 0 "(claim rc)"
TOK="$(echo "$C1" | val claim_token)"
[ -n "$TOK" ] && ok || fail "no token"
assert_eq "$("$AM" status "$ID1" | val state)" "claimed"
assert_eq "$("$AM" status "$ID1" | val claimed_by)" "claude-A"
assert_rc 1 "$AM" claim "$ID1" --owner claude-B
assert_eq "$("$AM" list --pending | grep -c "$ID1")" "1"     # still awaiting a response

t "respond: wrong token refused; missing Exchange-ID header refused; good response published atomically"
RESP="$TMP/resp.md"; write_response "$ID1" "$RESP"
assert_rc 1 "$AM" respond "$ID1" --token wrong --file "$RESP"
printf 'Responder: Claude Code\nno id line\n' > "$TMP/bad.md"
assert_rc 1 "$AM" respond "$ID1" --token "$TOK" --file "$TMP/bad.md"
write_response "some-other-id" "$TMP/mismatch.md"
assert_rc 1 "$AM" respond "$ID1" --token "$TOK" --file "$TMP/mismatch.md"
assert_nofile "$D1/response.md"
assert_rc 0 "$AM" respond "$ID1" --token "$TOK" --file "$RESP"
assert_file "$D1/response.md"
assert_eq "$("$AM" status "$ID1" | val state)" "answered"
assert_eq "$("$AM" status "$ID1" | val response_sha256)" "$(sha256sum "$D1/response.md" | cut -d' ' -f1)"
assert_eq "$(stat -c %a "$D1/response.md")" "600"

t "respond: write-once — a second response is refused and the first is untouched"
printf 'Exchange-ID: %s\nResponder: Claude Code\n\nOVERWRITE\n' "$ID1" > "$TMP/resp2.md"
assert_rc 1 "$AM" respond "$ID1" --token "$TOK" --file "$TMP/resp2.md"
assert_not_grep "OVERWRITE" "$D1/response.md"

t "read-response: prints validated response; refuses unanswered and tampered"
assert_grep "verdict: PROVEN ok" <("$AM" read-response "$ID1")
assert_grep "^Exchange-ID: $ID1\$" <("$AM" read-response "$ID1")
assert_rc 1 "$AM" read-response "$ID2"                        # never answered
chmod u+w "$D1/response.md"; echo "tamper" >> "$D1/response.md"
assert_rc 1 "$AM" read-response "$ID1"
assert_eq "$("$AM" status "$ID1" | val response_ok)" "no"

t "wait: returns 0 when a valid response lands, 124 on timeout, readiness only"
ID3="$(new_in "$TMP/repoB" waiter)"; publish_prompt "$ID3" "Task: Z"
assert_rc 124 "$AM" wait "$ID3" --timeout 1
( sleep 1; T3="$("$AM" claim "$ID3" --owner c | val claim_token)"; write_response "$ID3" "$TMP/r3.md"; "$AM" respond "$ID3" --token "$T3" --file "$TMP/r3.md" >/dev/null ) &
W="$("$AM" wait "$ID3" --timeout 15)"; rc=$?
wait
assert_eq "$rc" 0 "(wait rc)"
assert_eq "$(echo "$W" | val state)" "answered"
assert_not_grep "verdict:" <(echo "$W")     # wait does not print the body
assert_rc 1 "$AM" wait "no-such-id" --timeout 1

t "wait: default timeout is finite (usage advertises it)"
assert_grep "timeout" <("$AM" wait --help 2>&1)
assert_grep "600" <("$AM" wait --help 2>&1)

t "stale claim: takeover refused while fresh, allowed when stale"
ID4="$(new_in "$TMP/repoB" stale)"; publish_prompt "$ID4" "Task: S"
"$AM" claim "$ID4" --owner first >/dev/null
assert_rc 1 "$AM" claim "$ID4" --owner second --takeover
assert_rc 0 env AGENT_MAILBOX_STALE_CLAIM_SECS=0 "$AM" claim "$ID4" --owner second --takeover
assert_eq "$("$AM" status "$ID4" | val claimed_by)" "second"
assert_rc 1 env AGENT_MAILBOX_STALE_CLAIM_SECS=0 "$AM" claim "$ID4" --owner third   # without --takeover still refused

t "archive: only answered (or --force); moves dir; idempotent; ID stays reserved"
assert_rc 1 "$AM" archive "$ID2"                    # not answered
assert_rc 0 "$AM" archive "$ID3"
assert_nofile "$AGENT_MAILBOX_DIR/exchanges/$ID3"
assert_file "$AGENT_MAILBOX_DIR/archive/$ID3/response.md"
assert_eq "$("$AM" status "$ID3" | val state)" "archived"
assert_rc 0 "$AM" archive "$ID3"                    # already archived → ok
assert_rc 2 "$AM" wait "$ID3" --timeout 1           # archived → 2
assert_rc 0 "$AM" archive "$ID2" --force
assert_eq "$("$AM" list --pending | grep -c "$ID3")" "0"
assert_eq "$("$AM" list --all | grep -c "$ID3")" "1"

t "safety: symlinked prompt/response are refused"
ID5="$(new_in "$TMP/repoB" symlink)"; D5="$("$AM" path "$ID5")"
rm -f "$D5/prompt.md"; ln -s /etc/hostname "$D5/prompt.md"
assert_rc 1 "$AM" publish "$ID5"
assert_rc 1 "$AM" show "$ID5"

t "store not creatable: one clear error naming the store and the sandbox hint, exit 1"
RO="$TMP/ro"; mkdir -p "$RO"; chmod 500 "$RO"
out="$(cd "$TMP" && AGENT_MAILBOX_DIR="$RO/store" "$AM" new --topic blocked 2>&1)"; rc=$?
chmod 700 "$RO"
assert_eq "$rc" 1 "(rc for uncreatable store)"
assert_eq "$(echo "$out" | grep -c 'cannot create directory')" "0"        # no raw mkdir spam
assert_grep "cannot create mailbox store $RO/store" <(echo "$out")
assert_grep "writable_roots" <(echo "$out")

# ---- round-2 regressions (Codex adversarial review 2026-08-15) ----------------
t "status: exits 0 for every state (draft/published/claimed/answered/archived)"
IDS="$(new_in "$TMP/repoB" status-rc)"
assert_rc 0 "$AM" status "$IDS"                                   # draft
publish_prompt "$IDS" "Task: s"; assert_rc 0 "$AM" status "$IDS"  # published
TS="$("$AM" claim "$IDS" --owner o | val claim_token)"; assert_rc 0 "$AM" status "$IDS"   # claimed
write_response "$IDS" "$TMP/rs.md"; "$AM" respond "$IDS" --token "$TS" --file "$TMP/rs.md" >/dev/null
assert_rc 0 "$AM" status "$IDS"                                   # answered
"$AM" archive "$IDS" >/dev/null; assert_rc 0 "$AM" status "$IDS"  # archived
assert_rc 0 "$AM" list; assert_rc 0 "$AM" list --all --json

t "containment: a symlinked exchange dir is never followed (list/status/wait/archive/path)"
EXT="$TMP/external-exchange"; mkdir -p "$EXT"; printf 'exchange_id=2026-01-01T000000Z-evil\nstate=published\ncreated_epoch=1\nrepo=x\ngit_common_dir=x\ntarget=t\n' > "$EXT/meta"
ln -s "$EXT" "$AGENT_MAILBOX_DIR/exchanges/2026-01-01T000000Z-evil"
assert_eq "$("$AM" list --all | grep -c evil)" "0"
assert_rc 1 "$AM" status 2026-01-01T000000Z-evil
assert_rc 1 "$AM" path 2026-01-01T000000Z-evil
assert_rc 1 "$AM" wait 2026-01-01T000000Z-evil --timeout 0
assert_rc 1 "$AM" archive 2026-01-01T000000Z-evil --force
assert_eq "$(grep -c 'state=published' "$EXT/meta")" "1"          # external meta untouched
assert_nofile "$EXT/.lock"
rm -f "$AGENT_MAILBOX_DIR/exchanges/2026-01-01T000000Z-evil"

t "containment: symlinked .lock / meta / claim inside a real exchange are refused"
IDL="$(new_in "$TMP/repoB" lockfile)"; DL="$("$AM" path "$IDL")"
ln -sfn "$TMP/outside-lock" "$DL/.lock"          # replace the real lock with a symlink
assert_rc 1 "$AM" publish "$IDL"; assert_nofile "$TMP/outside-lock"; rm -f "$DL/.lock"
publish_prompt "$IDL" "task"; assert_eq "$("$AM" status "$IDL" | val state)" "published"
mv "$DL/meta" "$TMP/meta-moved"; ln -s "$TMP/meta-moved" "$DL/meta"
assert_rc 1 "$AM" status "$IDL"; assert_rc 1 "$AM" claim "$IDL" --owner o
rm -f "$DL/meta"; mv "$TMP/meta-moved" "$DL/meta"
mkdir -p "$TMP/outside-claim"; ln -s "$TMP/outside-claim" "$DL/claim"
assert_rc 1 "$AM" claim "$IDL" --owner o; assert_nofile "$TMP/outside-claim/token"; rm -f "$DL/claim"

t "respond: source file swapped after validation cannot change the published bytes (TOCTOU)"
IDT="$(new_in "$TMP/repoB" toctou)"; publish_prompt "$IDT" "Task: t"; DT="$("$AM" path "$IDT")"
TT="$("$AM" claim "$IDT" --owner o | val claim_token)"
write_response "$IDT" "$TMP/race-input.md"
printf 'Exchange-ID: some-other-id\nResponder: X\n\nSWAPPED\n' > "$TMP/race-swap.md"
( flock 8; sleep 2 ) 8>>"$DT/.lock" &
LOCKPID=$!
sleep 0.3
"$AM" respond "$IDT" --token "$TT" --file "$TMP/race-input.md" >"$TMP/race.out" 2>&1 &
RPID=$!
sleep 0.5; mv -f "$TMP/race-swap.md" "$TMP/race-input.md"
wait $RPID; RRC=$?; wait $LOCKPID
assert_eq "$RRC" 0 "(respond rc under swap)"
assert_not_grep "SWAPPED" "$DT/response.md"
assert_grep "verdict: PROVEN ok" "$DT/response.md"
assert_eq "$("$AM" status "$IDT" | val response_ok)" "yes"

t "recovery: orphan claim dir (crash after mkdir) does not block a fresh claim"
IDO="$(new_in "$TMP/repoB" orphan-claim)"; publish_prompt "$IDO" "Task: o"; DO="$("$AM" path "$IDO")"
mkdir "$DO/claim"; echo deadtoken > "$DO/claim/token"; echo ghost > "$DO/claim/owner"   # meta still says published
assert_rc 0 "$AM" claim "$IDO" --owner alive
assert_eq "$("$AM" status "$IDO" | val claimed_by)" "alive"

t "recovery: response.md linked but meta not finalized (crash before meta) rolls forward on retry"
IDR="$(new_in "$TMP/repoB" roll-forward)"; publish_prompt "$IDR" "Task: r"; DR="$("$AM" path "$IDR")"
TR="$("$AM" claim "$IDR" --owner o | val claim_token)"
write_response "$IDR" "$DR/response.md"; chmod 600 "$DR/response.md"        # simulate: link happened, meta not updated
assert_rc 0 "$AM" respond "$IDR" --token "$TR" --file "$DR/response.md"
assert_eq "$("$AM" status "$IDR" | val state)" "answered"
assert_eq "$("$AM" status "$IDR" | val response_ok)" "yes"
assert_rc 0 "$AM" read-response "$IDR"

t "recovery: archive interrupted after meta update (dir still active) completes on retry"
IDA="$(new_in "$TMP/repoB" half-archive)"; publish_prompt "$IDA" "Task: a"; DA="$("$AM" path "$IDA")"
TA="$("$AM" claim "$IDA" --owner o | val claim_token)"; write_response "$IDA" "$TMP/ra.md"; "$AM" respond "$IDA" --token "$TA" --file "$TMP/ra.md" >/dev/null
sed -i 's/^state=answered$/state=archived/' "$DA/meta"                       # simulate: meta flipped, mv never happened
assert_rc 0 "$AM" archive "$IDA"
assert_nofile "$AGENT_MAILBOX_DIR/exchanges/$IDA"; assert_file "$AGENT_MAILBOX_DIR/archive/$IDA/response.md"

t "metadata: control characters in owner/topic/target are refused; JSON always valid"
IDM="$(new_in "$TMP/repoB" meta-inject)"; publish_prompt "$IDM" "Task: m"
assert_rc 1 "$AM" claim "$IDM" --owner $'bad\nclaimed_epoch=oops'
assert_rc 1 "$AM" claim "$IDM" --owner $'a\rb'
assert_eq "$("$AM" status "$IDM" | val state)" "published"          # still claimable, meta intact
assert_rc 1 env -C "$TMP/repoB" "$AM" new --topic $'x\ny' --target $'T\rQ'
"$AM" claim "$IDM" --owner $'tab\there ok' >/dev/null
if command -v python3 >/dev/null; then
  "$AM" status "$IDM" --json | python3 -c 'import json,sys; json.load(sys.stdin)' && ok || fail "status --json invalid with tab in owner"
  "$AM" list --all --json | python3 -c 'import json,sys; json.load(sys.stdin)' && ok || fail "list --json invalid"
else ok; ok; fi

t "respond --file -: no temporary copies are left behind (success and failure)"
IDF="$(new_in "$TMP/repoB" stdin-clean)"; publish_prompt "$IDF" "Task: f"; DF="$("$AM" path "$IDF")"
TF="$("$AM" claim "$IDF" --owner o | val claim_token)"
printf 'Exchange-ID: wrong\nResponder: X\n' | "$AM" respond "$IDF" --token "$TF" --file - >/dev/null 2>&1 || true
assert_eq "$(ls -a "$DF" | grep -c '^\.stdin\.\|^\.response\.tmp')" "0"
printf 'Exchange-ID: %s\nResponder: Claude Code   \n\nok\n' "$IDF" | "$AM" respond "$IDF" --token "$TF" --file - >/dev/null
assert_eq "$(ls -a "$DF" | grep -c '^\.stdin\.\|^\.response\.tmp')" "0"
assert_eq "$("$AM" status "$IDF" | val responder)" "Claude Code"      # trailing spaces trimmed

t "CRLF: a prompt/response with CRLF headers still validates"
IDC="$(new_in "$TMP/repoB" crlf)"; DC="$("$AM" path "$IDC")"
sed -i '/^<!-- Replace this section/,/-->$/d' "$DC/prompt.md"; printf 'task body\n' >> "$DC/prompt.md"
sed -i 's/$/\r/' "$DC/prompt.md"
assert_rc 0 "$AM" publish "$IDC"
TC="$("$AM" claim "$IDC" --owner o | val claim_token)"
printf 'Exchange-ID: %s\r\nResponder: R\r\n\r\nbody\r\n' "$IDC" > "$TMP/crlf.md"
assert_rc 0 "$AM" respond "$IDC" --token "$TC" --file "$TMP/crlf.md"
assert_rc 0 "$AM" read-response "$IDC"

t "env: HOME unset without AGENT_MAILBOX_DIR gives one clear error, not a bash trace"
out="$(env -u HOME -u AGENT_MAILBOX_DIR "$AM" list 2>&1)"; rc=$?
assert_eq "$rc" 1 "(rc HOME unset)"
assert_not_grep "unbound variable" <(echo "$out")
assert_grep "AGENT_MAILBOX_DIR" <(echo "$out")

t "help: usage lists every command"
for c in new publish list status show path claim respond read-response wait archive; do
  assert_grep "\b$c\b" <("$AM" --help 2>&1)
done

# ===========================================================================
# round-3 review regressions (Codex QA of 1.1.0)

t "new: newline in CODEX_THREAD_ID is rejected before any exchange is reserved"
before_count="$(ls "$AGENT_MAILBOX_DIR/exchanges" | wc -l)"
out="$(cd "$TMP/repoB" && CODEX_THREAD_ID=$'qa-thread\ninjected_key=injected_value' "$AM" new --topic thread-injection 2>&1)"; rc=$?
assert_eq "$rc" 1 "(rc newline CODEX_THREAD_ID)"
assert_grep "CODEX_THREAD_ID" <(echo "$out")
assert_eq "$(ls "$AGENT_MAILBOX_DIR/exchanges" | wc -l)" "$before_count" "(no exchange reserved on rejection)"
[ -z "$(ls "$AGENT_MAILBOX_DIR/exchanges" | grep thread-injection)" ] && ok || fail "exchange dir reserved despite rejection"

t "new: control bytes in CODEX_THREAD_ID are rejected"
out="$(cd "$TMP/repoB" && CODEX_THREAD_ID=$'esc\033[31mred' "$AM" new --topic thread-esc 2>&1)"; rc=$?
assert_eq "$rc" 1 "(rc control CODEX_THREAD_ID)"
[ -z "$(ls "$AGENT_MAILBOX_DIR/exchanges" | grep thread-esc)" ] && ok || fail "exchange dir reserved despite rejection"

t "new: a repository path containing a newline is rejected"
NLREPO="$TMP/nl/repo"$'\n'"header-break"; mkdir -p "$TMP/nl"; mkrepo "$NLREPO"
out="$(cd "$NLREPO" && "$AM" new --topic nl-repo 2>&1)"; rc=$?
assert_eq "$rc" 1 "(rc newline repo path)"
assert_grep "repository" <(echo "$out")
[ -z "$(ls "$AGENT_MAILBOX_DIR/exchanges" | grep nl-repo)" ] && ok || fail "exchange dir reserved for newline repo path"

t "respond: an empty Responder value is rejected and the exchange stays claimed"
IDR="$(new_in "$TMP/repoB" responder-empty)"; publish_prompt "$IDR" "task"
TR="$("$AM" claim "$IDR" --owner o | val claim_token)"
printf 'Exchange-ID: %s\nResponder:    \n\nbody\n' "$IDR" > "$TMP/resp-empty.md"
assert_rc 1 "$AM" respond "$IDR" --token "$TR" --file "$TMP/resp-empty.md"
assert_eq "$("$AM" status "$IDR" | val state)" "claimed"
assert_nofile "$("$AM" path "$IDR")/response.md"

t "respond: control bytes in the Responder value are rejected; a valid retry then succeeds"
printf 'Exchange-ID: %s\nResponder: QA\033[31mRED\n\nbody\n' "$IDR" > "$TMP/resp-esc.md"
assert_rc 1 "$AM" respond "$IDR" --token "$TR" --file "$TMP/resp-esc.md"
assert_eq "$("$AM" status "$IDR" | val state)" "claimed"
write_response "$IDR" "$TMP/resp-ok.md" "QA User"
assert_rc 0 "$AM" respond "$IDR" --token "$TR" --file "$TMP/resp-ok.md"
assert_eq "$("$AM" status "$IDR" | val responder)" "QA User"

t "respond: roll-forward of an unfinalized response.md applies the same Responder validation"
IDR2="$(new_in "$TMP/repoB" responder-rollforward)"; publish_prompt "$IDR2" "task"
TR2="$("$AM" claim "$IDR2" --owner o | val claim_token)"
printf 'Exchange-ID: %s\nResponder:   \n\nbody\n' "$IDR2" > "$("$AM" path "$IDR2")/response.md"   # interrupted respond left an invalid file
write_response "$IDR2" "$TMP/resp-ok2.md"
assert_rc 1 "$AM" respond "$IDR2" --token "$TR2" --file "$TMP/resp-ok2.md"
assert_eq "$("$AM" status "$IDR2" | val state)" "claimed"

t "publish: refuses a prompt whose Task placeholder is untouched"
IDP="$(new_in "$TMP/repoB" placeholder)"
out="$("$AM" publish "$IDP" 2>&1)"; rc=$?
assert_eq "$rc" 1 "(rc untouched placeholder)"
assert_grep "placeholder" <(echo "$out")
assert_eq "$("$AM" status "$IDP" | val state)" "draft"
publish_prompt "$IDP" "real task"
assert_eq "$("$AM" status "$IDP" | val state)" "published"

t "surplus positional arguments are rejected instead of silently using the last one"
IDS="$(new_in "$TMP/repoB" surplus)"; publish_prompt "$IDS" "task"
IDS2="$(new_in "$TMP/repoB" surplus-two)"; publish_prompt "$IDS2" "task"   # a second VALID id as the surplus argument
assert_rc 1 "$AM" status "$IDS" "$IDS2"
assert_rc 1 "$AM" claim "$IDS" "$IDS2" --owner o
assert_rc 1 "$AM" wait "$IDS" "$IDS2" --timeout 0
assert_rc 1 "$AM" archive "$IDS" "$IDS2" --force
assert_rc 1 "$AM" respond "$IDS" "$IDS2" --token t --file /dev/null
assert_eq "$("$AM" status "$IDS" | val state)" "published"    # neither exchange was touched
assert_eq "$("$AM" status "$IDS2" | val state)" "published"

# ===========================================================================
# round-4 review regressions (Codex QA of 1.2.0)

t "respond: an embedded CR (not a CRLF terminator) in the Responder line is rejected"
IDH="$(new_in "$TMP/repoB" header-bytes)"; publish_prompt "$IDH" "task"
TH="$("$AM" claim "$IDH" --owner o | val claim_token)"
printf 'Exchange-ID: %s\nResponder: QA\rRED\n\nbody\n' "$IDH" > "$TMP/resp-cr.md"
assert_rc 1 "$AM" respond "$IDH" --token "$TH" --file "$TMP/resp-cr.md"
assert_eq "$("$AM" status "$IDH" | val state)" "claimed"

t "respond: a NUL byte in a header line is rejected"
printf 'Exchange-ID: %s\nResponder: QA\0RED\n\nbody\n' "$IDH" > "$TMP/resp-nul.md"
assert_rc 1 "$AM" respond "$IDH" --token "$TH" --file "$TMP/resp-nul.md"
assert_eq "$("$AM" status "$IDH" | val state)" "claimed"

t "respond: an embedded CR in the Exchange-ID line is rejected (CR-stripping must not make it match)"
printf 'Exchange-ID: \r%s\nResponder: R\n\nbody\n' "$IDH" > "$TMP/resp-cr1.md"
assert_rc 1 "$AM" respond "$IDH" --token "$TH" --file "$TMP/resp-cr1.md"
assert_eq "$("$AM" status "$IDH" | val state)" "claimed"

t "respond: control bytes in the body (after the header block) are the responder's business and are accepted"
printf 'Exchange-ID: %s\nResponder: R\n\nbody with \001 control\n' "$IDH" > "$TMP/resp-bodyctl.md"
IDH2="$(new_in "$TMP/repoB" body-bytes)"; publish_prompt "$IDH2" "task"
TH2="$("$AM" claim "$IDH2" --owner o | val claim_token)"
printf 'Exchange-ID: %s\nResponder: R\n\nbody with \001 control\n' "$IDH2" > "$TMP/resp-bodyctl.md"
assert_rc 0 "$AM" respond "$IDH2" --token "$TH2" --file "$TMP/resp-bodyctl.md"

t "respond: Responder value keeps its full text (colons) and is trimmed at both ends"
printf 'Exchange-ID: %s\nResponder:   QA: Team   \n\nbody\n' "$IDH" > "$TMP/resp-colon.md"
assert_rc 0 "$AM" respond "$IDH" --token "$TH" --file "$TMP/resp-colon.md"
assert_eq "$("$AM" status "$IDH" | val responder)" "QA: Team"

t "publish: an embedded CR in a header line is rejected while CRLF line endings remain valid"
IDPC="$(new_in "$TMP/repoB" prompt-cr)"; DPC="$("$AM" path "$IDPC")"
sed -i '/^<!-- Replace this section/,/-->$/d' "$DPC/prompt.md"; printf 'task\n' >> "$DPC/prompt.md"
sed -i '2s/^Requester: Codex$/Requester: Co\rdex/' "$DPC/prompt.md"
assert_rc 1 "$AM" publish "$IDPC"
assert_eq "$("$AM" status "$IDPC" | val state)" "draft"

t "status/list: a legacy exchange whose header holds control bytes reports prompt_ok=no and is hidden from --pending"
IDLG="$(new_in "$TMP/repoB" legacy-bytes)"; DLG="$("$AM" path "$IDLG")"
sed -i '/^<!-- Replace this section/,/-->$/d' "$DLG/prompt.md"; printf 'task\n' >> "$DLG/prompt.md"
sed -i '2s/^Requester: Codex$/Requester: Co\rdex/' "$DLG/prompt.md"
sed -i 's/^state=draft$/state=published/' "$DLG/meta"     # simulate a store written by an older version
printf 'prompt_sha256=%s\n' "$(sha256sum "$DLG/prompt.md" | cut -d' ' -f1)" >> "$DLG/meta"
assert_eq "$("$AM" status "$IDLG" | val prompt_ok)" "no"
[ -z "$("$AM" list --pending | grep "$IDLG")" ] && ok || fail "legacy control-byte exchange listed as pending"

t "publish: a legitimate task containing the placeholder phrase mid-line still publishes"
IDPP="$(new_in "$TMP/repoB" phrase)"; DPP="$("$AM" path "$IDPP")"
sed -i '/^<!-- Replace this section/,/-->$/d' "$DPP/prompt.md"
printf 'Please Replace this section with the focused request for the reviewer, then send.\n' >> "$DPP/prompt.md"
assert_rc 0 "$AM" publish "$IDPP"

t "wait: --timeout with a leading zero is parsed as decimal (no octal error)"
IDW="$(new_in "$TMP/repoB" timeout-zero)"
"$AM" wait "$IDW" --timeout 08 >/dev/null 2>"$TMP/wait-err"; rc=$?    # draft: times out after 8 s
assert_eq "$rc" 124 "(rc --timeout 08)"
assert_not_grep "value too great" "$TMP/wait-err"

# ===========================================================================
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
