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
mkdir -p "$TMP/fixed-clock"
printf '%s\n' '#!/bin/sh' \
  'if [ "$#" -eq 1 ] && [ "$1" = "+%s" ] && [ -n "${FAKE_EPOCH:-}" ]; then' \
  '  printf "%s\\n" "$FAKE_EPOCH"' \
  'else' \
  '  exec /usr/bin/date "$@"' \
  'fi' > "$TMP/fixed-clock/date"
chmod +x "$TMP/fixed-clock/date"
export SECONDOPINION_STALE_CLAIM_SECS=3600
# Several cases assert the default-off path before enabling auto-prune locally.
# Keep those cases independent of the invoking user's retention policy.
unset SECONDOPINION_AUTO_PRUNE SECONDOPINION_MAX_TURNS SECONDOPINION_PROGRESS_SECS SECONDOPINION_PROGRESS_MODE CODEX_THREAD_ID
export SECONDOPINION_ASK_GRACE=0

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
wait_exchange_slug() { # wait_exchange_slug <slug> -> id created by a concurrent foreground ask
  local slug="$1" d i
  for i in $(seq 1 100); do
    for d in "$SECONDOPINION_DIR/exchanges/"*-"$slug"; do
      [ -d "$d" ] || continue
      printf '%s\n' "${d##*/}"
      return 0
    done
    sleep 0.1
  done
  return 1
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
out="$("$AM" show "$ID2" 2>&1)"; rc=$?
assert_eq "$rc" 1 "(show refuses a hash-invalid prompt)"
assert_grep "validation" <(echo "$out")
assert_not_grep "sneaky edit" <(echo "$out")

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
IDSHOWDRAFT="$(new_in "$TMP/repoA" "show draft")"
assert_grep "Task:" <("$AM" show "$IDSHOWDRAFT")
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

t "claim: a foreground launch reservation refuses manual theft but admits its matching child"
IDRES="$(new_in "$TMP/repoA" "claim reservation")"; publish_prompt "$IDRES" "task"
RUNRES="0123456789abcdef0123456789abcdef"
printf 'responder_run_id=%s\nresponder_outcome=running\nresponder_pid=\nresponder_starttime=\nask_started_epoch=%s\n' "$RUNRES" "$(date +%s)" >> "$("$AM" path "$IDRES")/meta"
assert_eq "$("$AM" status "$IDRES" | val responder_status)" "launching"
assert_grep "responder launching" <("$AM" status "$IDRES")
out="$("$AM" claim "$IDRES" --owner manual-racer 2>&1)"; rc=$?
assert_eq "$rc" 1 "(manual claim during launch reservation)"
assert_grep "foreground responder is being launched" <(echo "$out")
CRES="$(SECONDOPINION_RUN_ID="$RUNRES" "$AM" claim "$IDRES" --owner matching-child)"; rc=$?
assert_eq "$rc" 0 "(matching child claim)"
TOKRES="$(echo "$CRES" | val claim_token)"; write_response "$IDRES" "$TMP/reservation.md"
assert_rc 0 "$AM" respond "$IDRES" --token "$TOKRES" --file "$TMP/reservation.md"

t "claim: launch reservation is active at age 4, exited at age 5, and manually recoverable"
IDRSTALE="$(new_in "$TMP/repoA" "stale claim reservation")"; publish_prompt "$IDRSTALE" "task"
CLOCK_EPOCH=2000000000
printf 'responder_run_id=abcdef0123456789abcdef0123456789\nresponder_outcome=running\nresponder_pid=\nresponder_starttime=\nask_started_epoch=%s\n' "$((CLOCK_EPOCH - 4))" >> "$("$AM" path "$IDRSTALE")/meta"
assert_eq "$(FAKE_EPOCH="$CLOCK_EPOCH" PATH="$TMP/fixed-clock:$PATH" "$AM" status "$IDRSTALE" | val responder_status)" "launching"
sed -i "s/^ask_started_epoch=.*/ask_started_epoch=$((CLOCK_EPOCH - 5))/" "$("$AM" path "$IDRSTALE")/meta"
assert_eq "$(FAKE_EPOCH="$CLOCK_EPOCH" PATH="$TMP/fixed-clock:$PATH" "$AM" status "$IDRSTALE" | val responder_status)" "exited"
CRSTALE="$(FAKE_EPOCH="$CLOCK_EPOCH" PATH="$TMP/fixed-clock:$PATH" "$AM" claim "$IDRSTALE" --owner recovery-responder)"; rc=$?
assert_eq "$rc" 0 "(manual claim after abandoned launch bound)"
TRSTALE="$(echo "$CRSTALE" | val claim_token)"; write_response "$IDRSTALE" "$TMP/stale-reservation.md"
assert_rc 0 "$AM" respond "$IDRSTALE" --token "$TRSTALE" --file "$TMP/stale-reservation.md"

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
if [ "${1:-}" = "--help" ] && [ -n "${STUB_LARGE_HELP:-}" ]; then
  exec python3 -c 'import sys,time; print("--safe-mode",flush=True); time.sleep(.1); print("help padding "*65536)'
fi
if [ "${1:-}" = "--help" ]; then
  echo "  --safe-mode                            Disable hooks, plugins, auto-memory and startup files"
  echo "  --effort <level>                       Effort level (low, medium, high, xhigh, max)"
  exit 0
fi
printf '%s\n' "$@" > "${STUB_ARGV_FILE:?}"
printf '%s\n' "$PWD" > "${STUB_CWD_FILE:?}"
[ -t 0 ] && echo "stdin-is-tty" >> "${STUB_ARGV_FILE}"
id=""; prev=""; for a in "$@"; do if [ "$prev" = "-p" ]; then printf '%s\n' "$a" > "${STUB_PROMPT_FILE:?}"; id="$(printf '%s\n' "$a" | sed -n 's/^Exchange-ID: //p' | head -1)"; fi; prev="$a"; done
case "${STUB_MODE:-answer}" in
  answer)
    tok="$("$STUB_AM" claim "$id" --owner stub 2>/dev/null | awk -F= '/^claim_token=/{print $2}')"
    printf 'Exchange-ID: %s\nResponder: Stub Claude\n\nverdict: PROVEN stub-answer\n' "$id" > "$STUB_DIR/resp.md"
    "$STUB_AM" respond "$id" --token "$tok" --file "$STUB_DIR/resp.md" >/dev/null 2>&1; echo '{"type":"result","subtype":"success","is_error":false}';;
  progress)
    echo '{"type":"system","subtype":"init","model":"claude-stub-progress"}'
    sleep 2
    echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"rg -n reliability plugins/secondopinion"}}]}}'
    echo '{"type":"user","message":{"content":[{"type":"tool_result","content":"matching source found"}]}}'
    sleep 2
    tok="$("$STUB_AM" claim "$id" --owner stub-progress 2>/dev/null | awk -F= '/^claim_token=/{print $2}')"
    printf 'Exchange-ID: %s\nResponder: Stub Claude\n\nverdict: PROVEN progress-answer\n' "$id" > "$STUB_DIR/resp.md"
    "$STUB_AM" respond "$id" --token "$tok" --file "$STUB_DIR/resp.md" >/dev/null 2>&1
    echo '{"type":"result","subtype":"success","is_error":false}';;
  graceanswer)
    tok="$("$STUB_AM" claim "$id" --owner stub-grace 2>/dev/null | awk -F= '/^claim_token=/{print $2}')"
    sleep 3
    printf 'Exchange-ID: %s\nResponder: Stub Claude\n\nverdict: PROVEN grace-answer\n' "$id" > "$STUB_DIR/resp.md"
    "$STUB_AM" respond "$id" --token "$tok" --file "$STUB_DIR/resp.md" >/dev/null 2>&1
    echo '{"type":"result","subtype":"success","is_error":false}';;
  slow)   sleep 30;;
  successnoanswer) echo '{"type":"result","subtype":"success","is_error":false}'; exit 0;;
  fail)   echo "boom" >&2; exit 1;;
  authfail)
    echo '{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["API Error: 401 authentication_failed: OAuth access token has expired"]}'
    exit 1;;
  claimignoreterm)
    "$STUB_AM" claim "$id" --owner stub-ignore-term >/dev/null 2>&1
    trap '' TERM
    while :; do sleep 1; done;;
  claimfail) "$STUB_AM" claim "$id" --owner stub >/dev/null 2>&1; echo "boom after claim" >&2; exit 1;;
  claimslow) "$STUB_AM" claim "$id" --owner stub >/dev/null 2>&1; sleep 30;;
  foreignclaimfail)
    "$STUB_AM" claim "$id" --owner foreign-stub >/dev/null 2>&1
    d="$($STUB_AM path "$id")"
    ( exec 9>>"$d/.lock"; flock 9; sed -i 's/^claim_run_id=.*/claim_run_id=ffffffffffffffffffffffffffffffff/' "$d/meta" )
    echo "boom after foreign claim" >&2; exit 1;;
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
assert_eq "$("$AM" status "$IDASK" | val responder_completion)" "validated-answer"
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
grep -qx -- "stream-json" "$STUB_ARGV_FILE" && ok || fail "ask must request stream-json for observable progress"
grep -qx -- "--verbose" "$STUB_ARGV_FILE" && ok || fail "stream-json requires --verbose"
grep -qx -- "--safe-mode" "$STUB_ARGV_FILE" && ok || fail "headless responder must suppress user hooks/plugins and session-env setup"

