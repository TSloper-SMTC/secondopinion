#!/bin/bash
# Behavioural tests for bin/secondopinion.
# Run: tests/test_secondopinion.sh   (exit 0 = all pass)
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AM="$HERE/../plugins/secondopinion/bin/secondopinion"
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
export HOME="$TMP/home"; mkdir -p "$HOME"     # never let any fallback path touch the real HOME
export SECONDOPINION_DIR="$TMP/store"
export SECONDOPINION_STALE_CLAIM_SECS=3600
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
assert_nofile "$SECONDOPINION_DIR"   # list must not create the store

t "new: creates draft with grammar-valid ID, header, meta, private perms"
ID1="$(new_in "$TMP/repoA-wt" "First Review!")"
[[ "$ID1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z-first-review$ ]] && ok || fail "bad id '$ID1'"
D1="$("$AM" path "$ID1")"
assert_eq "$D1" "$SECONDOPINION_DIR/exchanges/$ID1"
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
assert_eq "$(stat -c %a "$SECONDOPINION_DIR")" "700"
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
assert_rc 0 env SECONDOPINION_STALE_CLAIM_SECS=0 "$AM" claim "$ID4" --owner second --takeover
assert_eq "$("$AM" status "$ID4" | val claimed_by)" "second"
assert_rc 1 env SECONDOPINION_STALE_CLAIM_SECS=0 "$AM" claim "$ID4" --owner third   # without --takeover still refused

t "archive: only answered (or --force); moves dir; idempotent; ID stays reserved"
assert_rc 1 "$AM" archive "$ID2"                    # not answered
assert_rc 0 "$AM" archive "$ID3"
assert_nofile "$SECONDOPINION_DIR/exchanges/$ID3"
assert_file "$SECONDOPINION_DIR/archive/$ID3/response.md"
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
out="$(cd "$TMP" && SECONDOPINION_DIR="$RO/store" "$AM" new --topic blocked 2>&1)"; rc=$?
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
ln -s "$EXT" "$SECONDOPINION_DIR/exchanges/2026-01-01T000000Z-evil"
assert_eq "$("$AM" list --all | grep -c evil)" "0"
assert_rc 1 "$AM" status 2026-01-01T000000Z-evil
assert_rc 1 "$AM" path 2026-01-01T000000Z-evil
assert_rc 1 "$AM" wait 2026-01-01T000000Z-evil --timeout 0
assert_rc 1 "$AM" archive 2026-01-01T000000Z-evil --force
assert_eq "$(grep -c 'state=published' "$EXT/meta")" "1"          # external meta untouched
assert_nofile "$EXT/.lock"
rm -f "$SECONDOPINION_DIR/exchanges/2026-01-01T000000Z-evil"

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
assert_nofile "$SECONDOPINION_DIR/exchanges/$IDA"; assert_file "$SECONDOPINION_DIR/archive/$IDA/response.md"

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

t "env: HOME unset without SECONDOPINION_DIR gives one clear error, not a bash trace"
out="$(env -u HOME -u SECONDOPINION_DIR "$AM" list 2>&1)"; rc=$?
assert_eq "$rc" 1 "(rc HOME unset)"
assert_not_grep "unbound variable" <(echo "$out")
assert_grep "SECONDOPINION_DIR" <(echo "$out")

t "help: usage lists every command"
for c in new publish list status show path claim respond read-response wait archive; do
  assert_grep "\b$c\b" <("$AM" --help 2>&1)
done

# ===========================================================================
# round-3 review regressions (Codex QA of 1.1.0)

t "new: newline in CODEX_THREAD_ID is rejected before any exchange is reserved"
before_count="$(ls "$SECONDOPINION_DIR/exchanges" | wc -l)"
out="$(cd "$TMP/repoB" && CODEX_THREAD_ID=$'qa-thread\ninjected_key=injected_value' "$AM" new --topic thread-injection 2>&1)"; rc=$?
assert_eq "$rc" 1 "(rc newline CODEX_THREAD_ID)"
assert_grep "CODEX_THREAD_ID" <(echo "$out")
assert_eq "$(ls "$SECONDOPINION_DIR/exchanges" | wc -l)" "$before_count" "(no exchange reserved on rejection)"
[ -z "$(ls "$SECONDOPINION_DIR/exchanges" | grep thread-injection)" ] && ok || fail "exchange dir reserved despite rejection"

t "new: control bytes in CODEX_THREAD_ID are rejected"
out="$(cd "$TMP/repoB" && CODEX_THREAD_ID=$'esc\033[31mred' "$AM" new --topic thread-esc 2>&1)"; rc=$?
assert_eq "$rc" 1 "(rc control CODEX_THREAD_ID)"
[ -z "$(ls "$SECONDOPINION_DIR/exchanges" | grep thread-esc)" ] && ok || fail "exchange dir reserved despite rejection"

t "new: a repository path containing a newline is rejected"
NLREPO="$TMP/nl/repo"$'\n'"header-break"; mkdir -p "$TMP/nl"; mkrepo "$NLREPO"
out="$(cd "$NLREPO" && "$AM" new --topic nl-repo 2>&1)"; rc=$?
assert_eq "$rc" 1 "(rc newline repo path)"
assert_grep "repository" <(echo "$out")
[ -z "$(ls "$SECONDOPINION_DIR/exchanges" | grep nl-repo)" ] && ok || fail "exchange dir reserved for newline repo path"

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
# round-5 review regressions (Codex QA of 1.2.1)

t "respond: the header block is validated through the first blank line, not a fixed 20 lines"
IDX="$(new_in "$TMP/repoB" header-21)"; publish_prompt "$IDX" "task"
TX="$("$AM" claim "$IDX" --owner o | val claim_token)"
{ printf 'Exchange-ID: %s\nResponder: R\n' "$IDX"; for N in $(seq 3 20); do printf 'X-%02d: clean\n' "$N"; done; printf 'X-21: bad\033RED\n\nbody\n'; } > "$TMP/resp-21.md"
assert_rc 1 "$AM" respond "$IDX" --token "$TX" --file "$TMP/resp-21.md"
assert_eq "$("$AM" status "$IDX" | val state)" "claimed"

t "respond: a Responder line after the first blank line (in the body) does not count"
printf 'Exchange-ID: %s\n\nResponder: Body Only\n' "$IDX" > "$TMP/resp-bodyresp.md"
assert_rc 1 "$AM" respond "$IDX" --token "$TX" --file "$TMP/resp-bodyresp.md"
assert_eq "$("$AM" status "$IDX" | val state)" "claimed"

t "respond: an oversized header block is rejected rather than silently truncated"
{ printf 'Exchange-ID: %s\nResponder: R\n' "$IDX"; for N in $(seq 3 80); do printf 'X-%02d: clean\n' "$N"; done; printf '\nbody\n'; } > "$TMP/resp-huge.md"
assert_rc 1 "$AM" respond "$IDX" --token "$TX" --file "$TMP/resp-huge.md"
assert_eq "$("$AM" status "$IDX" | val state)" "claimed"

t "respond: a Responder line on header line 6 (inside the header block) is accepted"
printf 'Exchange-ID: %s\nX-2: a\nX-3: b\nX-4: c\nX-5: d\nResponder: Late Header\n\nbody\n' "$IDX" > "$TMP/resp-line6.md"
assert_rc 0 "$AM" respond "$IDX" --token "$TX" --file "$TMP/resp-line6.md"
assert_eq "$("$AM" status "$IDX" | val responder)" "Late Header"

t "publish: a control byte on header line 21 is rejected"
IDQ="$(new_in "$TMP/repoB" prompt-21)"; DQ="$("$AM" path "$IDQ")"
{ printf 'Exchange-ID: %s\nRequester: Codex\n' "$IDQ"; for N in $(seq 3 20); do printf 'X-%02d: clean\n' "$N"; done; printf 'X-21: bad\033RED\n\nTask:\nreal task\n'; } > "$DQ/prompt.md"
assert_rc 1 "$AM" publish "$IDQ"
assert_eq "$("$AM" status "$IDQ" | val state)" "draft"

t "publish: repeating publish on a tampered published prompt reports an integrity failure instead of exit 0"
IDT="$(new_in "$TMP/repoB" republish-tamper)"; publish_prompt "$IDT" "task"; DT="$("$AM" path "$IDT")"
chmod u+w "$DT/prompt.md"; printf '\ntamper\n' >> "$DT/prompt.md"
assert_rc 1 "$AM" publish "$IDT"
assert_eq "$("$AM" status "$IDT" | val prompt_ok)" "no"

t "publish: an indented untouched Task placeholder is still refused"
IDI="$(new_in "$TMP/repoB" indented-placeholder)"; DI="$("$AM" path "$IDI")"
sed -i 's/^<!-- Replace this section/    <!-- Replace this section/' "$DI/prompt.md"
assert_rc 1 "$AM" publish "$IDI"
assert_eq "$("$AM" status "$IDI" | val state)" "draft"

t "claim: a published prompt that fails hash/header validation is refused with an accurate message"
out="$("$AM" claim "$IDT" --owner o 2>&1)"; rc=$?
assert_eq "$rc" 1 "(rc claim tampered)"
assert_grep "validation" <(echo "$out")

# ===========================================================================
# round-6 review regressions (Codex QA of 1.2.2)

t "respond: the 64-record header bound holds when the header runs to EOF (no blank line)"
IDE="$(new_in "$TMP/repoB" header-eof)"; publish_prompt "$IDE" "task"
TE="$("$AM" claim "$IDE" --owner o | val claim_token)"
{ printf 'Exchange-ID: %s\nResponder: EOF64\n' "$IDE"; for N in $(seq 3 64); do printf 'X-%02d: clean\n' "$N"; done; } > "$TMP/resp-eof64.md"     # 64 records, EOF, no blank line
{ printf 'Exchange-ID: %s\nResponder: EOF65\n' "$IDE"; for N in $(seq 3 65); do printf 'X-%02d: clean\n' "$N"; done; } > "$TMP/resp-eof65.md"     # 65 records at EOF
{ printf 'Exchange-ID: %s\nResponder: EOF66\n' "$IDE"; for N in $(seq 3 65); do printf 'X-%02d: clean\n' "$N"; done; printf 'X-66: unterminated'; } > "$TMP/resp-eof66.md"   # 66th record without newline
{ printf 'Exchange-ID: %s\nResponder: B65\n' "$IDE"; for N in $(seq 3 65); do printf 'X-%02d: clean\n' "$N"; done; printf '\nbody\n'; } > "$TMP/resp-blank65.md"   # 65 records then blank
assert_rc 1 "$AM" respond "$IDE" --token "$TE" --file "$TMP/resp-eof65.md"
assert_rc 1 "$AM" respond "$IDE" --token "$TE" --file "$TMP/resp-eof66.md"
assert_rc 1 "$AM" respond "$IDE" --token "$TE" --file "$TMP/resp-blank65.md"
assert_eq "$("$AM" status "$IDE" | val state)" "claimed"
assert_rc 0 "$AM" respond "$IDE" --token "$TE" --file "$TMP/resp-eof64.md"
assert_eq "$("$AM" status "$IDE" | val responder)" "EOF64"

t "respond: header errors name the actual reason (control bytes vs too many lines)"
IDN="$(new_in "$TMP/repoB" header-reason)"; publish_prompt "$IDN" "task"
TN="$("$AM" claim "$IDN" --owner o | val claim_token)"
{ printf 'Exchange-ID: %s\nResponder: R\n' "$IDN"; for N in $(seq 3 65); do printf 'X-%02d: clean\n' "$N"; done; } > "$TMP/resp-lines65.md"
{ printf 'Exchange-ID: %s\nResponder: R\033x\n\nbody\n' "$IDN"; } > "$TMP/resp-ctl.md"
out_lines="$("$AM" respond "$IDN" --token "$TN" --file "$TMP/resp-lines65.md" 2>&1)"
out_ctl="$("$AM" respond "$IDN" --token "$TN" --file "$TMP/resp-ctl.md" 2>&1)"
echo "$out_lines" | grep -qi "lines" && ok || fail "line-bound error does not mention lines: $out_lines"
echo "$out_ctl" | grep -qi "control" && ok || fail "control-byte error does not mention control bytes: $out_ctl"

# ===========================================================================
# round-8 review regressions (Codex QA of 1.3.2)

t "env: a non-integer SECONDOPINION_STALE_CLAIM_SECS is rejected with one clear error"
IDSC="$(new_in "$TMP/repoB" stale-secs)"; publish_prompt "$IDSC" "task"
"$AM" claim "$IDSC" --owner o >/dev/null
out="$(SECONDOPINION_STALE_CLAIM_SECS=abc "$AM" claim "$IDSC" --owner p --takeover 2>&1)"; rc=$?
assert_eq "$rc" 1 "(rc bad STALE_CLAIM_SECS)"
assert_grep "SECONDOPINION_STALE_CLAIM_SECS" <(echo "$out")
assert_not_grep "integer expression expected" <(echo "$out")
assert_eq "$("$AM" status "$IDSC" | val state)" "claimed"

# ===========================================================================
# round-9 review regressions (Codex QA of 1.3.3)

t "env: an out-of-range SECONDOPINION_STALE_CLAIM_SECS (2^64) is refused rather than wrapping to 0 and permitting takeover"
IDOV="$(new_in "$TMP/repoB" stale-overflow)"; publish_prompt "$IDOV" "task"
"$AM" claim "$IDOV" --owner first >/dev/null
out="$(SECONDOPINION_STALE_CLAIM_SECS=18446744073709551616 "$AM" claim "$IDOV" --owner second --takeover 2>&1)"; rc=$?
assert_eq "$rc" 1 "(rc 2^64 STALE_CLAIM_SECS)"
assert_grep "SECONDOPINION_STALE_CLAIM_SECS" <(echo "$out")
assert_eq "$("$AM" status "$IDOV" | val claimed_by)" "first"

t "wait: an out-of-range --timeout (2^64) is refused rather than becoming an immediate timeout"
IDWO="$(new_in "$TMP/repoB" wait-overflow)"
out="$("$AM" wait "$IDWO" --timeout 18446744073709551616 2>&1)"; rc=$?
assert_eq "$rc" 1 "(rc 2^64 --timeout)"
assert_grep "timeout" <(echo "$out")

# ===========================================================================
# round-10 review regressions (Codex QA of 1.3.4)

t "wait: zero-padded decimals are normalized (00000000000 == 0), out-of-range still refused"
IDZ="$(new_in "$TMP/repoB" zero-pad)"
"$AM" wait "$IDZ" --timeout 00000000000 >/dev/null 2>&1; rc=$?
assert_eq "$rc" 124 "(rc --timeout 00000000000 on a draft)"
assert_rc 1 "$AM" wait "$IDZ" --timeout 04294967296

# ===========================================================================
# agent-mailbox rename: compatibility and migration

t "compat: SECONDOPINION_DIR wins; a legacy AGENT_MAILBOX_DIR is honoured with one deprecation warning"
LEG="$TMP/legacy-store"; NEW="$TMP/new-store"
out="$(env -u SECONDOPINION_DIR AGENT_MAILBOX_DIR="$LEG" "$AM" list 2>&1 >/dev/null)"; rc=$?
assert_eq "$rc" 0 "(list via legacy env)"
assert_grep "AGENT_MAILBOX_DIR" <(echo "$out"); assert_grep "SECONDOPINION_DIR" <(echo "$out")
IDL="$(env -u SECONDOPINION_DIR AGENT_MAILBOX_DIR="$LEG" "$AM" new --topic legacy-env 2>/dev/null | val exchange_id)"
[ -d "$LEG/exchanges/$IDL" ] && ok || fail "legacy env var did not select the store"
out="$(SECONDOPINION_DIR="$NEW" AGENT_MAILBOX_DIR="$LEG" "$AM" new --topic both-set 2>&1)"; rc=$?
IDB="$(echo "$out" | val exchange_id)"
[ -d "$NEW/exchanges/$IDB" ] && ok || fail "SECONDOPINION_DIR did not take precedence"
assert_not_grep "deprecated" <(echo "$out")

t "compat: invoking through an 'agent-mailbox' alias works and prints one deprecation line on stderr"
ALIAS="$TMP/aliasbin"; mkdir -p "$ALIAS"; ln -sfn "$AM" "$ALIAS/agent-mailbox"
IDA="$(new_in "$TMP/repoB" alias-topic)"
out_err="$("$ALIAS/agent-mailbox" status "$IDA" 2>&1 >/dev/null)"; rc=$?
assert_eq "$rc" 0 "(alias status)"
assert_eq "$(echo "$out_err" | grep -c "deprecated")" "1"
assert_eq "$("$ALIAS/agent-mailbox" status "$IDA" 2>/dev/null | val state)" "draft"

t "compat: legacy AGENT_MAILBOX_OWNER and AGENT_MAILBOX_STALE_CLAIM_SECS are honoured with a warning"
IDO="$(new_in "$TMP/repoB" legacy-owner)"; publish_prompt "$IDO" "task"
out="$(env -u SECONDOPINION_OWNER AGENT_MAILBOX_OWNER=legacy-owner "$AM" claim "$IDO" 2>&1)"
assert_eq "$(echo "$out" | val claimed_by)" "legacy-owner"
assert_grep "AGENT_MAILBOX_OWNER" <(echo "$out")
out="$(env -u SECONDOPINION_STALE_CLAIM_SECS AGENT_MAILBOX_STALE_CLAIM_SECS=abc "$AM" status "$IDO" 2>&1)"; rc=$?
assert_eq "$rc" 1 "(legacy stale-secs still validated)"

t "compat: with no env and only a legacy ~/.agent-mailbox store, the tool uses it and asks to migrate"
LH="$TMP/legacy-home"; mkdir -p "$LH/.agent-mailbox/exchanges" "$LH/.agent-mailbox/archive"
IDLH="$(cd "$TMP/repoB" && env -u SECONDOPINION_DIR -u AGENT_MAILBOX_DIR HOME="$LH" "$AM" new --topic legacy-home 2>/dev/null | val exchange_id)"
[ -d "$LH/.agent-mailbox/exchanges/$IDLH" ] && ok || fail "legacy store not used"
[ ! -e "$LH/.secondopinion" ] && ok || fail "tool created a second store next to the legacy one"
out="$(env -u SECONDOPINION_DIR -u AGENT_MAILBOX_DIR HOME="$LH" "$AM" list 2>&1 >/dev/null)"
assert_grep "install.sh" <(echo "$out")
# once ~/.secondopinion exists it is preferred silently
mkdir -p "$LH/.secondopinion"
out="$(env -u SECONDOPINION_DIR -u AGENT_MAILBOX_DIR HOME="$LH" "$AM" list 2>&1 >/dev/null)"
assert_eq "$out" "" "(no warning when the new store exists)"

# ===========================================================================
# `ask` — one command that publishes, spawns a headless responder, waits, and prints the answer

STUB_DIR="$TMP/claude-stub"; mkdir -p "$STUB_DIR"
# A stand-in for the `claude` CLI: records its argv, extracts the exchange id from the -p prompt,
# and answers through the real tool exactly like the headless skill would.
cat > "$STUB_DIR/claude" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" > "${STUB_ARGV_FILE:?}"
printf '%s\n' "$PWD" > "${STUB_CWD_FILE:?}"
[ -t 0 ] && echo "stdin-is-tty" >> "${STUB_ARGV_FILE}"
id=""; prev=""; for a in "$@"; do if [ "$prev" = "-p" ]; then printf '%s\n' "$a" > "${STUB_PROMPT_FILE:?}"; id="$(printf '%s\n' "$a" | sed -n 's/^Exchange-ID: //p' | head -1)"; fi; prev="$a"; done
case "${STUB_MODE:-answer}" in
  answer)
    tok="$("$STUB_AM" claim "$id" --owner stub 2>/dev/null | awk -F= '/^claim_token=/{print $2}')"
    printf 'Exchange-ID: %s\nResponder: Stub Claude\n\nverdict: PROVEN stub-answer\n' "$id" > "$STUB_DIR/resp.md"
    "$STUB_AM" respond "$id" --token "$tok" --file "$STUB_DIR/resp.md" >/dev/null 2>&1; echo '{"is_error":false}';;
  slow)   sleep 30;;
  fail)   echo "boom" >&2; exit 1;;
  claimfail) "$STUB_AM" claim "$id" --owner stub >/dev/null 2>&1; echo "boom after claim" >&2; exit 1;;
  claimslow) "$STUB_AM" claim "$id" --owner stub >/dev/null 2>&1; sleep 30;;
