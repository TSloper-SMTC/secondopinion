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
publish_prompt() { # publish_prompt <id> <body>
  local p; p="$("$AM" path "$1")/prompt.md"
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

t "help: usage lists every command"
for c in new publish list status show path claim respond read-response wait archive; do
  assert_grep "\b$c\b" <("$AM" --help 2>&1)
done

# ===========================================================================
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