t "ask: safe-mode capability probe drains help output without killing its producer"
out="$(cd "$TMP/repoA-wt" && STUB_LARGE_HELP=1 SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "large help" --file "$TMP/request.md" --timeout 30 2>"$TMP/large-help.err")"; rc=$?
assert_eq "$rc" 0 "(supported CLI with large delayed help output)"
assert_grep "verdict: PROVEN stub-answer" <(echo "$out")

t "ask: default progress is quiet while status retains detailed heartbeat/activity evidence"
out="$(cd "$TMP/repoA-wt" && STUB_MODE=progress SECONDOPINION_PROGRESS_SECS=1 SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "ask progress" --file "$TMP/request.md" --timeout 30 2>"$TMP/progress.err")"; rc=$?
assert_eq "$rc" 0 "(progress ask rc)"
IDPROG="$(echo "$out" | sed -n 's/^Exchange-ID: //p' | head -1)"
assert_grep "^Claude is still working — .* elapsed; waiting for results\.$" "$TMP/progress.err"
assert_not_grep "events=" "$TMP/progress.err"
assert_not_grep "rg -n reliability" "$TMP/progress.err"
PROG_EVENTS="$("$AM" status "$IDPROG" | val responder_event_count)"
[ "$PROG_EVENTS" -ge 2 ] && ok || fail "progress monitor recorded only $PROG_EVENTS stream event(s)"
PROG_STATUS="$("$AM" status "$IDPROG")"
assert_grep "rg -n reliability" <(echo "$PROG_STATUS")

t "ask --verbose-progress: opt-in diagnostics include deadlines, events, activity age and last action"
out="$(cd "$TMP/repoA-wt" && STUB_MODE=progress SECONDOPINION_PROGRESS_SECS=1 SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "ask verbose progress" --file "$TMP/request.md" --timeout 30 --verbose-progress 2>"$TMP/progress-verbose.err")"; rc=$?
assert_eq "$rc" 0 "(verbose progress ask rc)"
assert_grep "primary=30s work-deadline=30s" "$TMP/progress-verbose.err"
assert_grep "events=" "$TMP/progress-verbose.err"
assert_grep "tool Bash: rg -n reliability" "$TMP/progress-verbose.err"

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

t "ask grace: the primary deadline only notifies and an answer inside unconditional grace succeeds"
T0="$(date +%s)"
out="$(cd "$TMP/repoA-wt" && STUB_MODE=graceanswer SECONDOPINION_PROGRESS_SECS=1 SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "ask grace answer" --file "$TMP/request.md" --timeout 2 --grace 3 2>"$TMP/grace-answer.err")"; rc=$?
T1="$(date +%s)"
assert_eq "$rc" 0 "(answer inside grace rc)"
IDGA="$(echo "$out" | sed -n 's/^Exchange-ID: //p' | head -1)"
assert_grep "grace-answer" <(echo "$out")
[ $((T1 - T0)) -ge 3 ] && ok || fail "grace fixture returned before its delayed answer"
GAST="$("$AM" status "$IDGA")"
assert_eq "$(echo "$GAST" | val requested_timeout_secs)" "2"
assert_eq "$(echo "$GAST" | val requested_grace_secs)" "3"
assert_eq "$(echo "$GAST" | val hard_timeout_secs)" "5"
[ -n "$(echo "$GAST" | val deadline_notice_utc)" ] && ok || fail "primary deadline notification was not recorded"

t "ask grace: without an override grace defaults to the primary duration and the work deadline stays bounded"
T0="$(date +%s)"
out="$(cd "$TMP/repoA-wt" && env -u SECONDOPINION_ASK_GRACE STUB_MODE=slow SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "ask default grace" --file "$TMP/request.md" --timeout 2 2>&1)"; rc=$?
T1="$(date +%s)"
assert_eq "$rc" 124 "(default grace work-deadline rc)"
[ $((T1 - T0)) -ge 4 ] && ok || fail "default grace did not preserve the run through the 4s work deadline"
[ $((T1 - T0)) -le 8 ] && ok || fail "TERM-responsive run did not stop promptly (elapsed $((T1-T0))s)"
assert_grep "work deadline reached after 4s" <(echo "$out")

t "ask/review --background: reject before creating an exchange"
before_count="$(ls "$SECONDOPINION_DIR/exchanges" | wc -l)"
out="$(cd "$TMP/repoA-wt" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "removed background" --file "$TMP/request.md" --background 2>&1)"; rc=$?
assert_eq "$rc" 1 "(ask --background rc)"
assert_grep "removed" <(echo "$out")
out="$(cd "$TMP/repoA-wt" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" review --task "short focus" --background 2>&1)"; rc=$?
assert_eq "$rc" 1 "(review --background rc)"
assert_grep "removed" <(echo "$out")
assert_eq "$(ls "$SECONDOPINION_DIR/exchanges" | wc -l)" "$before_count" "(removed option creates no exchange)"

t "ask: refuses to start without a claude binary and creates no exchange"
before_count="$(ls "$SECONDOPINION_DIR/exchanges" | wc -l)"
out="$(cd "$TMP/repoA-wt" && SECONDOPINION_CLAUDE="$TMP/does-not-exist" "$AM" ask --topic "no claude" --file "$TMP/request.md" 2>&1)"; rc=$?
assert_eq "$rc" 1
assert_grep "claude" <(echo "$out")
assert_eq "$(ls "$SECONDOPINION_DIR/exchanges" | wc -l)" "$before_count"

t "ask: responder exit zero without a validated answer is explicitly classified as incomplete"
out="$(cd "$TMP/repoA-wt" && STUB_MODE=successnoanswer SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "zero without answer" --file "$TMP/request.md" --timeout 30 2>&1)"; rc=$?
assert_eq "$rc" 1 "(zero exit without answer rc)"
IDZWA="$(echo "$out" | val exchange_id)"
ZWAST="$("$AM" status "$IDZWA")"
assert_eq "$(echo "$ZWAST" | val responder_exit_code)" "0"
assert_eq "$(echo "$ZWAST" | val responder_outcome)" "responder-exit-0-without-valid-answer"
assert_eq "$(echo "$ZWAST" | val responder_completion)" "no-valid-answer"

t "ask: refuses an older Claude CLI without safe mode before creating an exchange"
mkdir -p "$TMP/old-claude"; printf '#!/bin/bash\necho "Claude Code old help"\n' > "$TMP/old-claude/claude"; chmod +x "$TMP/old-claude/claude"
before_count="$(ls "$SECONDOPINION_DIR/exchanges" | wc -l)"
out="$(cd "$TMP/repoA-wt" && SECONDOPINION_CLAUDE="$TMP/old-claude/claude" "$AM" ask --topic "old claude" --file "$TMP/request.md" 2>&1)"; rc=$?
assert_eq "$rc" 1
assert_grep "update Claude Code" <(echo "$out")
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