esac
STUB
chmod +x "$STUB_DIR/claude"
export STUB_DIR STUB_AM="$AM" STUB_ARGV_FILE="$TMP/stub-argv" STUB_CWD_FILE="$TMP/stub-cwd" STUB_PROMPT_FILE="$TMP/stub-prompt"
printf 'Please check the thing.\nSecond line.\n' > "$TMP/request.md"

t "ask: publishes, spawns the responder in the checkout, waits, prints the validated answer, exit 0"
out="$(cd "$TMP/repoA-wt" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "ask one" --file "$TMP/request.md" --timeout 60 2>"$TMP/ask.err")"; rc=$?
assert_eq "$rc" 0 "(ask rc)"
IDASK="$(echo "$out" | sed -n 's/^Exchange-ID: //p' | head -1)"
[ -n "$IDASK" ] && ok || fail "answer not printed (out: $(echo "$out" | head -3))"
assert_grep "verdict: PROVEN stub-answer" <(echo "$out")
assert_eq "$("$AM" status "$IDASK" | val state)" "answered"
assert_grep "Please check the thing." "$("$AM" path "$IDASK")/prompt.md"          # request text became the Task section
assert_not_grep "Replace this section" "$("$AM" path "$IDASK")/prompt.md"
assert_eq "$(cat "$STUB_CWD_FILE")" "$TMP/repoA-wt" "(responder cwd = the checkout the request was made from)"
# The prompt must be SELF-CONTAINED (mirror of the Claude->Codex plugin, which installs
# nothing in Codex): the full respond workflow inline + the id; no Claude-side skill/plugin.
grep -q -- "^Exchange-ID: $IDASK$" "$STUB_ARGV_FILE" && ok || fail "prompt must end by naming the exchange: 'Exchange-ID: $IDASK'"
grep -q -- "secondopinion claim" "$STUB_ARGV_FILE" && ok || fail "prompt must inline the respond workflow (self-contained; nothing installed in Claude)"
grep -q -- "^/secondopinion-respond" "$STUB_ARGV_FILE" && fail "prompt must not invoke a Claude-side slash command" || ok
grep -q -- "^---$" "$STUB_ARGV_FILE" && fail "skill frontmatter must be stripped from the inline prompt" || ok
assert_eq "$(tail -n1 "$STUB_PROMPT_FILE")" "Exchange-ID: $IDASK" "(the prompt's FINAL line is the assignment)"
grep -qx -- "Bash,Read,Grep,Glob,Write" "$STUB_ARGV_FILE" && ok || fail "default allowlist wrong"
grep -qx -- "Edit,NotebookEdit,WebFetch,WebSearch" "$STUB_ARGV_FILE" && ok || fail "default disallowed-tool list wrong"