t "ask: grace accepts zero, rejects malformed/overflow values, and creates no exchange on rejection"
before_count="$(ls "$SECONDOPINION_DIR/exchanges" | wc -l)"
assert_rc 1 env SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "bad grace" --file "$TMP/request.md" --timeout 2 --grace abc
assert_rc 1 env SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "overflow grace" --file "$TMP/request.md" --timeout 4294967295 --grace 1
assert_eq "$(ls "$SECONDOPINION_DIR/exchanges" | wc -l)" "$before_count" "(no exchange created for invalid grace)"

t "ask: a foreground responder's exact failed/timed-out claim is safely released for immediate retry"
out="$(cd "$TMP/repoA-wt" && STUB_MODE=claimfail SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "claim fail" --file "$TMP/request.md" --timeout 60 2>&1)"; rc=$?
assert_eq "$rc" 1 "(ask rc on claim-then-fail)"
IDCF="$(echo "$out" | sed -n 's/^exchange_id=//p' | head -1)"
assert_eq "$("$AM" status "$IDCF" | val state)" "published"
[ ! -e "$("$AM" path "$IDCF")/claim" ] && ok || fail "failed foreground responder left a claim behind"
assert_grep "safely released" <(echo "$out")
out="$(cd "$TMP/repoA-wt" && STUB_MODE=claimslow SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "claim slow" --file "$TMP/request.md" --timeout 2 2>&1)"; rc=$?
assert_eq "$rc" 124 "(ask rc on claim-then-timeout)"
IDCS="$(echo "$out" | sed -n 's/^exchange_id=//p' | head -1)"
assert_eq "$("$AM" status "$IDCS" | val state)" "published"
[ ! -e "$("$AM" path "$IDCS")/claim" ] && ok || fail "timed-out foreground responder left a claim behind"
assert_grep "retry immediately" <(echo "$out")

t "ask: failed foreground recovery never releases a different or uncorrelated claim"
out="$(cd "$TMP/repoA-wt" && STUB_MODE=foreignclaimfail SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "foreign claim fail" --file "$TMP/request.md" --timeout 60 2>&1)"; rc=$?
assert_eq "$rc" 1 "(ask rc on foreign claim failure)"
IDFC="$(echo "$out" | sed -n 's/^exchange_id=//p' | head -1)"
assert_eq "$("$AM" status "$IDFC" | val state)" "claimed"
[ -d "$("$AM" path "$IDFC")/claim" ] && ok || fail "uncorrelated claim was incorrectly removed"
assert_grep "claim was preserved" <(echo "$out")

t "archive relocates the responder log into the archived exchange (no errant files left behind)"
ASK_LOG="$($AM status "$IDASK" | val responder_log)"; ASK_LOG_BASE="${ASK_LOG##*/}"
[ -f "$ASK_LOG" ] && ok || fail "fixture: responder log missing for $IDASK"
assert_rc 0 "$AM" archive "$IDASK"
[ ! -e "$ASK_LOG" ] && ok || fail "responder log left orphaned in responder-logs/ after archive"
[ -f "$SECONDOPINION_DIR/archive/$IDASK/responder-logs/$ASK_LOG_BASE" ] && ok || fail "responder log not preserved inside the archived exchange"
assert_eq "$("$AM" status "$IDASK" | val responder_log)" "$SECONDOPINION_DIR/archive/$IDASK/responder-logs/$ASK_LOG_BASE" "(meta responder_log updated to the relocated path)"
# repair path: an orphan log for an ALREADY archived exchange is relocated by a re-archive
echo "orphan" > "$SECONDOPINION_DIR/responder-logs/$IDASK.log"
assert_rc 0 "$AM" archive "$IDASK"
[ ! -e "$SECONDOPINION_DIR/responder-logs/$IDASK.log" ] && [ -f "$SECONDOPINION_DIR/archive/$IDASK/responder-logs/$IDASK.log" ] && ok || fail "re-archive did not repair an orphaned responder log"
# collision repair: a later legacy log is disambiguated, never left behind or overwritten
echo "orphan-two" > "$SECONDOPINION_DIR/responder-logs/$IDASK.log"
assert_rc 0 "$AM" archive "$IDASK"
[ ! -e "$SECONDOPINION_DIR/responder-logs/$IDASK.log" ] && [ -f "$SECONDOPINION_DIR/archive/$IDASK/responder-logs/$IDASK.log.2" ] && ok || fail "colliding orphan responder log was not disambiguated into the archive"
assert_grep "orphan" "$SECONDOPINION_DIR/archive/$IDASK/responder-logs/$IDASK.log"
assert_grep "orphan-two" "$SECONDOPINION_DIR/archive/$IDASK/responder-logs/$IDASK.log.2"

t "ask: task text via --task and via stdin (-)"
out="$(cd "$TMP/repoA-wt" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "ask task" --task "Inline task text" --timeout 60 2>/dev/null)"; rc=$?
assert_eq "$rc" 0
IDT="$(echo "$out" | sed -n 's/^Exchange-ID: //p' | head -1)"; assert_grep "Inline task text" "$("$AM" path "$IDT")/prompt.md"
out="$(cd "$TMP/repoA-wt" && printf 'Piped task\n' | SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "ask stdin" --file - --timeout 60 2>/dev/null)"; rc=$?
assert_eq "$rc" 0
IDP="$(echo "$out" | sed -n 's/^Exchange-ID: //p' | head -1)"; assert_grep "Piped task" "$("$AM" path "$IDP")/prompt.md"

t "ask: detailed inline tasks are rejected before exchange creation; the same text works through --file"
LONGTASK="$(printf '%0241d' 0 | tr 0 x)"
before_count="$(ls "$SECONDOPINION_DIR/exchanges" | wc -l)"
out="$(cd "$TMP/repoA-wt" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "oversized task" --task "$LONGTASK" --timeout 60 2>&1)"; rc=$?
assert_eq "$rc" 1 "(oversized inline task rc)"
assert_grep "private request file" <(echo "$out")
out="$(cd "$TMP/repoA-wt" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "multiline task" --task $'first line\nsecond line' --timeout 60 2>&1)"; rc=$?
assert_eq "$rc" 1 "(multiline inline task rc)"
assert_eq "$(ls "$SECONDOPINION_DIR/exchanges" | wc -l)" "$before_count" "(inline-task rejection created an exchange)"
printf '%s\n' "$LONGTASK" > "$TMP/long-request.md"
out="$(cd "$TMP/repoA-wt" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "file-backed task" --file "$TMP/long-request.md" --timeout 60 2>/dev/null)"; rc=$?
assert_eq "$rc" 0 "(file-backed detailed task rc)"

t "new/ask: topics are one line and bounded before an exchange is created"
LONGTOPIC="$(printf '%0121d' 0 | tr 0 t)"
before_count="$(ls "$SECONDOPINION_DIR/exchanges" | wc -l)"
out="$(cd "$TMP/repoA-wt" && "$AM" new --topic "$LONGTOPIC" 2>&1)"; rc=$?
assert_eq "$rc" 1 "(oversized new topic rc)"
assert_grep "--topic is limited" <(echo "$out")
out="$(cd "$TMP/repoA-wt" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "$LONGTOPIC" --file "$TMP/request.md" 2>&1)"; rc=$?
assert_eq "$rc" 1 "(oversized ask topic rc)"
out="$(cd "$TMP/repoA-wt" && "$AM" new --topic $'first\nsecond' 2>&1)"; rc=$?
assert_eq "$rc" 1 "(multiline topic rc)"
assert_eq "$(ls "$SECONDOPINION_DIR/exchanges" | wc -l)" "$before_count" "(topic rejection created an exchange)"

# ===========================================================================
# --- reliability hardening: empty meta values, orphans, lock waits, rollforward

t "list: an exchange with an empty created_epoch lists with age '-' and never crashes or truncates the listing"
IDRC="$(new_in "$TMP/repoA" "hardening corrupt epoch")"
sed -i 's/^created_epoch=.*/created_epoch=/' "$("$AM" path "$IDRC")/meta"
IDRH="$(new_in "$TMP/repoA" "hardening healthy after")"
out="$("$AM" list --all 2>"$TMP/hard-list.err")"; rc=$?
assert_eq "$rc" 0 "(list rc with empty created_epoch)"
assert_not_grep "syntax error" "$TMP/hard-list.err"
assert_grep "$IDRH" <(echo "$out")
echo "$out" | grep "^$IDRC" | grep -q "	-	" && ok || fail "corrupt-epoch row missing or lacks '-' age"

t "jobs: same corrupt exchange never crashes or truncates jobs output"
out="$(cd "$TMP/repoA" && "$AM" jobs 2>"$TMP/hard-jobs.err")"; rc=$?
assert_eq "$rc" 0 "(jobs rc with empty created_epoch)"
assert_not_grep "syntax error" "$TMP/hard-jobs.err"
assert_grep "$IDRH" <(echo "$out")

t "claim: empty claimed_epoch refuses takeover cleanly (fail-safe, no arithmetic crash)"
IDCE="$(new_in "$TMP/repoA" "hardening claimed epoch")"; publish_prompt "$IDCE" "task"
"$AM" claim "$IDCE" --owner first >/dev/null
sed -i 's/^claimed_epoch=.*/claimed_epoch=/' "$("$AM" path "$IDCE")/meta"
out="$("$AM" claim "$IDCE" --owner second --takeover 2>&1)"; rc=$?
assert_eq "$rc" 1 "(claim rc on empty claimed_epoch)"
assert_grep "already claimed" <(echo "$out")
assert_not_grep "syntax error" <(echo "$out")

t "status: claimed exchange with empty claimed_epoch stays reportable"
out="$("$AM" status "$IDCE" 2>&1)"; rc=$?
assert_eq "$rc" 0 "(status rc on empty claimed_epoch)"
assert_not_grep "syntax error" <(echo "$out")

t "status: meta-less exchange dir reports a clean error, not a raw cat failure"
mkdir -p "$SECONDOPINION_DIR/exchanges/2026-01-01T000000Z-hardening-metaless"
out="$("$AM" status 2026-01-01T000000Z-hardening-metaless 2>&1)"; rc=$?
assert_eq "$rc" 1 "(status rc on meta-less dir)"
assert_grep "no meta" <(echo "$out")
assert_not_grep "cat:" <(echo "$out")

t "lock: a held exchange lock times out with a clear error instead of hanging forever"
IDLK="$(new_in "$TMP/repoA" "hardening lock wait")"; publish_prompt "$IDLK" "task"
( exec 9>>"$("$AM" path "$IDLK")/.lock"; flock 9; sleep 6 ) & HOLDER=$!
sleep 0.3
T0=$(date +%s)
out="$(SECONDOPINION_LOCK_WAIT_SECS=1 "$AM" claim "$IDLK" --owner waiter 2>&1)"; rc=$?
T1=$(date +%s)
assert_eq "$rc" 1 "(claim rc on held lock)"
[ $((T1 - T0)) -le 4 ] && ok || fail "lock wait did not time out (took $((T1-T0))s)"
assert_grep "busy" <(echo "$out")
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null

t "env: a non-integer SECONDOPINION_LOCK_WAIT_SECS is rejected with one clear error"
out="$(SECONDOPINION_LOCK_WAIT_SECS=abc "$AM" status "$IDLK" 2>&1)"; rc=$?
assert_eq "$rc" 1 "(rc bad LOCK_WAIT_SECS)"
assert_grep "SECONDOPINION_LOCK_WAIT_SECS" <(echo "$out")

t "env: SECONDOPINION_PROGRESS_SECS must be a positive integer"
out="$(SECONDOPINION_PROGRESS_SECS=0 "$AM" status "$IDLK" 2>&1)"; rc=$?
assert_eq "$rc" 1 "(rc zero PROGRESS_SECS)"
assert_grep "SECONDOPINION_PROGRESS_SECS" <(echo "$out")
out="$(SECONDOPINION_PROGRESS_SECS=abc "$AM" status "$IDLK" 2>&1)"; rc=$?
assert_eq "$rc" 1 "(rc bad PROGRESS_SECS)"

t "env: SECONDOPINION_PROGRESS_MODE accepts quiet/verbose only"
assert_rc 0 env SECONDOPINION_PROGRESS_MODE=quiet "$AM" status "$IDLK"
assert_rc 0 env SECONDOPINION_PROGRESS_MODE=verbose "$AM" status "$IDLK"
out="$(SECONDOPINION_PROGRESS_MODE=noisy "$AM" status "$IDLK" 2>&1)"; rc=$?
assert_eq "$rc" 1 "(rc bad PROGRESS_MODE)"
assert_grep "SECONDOPINION_PROGRESS_MODE" <(echo "$out")

t "wait: finalizes a valid on-disk response left by a responder that died before meta finalize"
IDRF="$(new_in "$TMP/repoA" "hardening rollforward wait")"; publish_prompt "$IDRF" "task"
"$AM" claim "$IDRF" --owner doomed >/dev/null
write_response "$IDRF" "$TMP/rollforward.md"
cp "$TMP/rollforward.md" "$("$AM" path "$IDRF")/response.md"; chmod 600 "$("$AM" path "$IDRF")/response.md"
assert_eq "$("$AM" status "$IDRF" | val state)" "claimed" "(fixture: still claimed)"
assert_rc 0 "$AM" wait "$IDRF" --timeout 5
assert_eq "$("$AM" status "$IDRF" | val state)" "answered" "(state after wait rollforward)"
assert_grep "PROVEN ok" <("$AM" read-response "$IDRF")

t "result: performs the same roll-forward"
IDRF2="$(new_in "$TMP/repoA" "hardening rollforward result")"; publish_prompt "$IDRF2" "task"
"$AM" claim "$IDRF2" --owner doomed >/dev/null
write_response "$IDRF2" "$TMP/rollforward2.md"
cp "$TMP/rollforward2.md" "$("$AM" path "$IDRF2")/response.md"; chmod 600 "$("$AM" path "$IDRF2")/response.md"
assert_grep "PROVEN ok" <("$AM" result "$IDRF2" 2>/dev/null)
assert_eq "$("$AM" status "$IDRF2" | val state)" "answered" "(state after result rollforward)"

t "wait: an INVALID on-disk response while claimed is never finalized"
IDRB="$(new_in "$TMP/repoA" "hardening rollforward bad")"; publish_prompt "$IDRB" "task"
"$AM" claim "$IDRB" --owner doomed >/dev/null
printf 'not a valid response\n' > "$("$AM" path "$IDRB")/response.md"; chmod 600 "$("$AM" path "$IDRB")/response.md"
assert_rc 124 "$AM" wait "$IDRB" --timeout 1
assert_eq "$("$AM" status "$IDRB" | val state)" "claimed" "(invalid response must not finalize)"

t "claim: state=claimed with claim/ missing is an orphaned takeover crash; immediately re-claimable"
IDOC="$(new_in "$TMP/repoA" "hardening orphan claim")"; publish_prompt "$IDOC" "task"
"$AM" claim "$IDOC" --owner victim >/dev/null
rm -rf "$("$AM" path "$IDOC")/claim"
out="$("$AM" claim "$IDOC" --owner rescuer 2>&1)"; rc=$?
assert_eq "$rc" 0 "(re-claim rc on orphaned claim)"
TOKOC="$(echo "$out" | val claim_token)"
[ -n "$TOKOC" ] && ok || fail "no claim_token from orphan re-claim"
write_response "$IDOC" "$TMP/orphanclaim.md"
assert_rc 0 "$AM" respond "$IDOC" --token "$TOKOC" --file "$TMP/orphanclaim.md"

t "ask --timeout: the killed responder leaves a non-empty log and the hint names ask --attach"
out="$(cd "$TMP/repoA-wt" && STUB_MODE=slow SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "hardening timeout log" --file "$TMP/request.md" --timeout 2 2>&1)"; rc=$?
assert_eq "$rc" 124 "(ask rc on timeout)"
assert_grep "ask --attach" <(echo "$out")
IDTL="$(echo "$out" | sed -n 's/^exchange_id=//p' | head -1)"
LOGTL="$("$AM" status "$IDTL" | val responder_log)"
[ -s "$LOGTL" ] && ok || fail "responder log empty after timeout kill"
assert_grep "reached work deadline" "$LOGTL"
TLST="$("$AM" status "$IDTL")"
assert_eq "$(echo "$TLST" | val termination_grace_secs)" "10"
assert_eq "$(echo "$TLST" | val final_kill_epoch)" "$(( $(echo "$TLST" | val hard_deadline_epoch) + 10 ))"