t "ask: --model and SECONDOPINION_CLAUDE_ARGS reach the responder argv"
out="$(cd "$TMP/repoA-wt" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" SECONDOPINION_CLAUDE_ARGS="--fallback-model claude-x" "$AM" ask --topic "ask argv" --file "$TMP/request.md" --model claude-test-model --timeout 60 2>/dev/null)"; rc=$?
assert_eq "$rc" 0
grep -qx -- "--model" "$STUB_ARGV_FILE" && grep -qx -- "claude-test-model" "$STUB_ARGV_FILE" && ok || fail "--model not passed through"
grep -qx -- "--fallback-model" "$STUB_ARGV_FILE" && grep -qx -- "claude-x" "$STUB_ARGV_FILE" && ok || fail "SECONDOPINION_CLAUDE_ARGS not appended"
grep -q -- "^dontAsk$" "$STUB_ARGV_FILE" && ok || fail "default (review) profile must use --permission-mode dontAsk"
grep -q -- "^--no-session-persistence$" "$STUB_ARGV_FILE" && ok || fail "responder must not persist sessions"
grep -q "stdin-is-tty" "$STUB_ARGV_FILE" && fail "responder stdin must be /dev/null" || ok

t "ask --write: uses the write profile (acceptEdits) instead of dontAsk"
out="$(cd "$TMP/repoA-wt" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "ask write" --file "$TMP/request.md" --write --timeout 60 2>/dev/null)"; rc=$?
assert_eq "$rc" 0
grep -q -- "^acceptEdits$" "$STUB_ARGV_FILE" && ok || fail "--write must select acceptEdits"