t "ask --timeout: a TERM-resistant responder is visibly terminating, then SIGKILLed and recovered"
T0="$(date +%s)"
out="$(cd "$TMP/repoA-wt" && STUB_MODE=claimignoreterm SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "hardening term kill" --file "$TMP/request.md" --timeout 1 --grace 0 2>&1)"; rc=$?
T1="$(date +%s)"
assert_eq "$rc" 124 "(TERM-resistant timeout rc)"
[ $((T1 - T0)) -ge 11 ] && [ $((T1 - T0)) -le 16 ] && ok || fail "TERM-to-KILL interval was not bounded as declared (elapsed $((T1-T0))s)"
assert_grep "reached its work deadline — terminating" <(echo "$out")
assert_not_grep "Killed" <(echo "$out")
TERM_LINE="$(printf '%s\n' "$out" | grep -n -m1 'reached its work deadline' | cut -d: -f1)"
printf '%s\n' "$out" | tail -n "+$TERM_LINE" | grep -q 'Claude is still working' && fail "progress called Claude working after termination began" || ok
IDTK="$(echo "$out" | sed -n 's/^exchange_id=//p' | head -1)"
assert_eq "$("$AM" status "$IDTK" | val state)" "published" "(TERM-resistant exact claim recovered)"
assert_eq "$("$AM" status "$IDTK" | val responder_exit_code)" "137"

t "lazy reap: a correlated live responder keeps its claim throughout bounded termination"
IDLR="$(new_in "$TMP/repoA" "hardening live reap")"; publish_prompt "$IDLR" "task"
RUNLR="11112222333344445555666677778888"
SECONDOPINION_RUN_ID="$RUNLR" "$AM" claim "$IDLR" --owner live-reap >/dev/null
sleep 60 & LRPID=$!
LRSTAT="$(cat /proc/$LRPID/stat)"; LRSTAT="${LRSTAT##*) }"; set -- $LRSTAT; LRSTART="${20}"
LRNOW="$(date +%s)"; LRNS="$(readlink /proc/self/ns/pid)"
printf 'responder_pid=%s\nresponder_starttime=%s\nresponder_namespace=%s\nresponder_run_id=%s\nhard_deadline_epoch=%s\nfinal_kill_epoch=%s\nreap_after_epoch=%s\n' \
  "$LRPID" "$LRSTART" "$LRNS" "$RUNLR" "$((LRNOW - 1))" "$((LRNOW + 9))" "$((LRNOW + 11))" >> "$("$AM" path "$IDLR")/meta"
assert_eq "$("$AM" status "$IDLR" | val state)" "claimed" "(live claim must survive work-deadline TERM window)"
[ -d "$("$AM" path "$IDLR")/claim" ] && ok || fail "live claim was reaped before the final-kill bound"
sed -i "s/^reap_after_epoch=.*/reap_after_epoch=$((LRNOW - 1))/" "$("$AM" path "$IDLR")/meta"
LRST="$("$AM" status "$IDLR")"
assert_eq "$(echo "$LRST" | val state)" "published" "(claim released after final-kill/reap bound)"
assert_eq "$(echo "$LRST" | val claim_release_reason)" "final-kill-bound-expired"
kill "$LRPID" 2>/dev/null; wait "$LRPID" 2>/dev/null

t "ask --attach: refuses while the recorded responder is still running (no log truncation)"
IDAT="$(new_in "$TMP/repoA" "hardening attach running")"; publish_prompt "$IDAT" "task"
sleep 60 & RPID=$!
RSTAT="$(cat /proc/$RPID/stat)"; RSTAT="${RSTAT##*) }"; set -- $RSTAT; RSTART="${20}"
printf 'responder_pid=%s\nresponder_starttime=%s\nresponder_log=%s\n' "$RPID" "$RSTART" "$SECONDOPINION_DIR/responder-logs/$IDAT.log" >> "$("$AM" path "$IDAT")/meta"
mkdir -p "$SECONDOPINION_DIR/responder-logs"
printf 'SENTINEL-DO-NOT-TRUNCATE\n' > "$SECONDOPINION_DIR/responder-logs/$IDAT.log"
out="$(cd "$TMP/repoA" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --attach "$IDAT" 2>&1)"; rc=$?
assert_eq "$rc" 1 "(attach rc while responder running)"
assert_grep "still running" <(echo "$out")
assert_grep "cancel" <(echo "$out")
assert_grep "SENTINEL-DO-NOT-TRUNCATE" "$SECONDOPINION_DIR/responder-logs/$IDAT.log"
kill "$RPID" 2>/dev/null; wait "$RPID" 2>/dev/null

t "status/attach: a fresh supervisor heartbeat proves liveness across PID namespaces"
IDHB="$(new_in "$TMP/repoA" "hardening heartbeat liveness")"; publish_prompt "$IDHB" "task"
HBNOW="$(date +%s)"
printf 'responder_pid=2147483647\nresponder_starttime=not-visible\nresponder_namespace=pid:[foreign-heartbeat]\nresponder_heartbeat_epoch=%s\nresponder_activity_epoch=%s\nresponder_activity=tool Read: src/main.c\nresponder_event_count=7\n' "$HBNOW" "$HBNOW" >> "$("$AM" path "$IDHB")/meta"
assert_eq "$("$AM" status "$IDHB" | val responder_status)" "running-heartbeat"
HB_STATUS="$("$AM" status "$IDHB")"
assert_grep "activity_age_secs=" <(echo "$HB_STATUS")
out="$(cd "$TMP/repoA" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --attach "$IDHB" 2>&1)"; rc=$?
assert_eq "$rc" 1 "(attach rc with fresh cross-namespace heartbeat)"
assert_grep "still running" <(echo "$out")
sed -i "s/^responder_heartbeat_epoch=.*/responder_heartbeat_epoch=$((HBNOW - 1000))/" "$("$AM" path "$IDHB")/meta"
assert_eq "$("$AM" status "$IDHB" | val responder_status)" "unknown-foreign-namespace"

t "ask --attach: refuses a fresh launch reservation, then recovers it after the short launch bound"
IDLAUNCH="$(new_in "$TMP/repoA" "attach launch reservation")"; publish_prompt "$IDLAUNCH" "task"
OLDLAUNCHRUN="11111111111111111111111111111111"
printf 'responder_run_id=%s\nresponder_outcome=running\nresponder_pid=\nresponder_starttime=\nask_started_epoch=%s\n' "$OLDLAUNCHRUN" "$(date +%s)" >> "$("$AM" path "$IDLAUNCH")/meta"
out="$(cd "$TMP/repoA" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --attach "$IDLAUNCH" 2>&1)"; rc=$?
assert_eq "$rc" 1 "(attach during launch reservation)"
assert_grep "still launching" <(echo "$out")
sed -i "s/^ask_started_epoch=.*/ask_started_epoch=$(( $(date +%s) - 5 ))/" "$("$AM" path "$IDLAUNCH")/meta"
out="$(cd "$TMP/repoA" && STUB_MODE=fail SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --attach "$IDLAUNCH" --timeout 30 2>&1)"; rc=$?
assert_eq "$rc" 1 "(attach after abandoned launch bound reaches replacement responder)"
LAUNCHST="$("$AM" status "$IDLAUNCH")"
[ "$(echo "$LAUNCHST" | val responder_run_id)" != "$OLDLAUNCHRUN" ] && ok || fail "stale launch reservation was not replaced"
assert_eq "$(echo "$LAUNCHST" | val attach_arbitration)" "exited-responder-replacement"

t "PID namespace: a real isolated foreground responder is heartbeat-visible and cannot be signalled by an outer session"
if unshare -Ur -pf --mount-proc true 2>/dev/null; then
  SECONDOPINION_CLAUDE="$STUB_DIR/claude" STUB_MODE=slow SECONDOPINION_PROGRESS_SECS=1 \
    unshare --kill-child=KILL -Ur -pf --mount-proc bash -c 'cd "$1" && exec "$2" ask --topic "real namespace heartbeat" --file "$3" --timeout 60' \
      bash "$TMP/repoA" "$AM" "$TMP/request.md" >"$TMP/real-ns.out" 2>&1 &
  NSPID=$!
  IDNS="$(wait_exchange_slug real-namespace-heartbeat)" || fail "PID-namespace ask did not publish an exchange"
  for i in $(seq 1 40); do [ -n "$("$AM" status "$IDNS" | val responder_heartbeat_epoch)" ] && break; sleep 0.1; done
  NSSTATUS="$("$AM" status "$IDNS")"
  [ "$(echo "$NSSTATUS" | val responder_namespace)" != "$(readlink /proc/self/ns/pid)" ] && ok || fail "fixture did not enter a distinct PID namespace"
  assert_eq "$(echo "$NSSTATUS" | val responder_status)" "running-heartbeat"
  out="$("$AM" cancel "$IDNS" 2>&1)"; rc=$?
  assert_eq "$rc" 1 "(outer cancel of foreign PID namespace)"
  assert_grep "another PID namespace" <(echo "$out")
  kill -TERM "$NSPID" 2>/dev/null || true; wait "$NSPID" 2>/dev/null || true
  sed -i 's/^responder_heartbeat_epoch=.*/responder_heartbeat_epoch=1/' "$("$AM" path "$IDNS")/meta"
  NSAFTER="$("$AM" status "$IDNS" | val responder_status)"
  case "$NSAFTER" in
    exited|unknown-foreign-namespace) ok;;
    *) fail "post-teardown foreign responder state is '$NSAFTER'";;
  esac
else
  echo "note: unprivileged PID namespaces unavailable; real namespace case skipped"
fi

t "foreground supervisor heartbeat prevents a cross-namespace duplicate attach"
(cd "$TMP/repoA" && STUB_MODE=slow SECONDOPINION_PROGRESS_SECS=1 SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "hardening foreground heartbeat" --file "$TMP/request.md" --timeout 60 >"$TMP/foreground-heartbeat.out" 2>&1) &
FGASKPID=$!
IDBGHB="$(wait_exchange_slug hardening-foreground-heartbeat)" || fail "foreground ask did not publish an exchange"
DBGHB="$("$AM" path "$IDBGHB")"
for i in $(seq 1 30); do [ -n "$("$AM" status "$IDBGHB" | val responder_heartbeat_epoch)" ] && break; sleep 0.1; done
[ -n "$("$AM" status "$IDBGHB" | val responder_heartbeat_epoch)" ] && ok || fail "foreground supervisor did not publish a heartbeat"
out="$("$AM" claim "$IDBGHB" --owner manual-racer 2>&1)"; rc=$?
assert_eq "$rc" 1 "(manual claim must not steal a live foreground exchange)"
assert_grep "foreground responder" <(echo "$out")
assert_eq "$("$AM" status "$IDBGHB" | val state)" "published" "(refused manual claim leaves exchange published)"
STATUS_PIDS=()
for i in $(seq 1 12); do "$AM" status "$IDBGHB" > "$TMP/fg-heartbeat-status.$i" 2>&1 & STATUS_PIDS+=("$!"); done
for p in "${STATUS_PIDS[@]}"; do wait "$p"; done
for i in $(seq 1 12); do
  assert_eq "$(val state < "$TMP/fg-heartbeat-status.$i")" "published" "(concurrent status $i while heartbeat rewrites meta)"
  [ -n "$(val responder_run_id < "$TMP/fg-heartbeat-status.$i")" ] && ok || fail "concurrent status $i observed truncated meta"
done
BGNS="$("$AM" status "$IDBGHB" | val responder_namespace)"
sed -i 's|^responder_namespace=.*|responder_namespace=pid:[foreign-test]|' "$DBGHB/meta"
assert_eq "$("$AM" status "$IDBGHB" | val responder_status)" "running-heartbeat"
ATTACH_PIDS=()
for i in $(seq 1 4); do
  ( cd "$TMP/repoA" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --attach "$IDBGHB" > "$TMP/fg-heartbeat-attach.$i" 2>&1; printf '%s\n' "$?" > "$TMP/fg-heartbeat-attach.$i.rc" ) &
  ATTACH_PIDS+=("$!")
done
for p in "${ATTACH_PIDS[@]}"; do wait "$p"; done
for i in $(seq 1 4); do
  assert_eq "$(cat "$TMP/fg-heartbeat-attach.$i.rc")" 1 "(cross-namespace duplicate attach $i rc)"
  assert_grep "still running" "$TMP/fg-heartbeat-attach.$i"
done
sed -i "s|^responder_namespace=.*|responder_namespace=$BGNS|" "$DBGHB/meta"
"$AM" cancel "$IDBGHB" >/dev/null 2>&1
wait "$FGASKPID" 2>/dev/null || true

t "ask --attach: stale foreign recovery uses a unique log and never truncates incumbent diagnostics"
IDUFL="$(new_in "$TMP/repoA" "hardening foreign attach log")"; publish_prompt "$IDUFL" "task"
mkdir -p "$SECONDOPINION_DIR/responder-logs"
OLDLOG="$SECONDOPINION_DIR/responder-logs/$IDUFL.incumbent.log"
printf 'SENTINEL-FOREIGN-INCUMBENT\n' > "$OLDLOG"
printf 'responder_pid=2147483647\nresponder_starttime=not-visible\nresponder_namespace=pid:[foreign-stale]\nresponder_heartbeat_epoch=1\nresponder_log=%s\n' "$OLDLOG" >> "$("$AM" path "$IDUFL")/meta"
sed -i '/^responder_log=/i responder_run_id=incumbent-run-identity' "$("$AM" path "$IDUFL")/meta"
out="$(cd "$TMP/repoA" && STUB_MODE=fail SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --attach "$IDUFL" --timeout 30 2>&1)"; rc=$?
assert_eq "$rc" 1 "(stale foreign attach failure rc)"
assert_grep "SENTINEL-FOREIGN-INCUMBENT" "$OLDLOG"
NEWLOG="$("$AM" status "$IDUFL" | val responder_log)"
[ "$NEWLOG" != "$OLDLOG" ] && ok || fail "attach reused the incumbent responder log"
[ -s "$NEWLOG" ] && ok || fail "replacement responder did not receive a unique diagnostic log"
UFST="$("$AM" status "$IDUFL")"
assert_eq "$(echo "$UFST" | val attach_arbitration)" "stale-foreign-replacement"
assert_eq "$(echo "$UFST" | val previous_responder_run_id)" "incumbent-run-identity"
assert_eq "$(echo "$UFST" | val previous_responder_namespace)" "pid:[foreign-stale]"
assert_eq "$(echo "$UFST" | val previous_responder_log)" "$OLDLOG"
assert_rc 0 "$AM" archive "$IDUFL" --force
UFA="$SECONDOPINION_DIR/archive/$IDUFL/responder-logs"
assert_eq "$("$AM" status "$IDUFL" | val previous_responder_log)" "$UFA/${OLDLOG##*/}" "(archived previous log path updated)"
assert_eq "$("$AM" status "$IDUFL" | val responder_log)" "$UFA/${NEWLOG##*/}" "(archived current log path updated)"

t "ask --attach: a clean exchange clears stale arbitration metadata"
IDCLEAN="$(new_in "$TMP/repoA" "hardening clean attach")"; publish_prompt "$IDCLEAN" "task"
printf 'attach_arbitration=stale-value\nprevious_responder_run_id=stale-run\nprevious_responder_log=stale-log\n' >> "$("$AM" path "$IDCLEAN")/meta"
out="$(cd "$TMP/repoA" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --attach "$IDCLEAN" --timeout 30 2>&1)"; rc=$?
assert_eq "$rc" 0 "(clean attach rc)"
CLEANST="$("$AM" status "$IDCLEAN")"
assert_eq "$(echo "$CLEANST" | val attach_arbitration)" ""
assert_eq "$(echo "$CLEANST" | val previous_responder_run_id)" ""
assert_eq "$(echo "$CLEANST" | val previous_responder_log)" ""