t "ask: responder failure -> exit 1, exchange stays published (retryable), log path reported"
out="$(cd "$TMP/repoA-wt" && STUB_MODE=fail SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "ask fail" --file "$TMP/request.md" --timeout 60 2>&1)"; rc=$?
assert_eq "$rc" 1 "(ask rc on responder failure)"
IDF="$(echo "$out" | sed -n 's/^exchange_id=//p' | head -1)"
assert_eq "$("$AM" status "$IDF" | val state)" "published"
assert_grep "log" <(echo "$out")

t "ask --timeout: a slow responder is killed, exit 124, exchange still pending for a later responder"
out="$(cd "$TMP/repoA-wt" && STUB_MODE=slow SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "ask slow" --file "$TMP/request.md" --timeout 2 2>&1)"; rc=$?
assert_eq "$rc" 124 "(ask rc on timeout)"
IDS="$(echo "$out" | sed -n 's/^exchange_id=//p' | head -1)"
assert_eq "$("$AM" status "$IDS" | val state)" "published"
sleep 1; pgrep -f "STUB_MODE=slow" >/dev/null 2>&1 && fail "slow responder still running after timeout" || ok

t "ask --background: returns immediately with the id; wait/read-response complete later"
out="$(cd "$TMP/repoA-wt" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "ask bg" --file "$TMP/request.md" --background 2>/dev/null)"; rc=$?
assert_eq "$rc" 0
IDB="$(echo "$out" | val exchange_id)"
[ -n "$IDB" ] && ok || fail "no exchange_id printed"
assert_rc 0 "$AM" wait "$IDB" --timeout 30
assert_grep "stub-answer" <("$AM" read-response "$IDB")

t "ask: refuses to start without a claude binary and creates no exchange"
before_count="$(ls "$SECONDOPINION_DIR/exchanges" | wc -l)"
out="$(cd "$TMP/repoA-wt" && SECONDOPINION_CLAUDE="$TMP/does-not-exist" "$AM" ask --topic "no claude" --file "$TMP/request.md" 2>&1)"; rc=$?
assert_eq "$rc" 1
assert_grep "claude" <(echo "$out")
assert_eq "$(ls "$SECONDOPINION_DIR/exchanges" | wc -l)" "$before_count"

t "ask: refuses when the respond instructions are missing next to the CLI, creates no exchange"
mkdir -p "$TMP/lonely/bin"; cp "$AM" "$TMP/lonely/bin/secondopinion"; chmod +x "$TMP/lonely/bin/secondopinion"
before_count="$(ls "$SECONDOPINION_DIR/exchanges" | wc -l)"
out="$(cd "$TMP/repoA-wt" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$TMP/lonely/bin/secondopinion" ask --topic "no skill" --file "$TMP/request.md" 2>&1)"; rc=$?
assert_eq "$rc" 1 "(ask rc without the skill file)"
assert_grep "secondopinion-respond/SKILL.md" <(echo "$out")
assert_eq "$(ls "$SECONDOPINION_DIR/exchanges" | wc -l)" "$before_count" "(no exchange created)"