t "ask: an authentication failure gives an actionable normal-terminal login and exact attach path"
out="$(cd "$TMP/repoA" && STUB_MODE=authfail SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "hardening auth hint" --file "$TMP/request.md" --timeout 30 2>&1)"; rc=$?
assert_eq "$rc" 1 "(auth failure rc)"
assert_grep "claude auth login" <(echo "$out")
assert_grep "normal terminal" <(echo "$out")
assert_grep "ask --attach" <(echo "$out")

t "prune --apply: sweeps leftover .prune-trash residue from an interrupted removal"
IDPT="$(new_in "$TMP/repoA" "hardening prune trash")"; publish_prompt "$IDPT" "task"
TOKPT="$("$AM" claim "$IDPT" --owner p | val claim_token)"
write_response "$IDPT" "$TMP/prunetrash.md"
"$AM" respond "$IDPT" --token "$TOKPT" --file "$TMP/prunetrash.md" >/dev/null
"$AM" archive "$IDPT" >/dev/null
mkdir -p "$SECONDOPINION_DIR/archive/.prune-trash.999.2020-01-01T000000Z-stale"
echo x > "$SECONDOPINION_DIR/archive/.prune-trash.999.2020-01-01T000000Z-stale/leftover"
assert_rc 0 "$AM" prune --apply
[ ! -e "$SECONDOPINION_DIR/archive/.prune-trash.999.2020-01-01T000000Z-stale" ] && ok || fail "stale .prune-trash residue not swept"

t "jobs: an exchange-less repository explains itself on stderr and hints --all"
mkrepo "$TMP/repoC"
out="$(cd "$TMP/repoC" && "$AM" jobs 2>"$TMP/jobs-empty.err")"; rc=$?
assert_eq "$rc" 0 "(jobs rc in exchange-less repo)"
assert_eq "$out" "" "(jobs stdout stays empty)"
assert_grep "jobs --all" "$TMP/jobs-empty.err"
out="$(cd "$TMP/repoA" && "$AM" jobs 2>"$TMP/jobs-nonempty.err")"
assert_not_grep "no exchanges" "$TMP/jobs-nonempty.err"

t "jobs --all: an empty store says so instead of printing nothing"
out="$(cd "$TMP/repoC" && SECONDOPINION_DIR="$TMP/store-empty-jobs" "$AM" jobs --all 2>"$TMP/jobs-all.err")"; rc=$?
assert_eq "$rc" 0 "(jobs --all rc on empty store)"
assert_grep "no exchanges" "$TMP/jobs-all.err"

t "archive: refuses a cross-filesystem archive/ before mutating anything"
IDXF="$(new_in "$TMP/repoA" "hardening crossfs")"; publish_prompt "$IDXF" "task"
TOKXF="$("$AM" claim "$IDXF" --owner x | val claim_token)"
write_response "$IDXF" "$TMP/xfs.md"
"$AM" respond "$IDXF" --token "$TOKXF" --file "$TMP/xfs.md" >/dev/null
XDEV="/dev/shm/so-crossfs-test.$$"; mkdir -p "$XDEV"
mv "$SECONDOPINION_DIR/archive" "$SECONDOPINION_DIR/archive.real"
ln -s "$XDEV" "$SECONDOPINION_DIR/archive"
out="$("$AM" archive "$IDXF" 2>&1)"; rc=$?
rm "$SECONDOPINION_DIR/archive"; mv "$SECONDOPINION_DIR/archive.real" "$SECONDOPINION_DIR/archive"; rm -rf "$XDEV"
assert_eq "$rc" 1 "(archive rc onto cross-fs archive/)"
assert_grep "filesystem" <(echo "$out")
assert_eq "$("$AM" status "$IDXF" | val state)" "answered" "(refusal must not mutate state)"
assert_rc 0 "$AM" archive "$IDXF"
assert_eq "$("$AM" status "$IDXF" | val state)" "archived" "(same-fs archive still works)"

t "ask: a FOREGROUND responder's identity is recorded so jobs/status show liveness from any session"
(cd "$TMP/repoA-wt" && STUB_MODE=slow SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "fg identity" --file "$TMP/request.md" --timeout 3 >/dev/null 2>&1) &
ASKBG=$!
IDFG=""
for i in $(seq 1 20); do
  IDFG="$(ls "$SECONDOPINION_DIR/exchanges" 2>/dev/null | grep 'fg-identity' | head -1)"
  [ -n "$IDFG" ] && [ -n "$("$AM" status "$IDFG" 2>/dev/null | val responder_pid)" ] && break
  sleep 0.1
done
[ -n "$IDFG" ] && ok || fail "fg-identity exchange not created"
assert_eq "$("$AM" status "$IDFG" | val responder_status)" "running" "(foreground responder liveness while in flight)"
wait "$ASKBG" 2>/dev/null
assert_eq "$("$AM" status "$IDFG" | val responder_status)" "exited" "(liveness after the timeout kill)"

t "prune: GCs day-old crash litter (meta-less orphans, .new staging, stale tmp files); fresh litter survives"
mkdir -p "$SECONDOPINION_DIR/exchanges/2020-01-01T000000Z-old-orphan"
touch -d '2 days ago' "$SECONDOPINION_DIR/exchanges/2020-01-01T000000Z-old-orphan"
mkdir -p "$SECONDOPINION_DIR/exchanges/.new.99999"; echo x > "$SECONDOPINION_DIR/exchanges/.new.99999/prompt.md"
touch -d '2 days ago' "$SECONDOPINION_DIR/exchanges/.new.99999"
mkdir -p "$SECONDOPINION_DIR/exchanges/2020-01-02T000000Z-fresh-orphan"
IDGC="$(new_in "$TMP/repoA" "hardening gc host")"; publish_prompt "$IDGC" "task"
GCD="$("$AM" path "$IDGC")"
echo t > "$GCD/.meta.tmp.123"; touch -d '2 days ago' "$GCD/.meta.tmp.123"
echo t > "$GCD/.response.tmp.fresh"
"$AM" prune >/dev/null 2>&1
[ -d "$SECONDOPINION_DIR/exchanges/2020-01-01T000000Z-old-orphan" ] && ok || fail "dry-run removed an orphan"
assert_rc 0 "$AM" prune --apply
[ ! -e "$SECONDOPINION_DIR/exchanges/2020-01-01T000000Z-old-orphan" ] && ok || fail "old meta-less orphan not GCed"
[ ! -e "$SECONDOPINION_DIR/exchanges/.new.99999" ] && ok || fail "old .new staging not GCed"
[ -d "$SECONDOPINION_DIR/exchanges/2020-01-02T000000Z-fresh-orphan" ] && ok || fail "fresh orphan must survive (may be mid-creation)"
[ ! -e "$GCD/.meta.tmp.123" ] && ok || fail "stale tmp file not GCed"
[ -e "$GCD/.response.tmp.fresh" ] && ok || fail "fresh tmp file must survive"
assert_eq "$("$AM" status "$IDGC" | val state)" "published" "(real exchange untouched by GC)"
rm -rf "$SECONDOPINION_DIR/exchanges/2020-01-02T000000Z-fresh-orphan"

t "ask --attach: re-checks state under the lock; a claim racing the attach wins and no responder launches"
IDRA="$(new_in "$TMP/repoA-wt" "hardening attach race")"; publish_prompt "$IDRA" "task"
printf 'UNTOUCHED\n' > "$STUB_ARGV_FILE"
(cd "$TMP/repoA-wt" && SECONDOPINION_TEST_ATTACH_PAUSE=1 SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --attach "$IDRA" --timeout 30 >"$TMP/attach-race.out" 2>&1) &
ATTBG=$!
sleep 0.3
"$AM" claim "$IDRA" --owner racer >/dev/null 2>&1
wait "$ATTBG"; rc=$?
assert_eq "$rc" 1 "(attach rc when a claim won the race)"
assert_grep "no longer published" "$TMP/attach-race.out"
assert_grep "UNTOUCHED" "$STUB_ARGV_FILE"