t "ask: an UNREADABLE respond-instructions file refuses before creating an exchange"
mkdir -p "$TMP/unread/bin" "$TMP/unread/skills/secondopinion-respond"
cp "$AM" "$TMP/unread/bin/secondopinion"; chmod +x "$TMP/unread/bin/secondopinion"
cp "$HERE/../plugins/secondopinion/skills/secondopinion-respond/SKILL.md" "$TMP/unread/skills/secondopinion-respond/SKILL.md"
chmod 000 "$TMP/unread/skills/secondopinion-respond/SKILL.md"
before_count="$(ls "$SECONDOPINION_DIR/exchanges" | wc -l)"
out="$(cd "$TMP/repoA-wt" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$TMP/unread/bin/secondopinion" ask --topic "unreadable" --file "$TMP/request.md" 2>&1)"; rc=$?
assert_eq "$rc" 1 "(ask rc with unreadable instructions)"
assert_eq "$(ls "$SECONDOPINION_DIR/exchanges" | wc -l)" "$before_count" "(no exchange created for unreadable instructions)"
chmod 644 "$TMP/unread/skills/secondopinion-respond/SKILL.md"

t "ask: a zero timeout is refused (GNU timeout 0 would disable the limit), no exchange created"
before_count="$(ls "$SECONDOPINION_DIR/exchanges" | wc -l)"
out="$(cd "$TMP/repoA-wt" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "zero" --file "$TMP/request.md" --timeout 0 2>&1)"; rc=$?
assert_eq "$rc" 1 "(ask rc --timeout 0)"
out="$(cd "$TMP/repoA-wt" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" SECONDOPINION_ASK_TIMEOUT=0 "$AM" ask --topic "zero env" --file "$TMP/request.md" 2>&1)"; rc=$?
assert_eq "$rc" 1 "(ask rc SECONDOPINION_ASK_TIMEOUT=0)"
assert_eq "$(ls "$SECONDOPINION_DIR/exchanges" | wc -l)" "$before_count" "(no exchange created for zero timeouts)"

t "ask: responder that CLAIMS and then fails/times out is reported as claimed with the takeover path, not as published"
out="$(cd "$TMP/repoA-wt" && STUB_MODE=claimfail SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "claim fail" --file "$TMP/request.md" --timeout 60 2>&1)"; rc=$?
assert_eq "$rc" 1 "(ask rc on claim-then-fail)"
IDCF="$(echo "$out" | sed -n 's/^exchange_id=//p' | head -1)"
assert_eq "$("$AM" status "$IDCF" | val state)" "claimed"
echo "$out" | grep -q "state=claimed" && ok || fail "claim-then-fail does not report state=claimed: $out"
echo "$out" | grep -qi "takeover" && ok || fail "claim-then-fail does not mention the takeover path: $out"
echo "$out" | grep -q "stays published" && fail "claim-then-fail still claims the exchange stays published" || ok
out="$(cd "$TMP/repoA-wt" && STUB_MODE=claimslow SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "claim slow" --file "$TMP/request.md" --timeout 2 2>&1)"; rc=$?
assert_eq "$rc" 124 "(ask rc on claim-then-timeout)"
echo "$out" | grep -q "state=claimed" && ok || fail "claim-then-timeout does not report state=claimed: $out"
echo "$out" | grep -qi "takeover" && ok || fail "claim-then-timeout does not mention the takeover path: $out"