t "ask --attach: a heartbeat racing the attach is rechecked under lock and prevents a duplicate"
IDRAH="$(new_in "$TMP/repoA-wt" "hardening attach heartbeat race")"; publish_prompt "$IDRAH" "task"
printf 'responder_pid=2147483647\nresponder_starttime=not-visible\nresponder_namespace=pid:[foreign-race]\nresponder_heartbeat_epoch=1\n' >> "$("$AM" path "$IDRAH")/meta"
printf 'UNTOUCHED-HEARTBEAT\n' > "$STUB_ARGV_FILE"
(cd "$TMP/repoA-wt" && SECONDOPINION_TEST_ATTACH_PAUSE=1 SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --attach "$IDRAH" --timeout 30 >"$TMP/attach-heartbeat-race.out" 2>&1) &
ATTHB=$!
sleep 0.3
sed -i "s/^responder_heartbeat_epoch=.*/responder_heartbeat_epoch=$(date +%s)/" "$("$AM" path "$IDRAH")/meta"
wait "$ATTHB"; rc=$?
assert_eq "$rc" 1 "(attach rc when a heartbeat revived during startup)"
assert_grep "became live" "$TMP/attach-heartbeat-race.out"
assert_grep "UNTOUCHED-HEARTBEAT" "$STUB_ARGV_FILE"

t "respond: an ln failure with no existing response is not misreported as write-once"
mkdir -p "$TMP/failbin"; printf '#!/bin/bash\nexit 1\n' > "$TMP/failbin/ln"; chmod +x "$TMP/failbin/ln"
IDLN="$(new_in "$TMP/repoA" "hardening ln fail")"; publish_prompt "$IDLN" "task"
TOKLN="$("$AM" claim "$IDLN" --owner l | val claim_token)"
write_response "$IDLN" "$TMP/lnfail.md"
out="$(PATH="$TMP/failbin:$PATH" "$AM" respond "$IDLN" --token "$TOKLN" --file "$TMP/lnfail.md" 2>&1)"; rc=$?
assert_eq "$rc" 1 "(respond rc on ln failure)"
assert_grep "hardlink" <(echo "$out")
assert_not_grep "write-once" <(echo "$out")

t "ask: SECONDOPINION_CLAUDE_ARGS is word-split but never glob-expanded"
touch "$TMP/repoA-wt/globfile"
out="$(cd "$TMP/repoA-wt" && SECONDOPINION_CLAUDE_ARGS='--extra-flag *' SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "glob args" --file "$TMP/request.md" --timeout 60 2>/dev/null)"
grep -Fxq -- '*' "$STUB_ARGV_FILE" && ok || fail "literal * not passed through"
assert_not_grep "^globfile$" "$STUB_ARGV_FILE"

t "ask --attach --write: refused on a review exchange (reviews are read-only)"
out="$(cd "$TMP/repoA-wt" && STUB_MODE=fail SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" review --scope working-tree --topic "hardening review write" --task focus --timeout 60 2>&1)"
IDRW="$(echo "$out" | sed -n 's/^exchange_id=//p' | head -1)"
[ -n "$IDRW" ] && ok || fail "review exchange not created: $out"
out="$(cd "$TMP/repoA-wt" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --attach "$IDRW" --write 2>&1)"; rc=$?
assert_eq "$rc" 1 "(attach --write rc on review exchange)"
assert_grep "read-only" <(echo "$out")

t "preflight: a PATH without flock fails with one clear error naming flock"
out="$(PATH="" "$AM" version 2>&1)"; rc=$?
assert_eq "$rc" 1 "(rc with empty PATH)"
assert_grep "flock" <(echo "$out")

# --- auto-prune: opt-in, bucket-only, fail-open --------------------------------------------
SAP="$TMP/store-auto"
ap_ex() { # ap_ex <repo> <topic> [archive-args...] -> archives one answered exchange; prints archive stdout
  local repo="$1" topic="$2"; shift 2
  local id tok
  id="$(SECONDOPINION_DIR="$SAP" new_in "$repo" "$topic")"
  SECONDOPINION_DIR="$SAP" publish_prompt "$id" "task"
  tok="$(SECONDOPINION_DIR="$SAP" "$AM" claim "$id" --owner a | val claim_token)"
  write_response "$id" "$TMP/ap.md"
  SECONDOPINION_DIR="$SAP" "$AM" respond "$id" --token "$tok" --file "$TMP/ap.md" >/dev/null
  SECONDOPINION_DIR="$SAP" "$AM" archive "$id" "$@" 2>"$TMP/ap.err"
}
ap_count() { ls -1 "$SAP/archive" 2>/dev/null | grep -c '^2'; }

t "auto-prune: SECONDOPINION_AUTO_PRUNE keeps the bucket at the retention bound after archive"
for i in 1 2 3; do SECONDOPINION_RETAIN=3 SECONDOPINION_AUTO_PRUNE=1 ap_ex "$TMP/repoA" "ap-fill-$i" >/dev/null; done
assert_eq "$(ap_count)" "3" "(bucket at bound before overflow)"
out="$(SECONDOPINION_RETAIN=3 SECONDOPINION_AUTO_PRUNE=1 ap_ex "$TMP/repoA" "ap-overflow")"; rc=$?
assert_eq "$rc" 0 "(archive rc with auto-prune)"
assert_eq "$(ap_count)" "3" "(bucket pruned back to bound)"
assert_grep "^auto_prune=ok removed=1" <(echo "$out")

t "auto-prune: archive --prune works without the env var"
out="$(SECONDOPINION_RETAIN=3 ap_ex "$TMP/repoA" "ap-flag" --prune)"; rc=$?
assert_eq "$rc" 0 "(archive --prune rc)"
assert_eq "$(ap_count)" "3" "(bucket pruned by the flag)"
assert_grep "^auto_prune=ok removed=1" <(echo "$out")

t "auto-prune: OFF by default — plain archive lets the bucket grow and only prints the retention note"
out="$(SECONDOPINION_RETAIN=3 ap_ex "$TMP/repoA" "ap-default-off")"; rc=$?
assert_eq "$rc" 0 "(plain archive rc)"
assert_eq "$(ap_count)" "4" "(bucket grew without opt-in)"
assert_not_grep "auto_prune" <(echo "$out")
assert_grep "prune" "$TMP/ap.err"

t "auto-prune: fail-open — a failing prune never fails the archive"
mv "$SAP/tombstones" "$SAP/tombstones.real" 2>/dev/null; ln -s /nonexistent "$SAP/tombstones"
out="$(SECONDOPINION_RETAIN=3 SECONDOPINION_AUTO_PRUNE=1 ap_ex "$TMP/repoA" "ap-failopen")"; rc=$?
rm -f "$SAP/tombstones"; mv "$SAP/tombstones.real" "$SAP/tombstones" 2>/dev/null
assert_eq "$rc" 0 "(archive rc while prune fails)"
assert_grep "^auto_prune=failed" <(echo "$out")
SECONDOPINION_DIR="$SAP" "$AM" status "$(echo "$out" | val exchange_id)" >/dev/null 2>&1 && ok || fail "archived exchange unreadable after fail-open"

t "auto-prune: bucket-only — other repositories' archives are never touched, and no GC runs"
SAP="$TMP/store-auto2"
for i in 1 2; do SECONDOPINION_RETAIN=9 ap_ex "$TMP/repoA" "apb-a$i" >/dev/null; done
for i in 1 2; do SECONDOPINION_RETAIN=9 ap_ex "$TMP/repoB" "apb-b$i" >/dev/null; done
mkdir -p "$SAP/exchanges/2020-01-01T000000Z-apb-orphan"; touch -d '2 days ago' "$SAP/exchanges/2020-01-01T000000Z-apb-orphan"
out="$(SECONDOPINION_RETAIN=1 SECONDOPINION_AUTO_PRUNE=1 ap_ex "$TMP/repoA" "apb-a3")"; rc=$?
assert_eq "$rc" 0 "(bucket-only archive rc)"
assert_grep "^auto_prune=ok removed=2" <(echo "$out")
assert_eq "$(ls -1 "$SAP/archive" | grep -c 'apb-b')" "2" "(repoB bucket untouched despite being over-retain)"
[ -d "$SAP/exchanges/2020-01-01T000000Z-apb-orphan" ] && ok || fail "auto-prune ran the store-wide GC (orphan removed)"

# ===========================================================================
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