t "ask --background: the printed state is read from meta, not hardcoded"
out="$(cd "$TMP/repoA-wt" && STUB_MODE=slow SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "bg state" --file "$TMP/request.md" --background 2>/dev/null)"; rc=$?
assert_eq "$rc" 0
IDBS="$(echo "$out" | val exchange_id)"
assert_eq "$(echo "$out" | val state)" "$("$AM" status "$IDBS" | val state)" "(reported state matches meta)"

t "archive relocates the responder log into the archived exchange (no errant files left behind)"
[ -f "$SECONDOPINION_DIR/responder-logs/$IDASK.log" ] && ok || fail "fixture: responder log missing for $IDASK"
assert_rc 0 "$AM" archive "$IDASK"
[ ! -e "$SECONDOPINION_DIR/responder-logs/$IDASK.log" ] && ok || fail "responder log left orphaned in responder-logs/ after archive"
[ -f "$SECONDOPINION_DIR/archive/$IDASK/responder.log" ] && ok || fail "responder log not preserved inside the archived exchange"
assert_eq "$("$AM" status "$IDASK" | val responder_log)" "$SECONDOPINION_DIR/archive/$IDASK/responder.log" "(meta responder_log updated to the relocated path)"
# repair path: an orphan log for an ALREADY archived exchange is relocated by a re-archive
echo "orphan" > "$SECONDOPINION_DIR/responder-logs/$IDASK.log"; rm -f "$SECONDOPINION_DIR/archive/$IDASK/responder.log"
assert_rc 0 "$AM" archive "$IDASK"
[ ! -e "$SECONDOPINION_DIR/responder-logs/$IDASK.log" ] && [ -f "$SECONDOPINION_DIR/archive/$IDASK/responder.log" ] && ok || fail "re-archive did not repair an orphaned responder log"

t "ask: task text via --task and via stdin (-)"
out="$(cd "$TMP/repoA-wt" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "ask task" --task "Inline task text" --timeout 60 2>/dev/null)"; rc=$?
assert_eq "$rc" 0
IDT="$(echo "$out" | sed -n 's/^Exchange-ID: //p' | head -1)"; assert_grep "Inline task text" "$("$AM" path "$IDT")/prompt.md"
out="$(cd "$TMP/repoA-wt" && printf 'Piped task\n' | SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "ask stdin" --file - --timeout 60 2>/dev/null)"; rc=$?
assert_eq "$rc" 0
IDP="$(echo "$out" | sed -n 's/^Exchange-ID: //p' | head -1)"; assert_grep "Piped task" "$("$AM" path "$IDP")/prompt.md"

# ===========================================================================
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
