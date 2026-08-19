#!/bin/bash
# Parity-pass tests: retention/prune, background job control, follow-up/resume,
# model/effort, review modes. Isolated store + throwaway HOME; fake `claude`.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AM="$HERE/../plugins/secondopinion/bin/secondopinion"
PASS=0; FAIL=0; CURRENT=""
t()      { CURRENT="$1"; }
ok()     { PASS=$((PASS+1)); }
fail()   { FAIL=$((FAIL+1)); echo "FAIL [$CURRENT] $*" >&2; }
assert_eq() { [ "$1" = "$2" ] && ok || fail "expected '$2' got '$1' ${3:-}"; }
assert_rc() { local want="$1"; shift; "$@" >/dev/null 2>&1; local rc=$?; [ "$rc" = "$want" ] && ok || fail "rc=$rc want=$want: $*"; }
assert_grep() { grep -q -- "$1" "$2" 2>/dev/null && ok || fail "'$1' not found in $2"; }
val() { awk -v k="$1" -F= '$1==k{sub(/^[^=]*=/,""); print; exit}' ; }

TMP="$(mktemp -d)"; [ -n "${KEEP_TMP:-}" ] && trap "echo TMP=$TMP" EXIT || trap "rm -rf \"$TMP\"" EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
export SECONDOPINION_DIR="$TMP/store"
unset SECONDOPINION_RETAIN CODEX_THREAD_ID

mkrepo() { git init -q -b main "$1" && git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init; }
mkrepo "$TMP/repoA"; mkrepo "$TMP/repoB"; mkdir -p "$TMP/nogit"

arch_in() { # arch_in <dir> <topic> -> archived exchange id (fast path: draft -> archive --force)
  local id; id="$( (cd "$1" && "$AM" new --topic "$2") | val exchange_id )"
  "$AM" archive "$id" --force >/dev/null 2>&1 || { echo "ARCH-FAIL"; return 1; }
  printf '%s\n' "$id"
}

# ===========================================================================
# Phase 3: bounded retention + prune + tombstones

t "prune: below and at the retention bound there are no candidates (49/50), one above (51)"
for i in $(seq 1 49); do arch_in "$TMP/repoA" "keep $i" >/dev/null; done
out="$("$AM" prune 2>&1)"; assert_eq "$(echo "$out" | val candidates)" "0" "(49 archived)"
arch_in "$TMP/repoA" "keep 50" >/dev/null
out="$("$AM" prune 2>&1)"; assert_eq "$(echo "$out" | val candidates)" "0" "(50 archived)"
ID51="$(arch_in "$TMP/repoA" "keep 51")"
out="$("$AM" prune 2>&1)"
assert_eq "$(echo "$out" | val candidates)" "1" "(51 archived)"
assert_eq "$(echo "$out" | val mode)" "dry-run"
assert_eq "$(echo "$out" | val pruned)" "0" "(dry-run prunes nothing)"
echo "$out" | grep -q "^prune=" && ok || fail "no prune= target line: $out"
echo "$out" | grep -q "bytes=" && ok || fail "no bytes in target line: $out"
assert_eq "$(ls "$SECONDOPINION_DIR/archive" | wc -l)" "51" "(dry run removed nothing)"

t "prune: buckets are per git-common-dir plus a non-git bucket; a busy repo cannot evict others"
IDB="$(arch_in "$TMP/repoB" "b one")"; IDN="$(cd "$TMP/nogit" && "$AM" new --topic "n one" | val exchange_id)"
"$AM" archive "$IDN" --force >/dev/null
out="$("$AM" prune 2>&1)"
assert_eq "$(echo "$out" | val candidates)" "1" "(only repoA is over its bound)"
echo "$out" | grep "^prune=" | grep -q "$IDB\|$IDN" && fail "repoB/non-git exchange listed although their buckets are small" || ok

t "prune --retain overrides the bound; SECONDOPINION_RETAIN is honoured; invalid values refused"
out="$("$AM" prune --retain 2 2>&1)"
a_candidates="$(echo "$out" | val candidates)"
assert_eq "$a_candidates" "49" "(repoA 51-2, repoB and non-git at 1 each)"
out="$(SECONDOPINION_RETAIN=2 "$AM" prune 2>&1)"; assert_eq "$(echo "$out" | val candidates)" "49" "(env override)"
assert_rc 1 "$AM" prune --retain 0
assert_rc 1 "$AM" prune --retain -3
assert_rc 1 "$AM" prune --retain abc

t "prune --apply removes only over-bound archived exchanges, appends tombstones, never touches exchanges/"
LIVEID="$( (cd "$TMP/repoA" && "$AM" new --topic "live draft") | val exchange_id )"
before_active="$(ls "$SECONDOPINION_DIR/exchanges" | wc -l)"
out="$("$AM" prune --apply 2>&1)"
assert_eq "$(echo "$out" | val mode)" "apply"
assert_eq "$(echo "$out" | val pruned)" "1"
assert_eq "$(ls "$SECONDOPINION_DIR/archive" | wc -l)" "52" "(53 archived minus 1 pruned)"
assert_eq "$(ls "$SECONDOPINION_DIR/exchanges" | wc -l)" "$before_active" "(active exchanges untouched)"
PRUNED_ID="$(echo "$out" | sed -n 's/^prune=\([^ \t]*\).*/\1/p' | head -1)"
grep -Fxq "$PRUNED_ID" "$SECONDOPINION_DIR/tombstones" && ok || fail "pruned id not tombstoned"
[ "$(stat -c %a "$SECONDOPINION_DIR/tombstones")" = "600" ] && ok || fail "tombstones not 0600"

t "tombstones: a pruned ID is never reused, even for the same topic in the same second"
mkrepo "$TMP/repoD"
DSTUB="$TMP/datestub"; mkdir -p "$DSTUB"
cat > "$DSTUB/date" <<'DS'
#!/bin/bash
case "$*" in
  *"+%Y-%m-%dT%H%M%SZ"*) echo 2020-01-01T000000Z;;
  *"+%Y-%m-%dT%H:%M:%SZ"*) echo 2020-01-01T00:00:00Z;;
  *) exec /bin/date "$@";;
esac
DS
chmod +x "$DSTUB/date"
TID="$( (cd "$TMP/repoD" && PATH="$DSTUB:$PATH" "$AM" new --topic "tomb") | val exchange_id )"
assert_eq "$TID" "2020-01-01T000000Z-tomb" "(deterministic id)"
PATH="$DSTUB:$PATH" "$AM" archive "$TID" --force >/dev/null          # archived_utc = 2020 too
NEWER="$(arch_in "$TMP/repoD" "newer")"
"$AM" prune --retain 1 --apply >/dev/null 2>&1                        # repoD keeps only NEWER
grep -Fxq "$TID" "$SECONDOPINION_DIR/tombstones" && ok || fail "old exchange not pruned/tombstoned in repoD"
TID2="$( (cd "$TMP/repoD" && PATH="$DSTUB:$PATH" "$AM" new --topic "tomb") | val exchange_id )"
[ "$TID2" = "2020-01-01T000000Z-tomb-2" ] && ok || fail "tombstoned id was reused or wrong suffix: '$TID2'"
"$AM" archive "$TID2" --force >/dev/null 2>&1

t "prune: an exchange whose .lock is held is skipped, not removed"
mkrepo "$TMP/repoC"
OLDL="$( (cd "$TMP/repoC" && PATH="$DSTUB:$PATH" "$AM" new --topic "held old") | val exchange_id )"
PATH="$DSTUB:$PATH" "$AM" archive "$OLDL" --force >/dev/null
NEWL="$(arch_in "$TMP/repoC" "held new")"
( exec 9>>"$SECONDOPINION_DIR/archive/$OLDL/.lock"; flock 9; sleep 4 ) &
HOLDER=$!; sleep 0.5
out="$("$AM" prune --retain 1 --apply 2>&1)"
echo "$out" | grep -q "skipped=$OLDL" && ok || fail "held exchange not reported skipped: $out"
[ -d "$SECONDOPINION_DIR/archive/$OLDL" ] && ok || fail "held exchange was removed while locked"
[ -d "$SECONDOPINION_DIR/archive/$NEWL" ] && ok || fail "retained exchange was removed"
wait "$HOLDER" 2>/dev/null

t "prune --apply: a candidate locked AFTER selection is never removed while locked (lock is held through removal)"
RSTORE="$TMP/store-race"; mkrepo "$TMP/repoE"
OLDR="$( (cd "$TMP/repoE" && PATH="$DSTUB:$PATH" SECONDOPINION_DIR="$RSTORE" "$AM" new --topic "race old") | val exchange_id )"
PATH="$DSTUB:$PATH" SECONDOPINION_DIR="$RSTORE" "$AM" archive "$OLDR" --force >/dev/null
NEWR="$( (cd "$TMP/repoE" && SECONDOPINION_DIR="$RSTORE" "$AM" new --topic "race new") | val exchange_id )"
SECONDOPINION_DIR="$RSTORE" "$AM" archive "$NEWR" --force >/dev/null
SECONDOPINION_DIR="$RSTORE" SECONDOPINION_TEST_PRUNE_PAUSE=2 "$AM" prune --retain 1 --apply >/dev/null 2>&1 &
PRUNER=$!
sleep 0.7                                  # inside the pause window, after target selection
GRABBED=0
exec 6>>"$RSTORE/archive/$OLDR/.lock" 2>/dev/null && flock -n 6 && GRABBED=1
wait "$PRUNER"
if [ "$GRABBED" = 1 ]; then
  [ -d "$RSTORE/archive/$OLDR" ] && ok || fail "exchange was removed WHILE another process held its lock (probe/removal race)"
  exec 6>&-
else
  # the fixed implementation holds the lock through removal, so the grab must fail and the target goes
  [ ! -d "$RSTORE/archive/$OLDR" ] && ok || fail "lock grab failed but the candidate also survived"
  exec 6>&- 2>/dev/null || true
fi

t "prune: an interrupted apply (tombstone written, directory left) completes on re-run"
VICT="$(arch_in "$TMP/repoB" "victim zz")"; sleep 1.1; KEEP="$(arch_in "$TMP/repoB" "keeper zz")"
printf '%s\n' "$VICT" >> "$SECONDOPINION_DIR/tombstones"     # simulate the crash window
out="$("$AM" prune --retain 1 --apply 2>&1)"
[ ! -d "$SECONDOPINION_DIR/archive/$VICT" ] && ok || fail "interrupted prune target not completed"
assert_eq "$(grep -Fxc "$VICT" "$SECONDOPINION_DIR/tombstones")" "1" "(no duplicate tombstone line)"

t "prune: a symlinked tombstones file fails closed"
SYM="$TMP/store-symtomb"; mkdir -p "$SYM"
env SECONDOPINION_DIR="$SYM" "$AM" new --topic seed >/dev/null 2>&1 || true
ln -sfn /dev/null "$SYM/tombstones"
out="$(env SECONDOPINION_DIR="$SYM" "$AM" prune --apply 2>&1)"; rc=$?
assert_eq "$rc" 1 "(prune with symlinked tombstones)"
echo "$out" | grep -qi "symlink" && ok || fail "error does not name the symlink: $out"

# ===========================================================================
# Phase 4: background job identity, status, jobs, result, cancel

STUB_DIR="$TMP/claude-stub"; mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/claude" <<'STUB'
#!/bin/bash
if [ "${1:-}" = "--help" ]; then
  echo "  --effort <level>                      Effort level for the current session"
  echo "                                        (low, medium, high, xhigh, max)"
  exit 0
fi
printf '%s
' "$@" > "${STUB_ARGV_FILE:?}"
id=""; prev=""; for a in "$@"; do if [ "$prev" = "-p" ]; then id="$(printf '%s
' "$a" | sed -n 's/^Exchange-ID: //p' | head -1)"; fi; prev="$a"; done
case "${STUB_MODE:-answer}" in
  answer)
    tok="$("$STUB_AM" claim "$id" --owner stub 2>/dev/null | awk -F= '/^claim_token=/{print $2}')"
    printf 'Exchange-ID: %s
Responder: Stub Claude

%s
' "$id" "${STUB_BODY:-verdict: PROVEN stub-answer}" > "$STUB_DIR/resp.md"
    "$STUB_AM" respond "$id" --token "$tok" --file "$STUB_DIR/resp.md" >/dev/null 2>&1
    if [ -n "${STUB_PLAIN_OUTPUT:-}" ]; then echo '{"is_error":false}'; else echo '{"is_error":false,"modelUsage":{"claude-stub-model-1":{"in":1}}}'; fi;;
  slow) sleep 60;;
  fail) echo boom >&2; exit 1;;
esac
STUB
chmod +x "$STUB_DIR/claude"
export STUB_DIR STUB_AM="$AM" STUB_ARGV_FILE="$TMP/stub-argv"
printf 'Check the thing.
' > "$TMP/request.md"

t "background job identity: pid + start time recorded; status shows a running responder and elapsed time"
out="$(cd "$TMP/repoA" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" STUB_MODE=slow "$AM" ask --topic "bg job" --file "$TMP/request.md" --background 2>/dev/null)"
IDBG="$(echo "$out" | val exchange_id)"
[ -n "$IDBG" ] && ok || fail "no exchange id from ask --background"
sleep 1
st="$("$AM" status "$IDBG")"
PIDBG="$(echo "$st" | val responder_pid)"
[ -n "$PIDBG" ] && kill -0 "$PIDBG" 2>/dev/null && ok || fail "responder_pid missing or dead: '$PIDBG'"
[ -n "$(echo "$st" | val responder_starttime)" ] && ok || fail "responder_starttime not recorded"
assert_eq "$(echo "$st" | val responder_status)" "running"
el="$(echo "$st" | val elapsed_secs)"; [ -n "$el" ] && [ "$el" -ge 0 ] && ok || fail "elapsed_secs missing: '$el'"
echo "$st" | grep -q "^next=" && ok || fail "status lacks a next= recovery hint"

t "cancel: kills only the verified process group; exchange stays recoverable; responder marked cancelled"
out="$("$AM" cancel "$IDBG" 2>&1)"; rc=$?
assert_eq "$rc" 0 "(cancel rc)"
assert_eq "$(echo "$out" | val cancelled)" "yes"
sleep 0.5
kill -0 "$PIDBG" 2>/dev/null && fail "responder still alive after cancel" || ok
st="$("$AM" status "$IDBG")"
assert_eq "$(echo "$st" | val state)" "published" "(exchange stays recoverable)"
assert_eq "$(echo "$st" | val responder_status)" "cancelled"

t "cancel: refuses a PID-reuse candidate (start-time mismatch) and a second cancel reports not-running"
d="$("$AM" path "$IDBG")"
( exec 9>>"$d/.lock"; flock 9; sed -i "s/^responder_pid=.*/responder_pid=1/; s/^responder_starttime=.*/responder_starttime=999999/" "$d/meta" )
out="$("$AM" cancel "$IDBG" 2>&1)"; rc=$?
[ "$rc" != 0 ] && ok || fail "cancel accepted a mismatched start time (PID reuse)"
echo "$out" | grep -qi "start.time\|reuse\|mismatch" && ok || fail "no PID-reuse explanation: $out"
( exec 9>>"$d/.lock"; flock 9; sed -i "s/^responder_pid=.*/responder_pid=$PIDBG/" "$d/meta" )
out="$("$AM" cancel "$IDBG" 2>&1)"; rc=$?
assert_eq "$(echo "$out" | val cancelled)" "no"
echo "$out" | grep -q "not-running\|already" && ok || fail "second cancel not reported honestly: $out"

t "cancel: never demotes an answered exchange"
out="$(cd "$TMP/repoA" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "bg ans" --file "$TMP/request.md" --background 2>/dev/null)"
IDANS="$(echo "$out" | val exchange_id)"
assert_rc 0 "$AM" wait "$IDANS" --timeout 30
out="$("$AM" cancel "$IDANS" 2>&1)"; rc=$?
assert_eq "$(echo "$out" | val cancelled)" "no"
assert_eq "$("$AM" status "$IDANS" | val state)" "answered" "(state untouched)"

t "status: an exited (not cancelled) responder on an unanswered exchange is reported stale, not guessed running"
out="$(cd "$TMP/repoA" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" STUB_MODE=fail "$AM" ask --topic "bg dead" --file "$TMP/request.md" --background 2>/dev/null)"
IDDEAD="$(echo "$out" | val exchange_id)"
sleep 1
st="$("$AM" status "$IDDEAD")"
assert_eq "$(echo "$st" | val responder_status)" "exited"
assert_eq "$(echo "$st" | val state)" "published"

t "jobs: repository-scoped table with state, age, responder"
out="$(cd "$TMP/repoA" && "$AM" jobs 2>/dev/null)"
echo "$out" | grep -q "$IDANS" && ok || fail "answered exchange missing from jobs: $out"
echo "$out" | grep "$IDDEAD" | grep -q "exited" && ok || fail "dead responder not shown in jobs: $out"
out2="$(cd "$TMP/repoB" && "$AM" jobs 2>/dev/null)"
echo "$out2" | grep -q "$IDANS" && fail "jobs leaked exchanges of another repository" || ok

t "result: prints the validated answer for an answered exchange, and an honest status + log for a failed one"
r1="$("$AM" result "$IDANS" 2>/dev/null)"
r2="$("$AM" read-response "$IDANS" 2>/dev/null)"
assert_eq "$r1" "$r2" "(result == read-response for answered)"
out="$("$AM" result "$IDDEAD" 2>&1)"; rc=$?
[ "$rc" != 0 ] && ok || fail "result on unanswered exchange must fail"
echo "$out" | grep -q "responder_log=" && ok || fail "failed result does not point at the log: $out"
"$AM" archive "$IDANS" >/dev/null 2>&1; "$AM" archive "$IDDEAD" --force >/dev/null 2>&1; "$AM" archive "$IDBG" --force >/dev/null 2>&1

t "responder.pid containment: a symlinked pid record is refused, not followed"
out="$(cd "$TMP/repoA" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" STUB_MODE=slow "$AM" ask --topic "bg sym" --file "$TMP/request.md" --background 2>/dev/null)"
IDSYM="$(echo "$out" | val exchange_id)"; sleep 0.5
d="$("$AM" path "$IDSYM")"; PIDS="$("$AM" status "$IDSYM" | val responder_pid)"
"$AM" cancel "$IDSYM" >/dev/null 2>&1   # tidy the running stub first
[ -f "$d/responder.pid" ] && { rm -f "$d/responder.pid"; ln -s /etc/passwd "$d/responder.pid"; st="$("$AM" status "$IDSYM" 2>&1)"; echo "$st" | grep -qi "symlink" && ok || fail "symlinked responder.pid not refused: $st"; } || ok
"$AM" archive "$IDSYM" --force >/dev/null 2>&1

# ===========================================================================
# Phase 5+6: model/effort controls, follow-up, opt-in native resume

t "ask --effort: validated against the live CLI's advertised levels; unsupported CLIs and bad values refused before any exchange"
before_count="$(ls "$SECONDOPINION_DIR/exchanges" | wc -l)"
out="$(cd "$TMP/repoA" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "eff" --file "$TMP/request.md" --effort xhigh --timeout 60 2>/dev/null)"; rc=$?
assert_eq "$rc" 0 "(ask --effort xhigh)"
grep -qx -- "--effort" "$STUB_ARGV_FILE" && grep -qx -- "xhigh" "$STUB_ARGV_FILE" && ok || fail "--effort not passed through"
IDEFF="$(echo "$out" | sed -n 's/^Exchange-ID: //p' | head -1)"
assert_eq "$("$AM" status "$IDEFF" | val requested_effort)" "xhigh"
out="$(cd "$TMP/repoA" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "eff bad" --file "$TMP/request.md" --effort turbo 2>&1)"; rc=$?
assert_eq "$rc" 1 "(bad effort)"
echo "$out" | grep -q "low" && ok || fail "error does not list supported levels: $out"
NOEFF="$TMP/claude-noeff"; mkdir -p "$NOEFF"; printf '#!/bin/bash\n[ "$1" = "--help" ] && exit 0\nexit 0\n' > "$NOEFF/claude"; chmod +x "$NOEFF/claude"
out="$(cd "$TMP/repoA" && SECONDOPINION_CLAUDE="$NOEFF/claude" "$AM" ask --topic "eff unsup" --file "$TMP/request.md" --effort low 2>&1)"; rc=$?
assert_eq "$rc" 1 "(unsupported CLI)"
echo "$out" | grep -qi "does not support" && ok || fail "unsupported --effort not named: $out"
assert_rc 1 env SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "eff ctl" --file "$TMP/request.md" --effort "$(printf 'x\001y')"
assert_eq "$(ls "$SECONDOPINION_DIR/exchanges" | wc -l)" "$((before_count+1))" "(only the one valid ask created an exchange)"

t "ask records requested and realized model/effort; realized is 'unproven' when the output does not prove it"
out="$(cd "$TMP/repoA" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "mod" --file "$TMP/request.md" --model claude-test-model --timeout 60 2>/dev/null)"
IDMOD="$(echo "$out" | sed -n 's/^Exchange-ID: //p' | head -1)"
st="$("$AM" status "$IDMOD")"
assert_eq "$(echo "$st" | val requested_model)" "claude-test-model"
assert_eq "$(echo "$st" | val realized_model)" "claude-stub-model-1" "(proven from modelUsage in the responder output)"
out="$(cd "$TMP/repoA" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" STUB_PLAIN_OUTPUT=1 "$AM" ask --topic "mod unproven" --file "$TMP/request.md" --model m2 --timeout 60 2>/dev/null)"
IDM2="$(echo "$out" | sed -n 's/^Exchange-ID: //p' | head -1)"
assert_eq "$("$AM" status "$IDM2" | val realized_model)" "unproven"

t "follow-up: a NEW linked exchange embeds the validated parent; the parent's files stay byte-identical"
PD="$("$AM" path "$IDMOD")"
H1="$(sha256sum "$PD/prompt.md" "$PD/response.md" | sha256sum)"
out="$(cd "$TMP/repoA" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --follow-up "$IDMOD" --topic "fu" --task "And what about X?" --timeout 60 2>/dev/null)"; rc=$?
assert_eq "$rc" 0 "(follow-up ask)"
IDFU="$(echo "$out" | sed -n 's/^Exchange-ID: //p' | head -1)"
[ -n "$IDFU" ] && [ "$IDFU" != "$IDMOD" ] && ok || fail "no new exchange for the follow-up"
assert_eq "$("$AM" status "$IDFU" | val parent_exchange)" "$IDMOD"
FUP="$("$AM" path "$IDFU")/prompt.md"
grep -q "^Parent-Exchange: $IDMOD$" "$FUP" && ok || fail "prompt header lacks Parent-Exchange"
grep -q "And what about X?" "$FUP" && ok || fail "follow-up task text missing"
grep -q "verdict: PROVEN stub-answer" "$FUP" && ok || fail "validated parent response not embedded"
H2="$(sha256sum "$PD/prompt.md" "$PD/response.md" | sha256sum)"
assert_eq "$H2" "$H1" "(parent files untouched)"

t "follow-up: refused for a cross-repository parent and for a tampered parent response; nothing is created"
before_count="$(ls "$SECONDOPINION_DIR/exchanges" | wc -l)"
out="$(cd "$TMP/repoB" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --follow-up "$IDMOD" --topic "xrepo" --task "t" 2>&1)"; rc=$?
assert_eq "$rc" 1 "(cross-repo follow-up)"
echo "$out" | grep -qi "repositor" && ok || fail "cross-repo refusal not explained: $out"
printf 'tamper' >> "$PD/response.md"
out="$(cd "$TMP/repoA" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --follow-up "$IDMOD" --topic "tampered" --task "t" 2>&1)"; rc=$?
assert_eq "$rc" 1 "(tampered parent)"
assert_eq "$(ls "$SECONDOPINION_DIR/exchanges" | wc -l)" "$before_count" "(no exchange created on refusals)"

t "resume: --persist opts into a stored session id; --resume reuses it; defaults stay private (--no-session-persistence)"
out="$(cd "$TMP/repoA" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "persist" --file "$TMP/request.md" --persist --timeout 60 2>/dev/null)"
IDPP="$(echo "$out" | sed -n 's/^Exchange-ID: //p' | head -1)"
grep -qx -- "--session-id" "$STUB_ARGV_FILE" && ok || fail "--persist did not pass --session-id"
grep -qx -- "--no-session-persistence" "$STUB_ARGV_FILE" && fail "--persist must drop --no-session-persistence" || ok
SID="$("$AM" status "$IDPP" | val session_id)"
echo "$SID" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' && ok || fail "no uuid session id recorded: '$SID'"
out="$(cd "$TMP/repoA" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --resume "$IDPP" --topic "resumed" --task "continue please" --timeout 60 2>/dev/null)"; rc=$?
assert_eq "$rc" 0 "(resume ask)"
grep -qx -- "--resume" "$STUB_ARGV_FILE" && grep -qx -- "$SID" "$STUB_ARGV_FILE" && ok || fail "--resume did not pass the stored session id"
IDRES="$(echo "$out" | sed -n 's/^Exchange-ID: //p' | head -1)"
assert_eq "$("$AM" status "$IDRES" | val parent_exchange)" "$IDPP"
# default asks remain private
(cd "$TMP/repoA" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "private" --file "$TMP/request.md" --timeout 60 >/dev/null 2>&1)
grep -qx -- "--no-session-persistence" "$STUB_ARGV_FILE" && ok || fail "default ask lost --no-session-persistence"

t "resume: refused without a persisted session, with a malformed stored id, cross-repo, or combined with --fresh"
out="$(cd "$TMP/repoA" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --resume "$IDEFF" --topic "r1" --task t 2>&1)"; rc=$?
assert_eq "$rc" 1 "(no persisted session)"
echo "$out" | grep -q -- "--follow-up" && ok || fail "refusal does not point at --follow-up: $out"
d="$("$AM" path "$IDPP")"
( exec 9>>"$d/.lock"; flock 9; sed -i 's/^session_id=.*/session_id=abc;rm -rf ~/' "$d/meta" )
assert_rc 1 env SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --resume "$IDPP" --topic "r2" --task t
( exec 9>>"$d/.lock"; flock 9; sed -i "s/^session_id=.*/session_id=$SID/" "$d/meta" )
out="$(cd "$TMP/repoB" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --resume "$IDPP" --topic "r3" --task t 2>&1)"; rc=$?
assert_eq "$rc" 1 "(cross-repo resume)"
assert_rc 1 env SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --resume "$IDPP" --fresh --topic "r4" --task t

# ===========================================================================
# Phase 7: review modes + structured results

t "review: read-only review exchange with working-tree scope and a structured-output contract; --write refused"
echo change > "$TMP/repoA/newfile.txt"
out="$(cd "$TMP/repoA" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" review --task "focus on newfile" --timeout 60 2>/dev/null)"; rc=$?
assert_eq "$rc" 0 "(review rc)"
IDRV="$(echo "$out" | sed -n 's/^Exchange-ID: //p' | head -1)"
[ -n "$IDRV" ] && ok || fail "no review exchange id"
RVP="$("$AM" path "$IDRV")/prompt.md"
grep -qi "review" "$RVP" && grep -qi "working.tree\|uncommitted" "$RVP" && ok || fail "review charter/scope missing from prompt"
grep -q '"verdict"' "$RVP" && grep -q "needs-attention" "$RVP" && ok || fail "structured output contract missing from prompt"
grep -qi "read-only\|do not fix\|must not modify" "$RVP" && ok || fail "read-only rule missing from prompt"
assert_eq "$("$AM" status "$IDRV" | val review_mode)" "normal"
assert_rc 1 env SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" review --task t --write

t "review --adversarial: challenge framing; review --base validates the ref before any exchange"
out="$(cd "$TMP/repoA" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" review --adversarial --task "challenge the design" --timeout 60 2>/dev/null)"
IDAV="$(echo "$out" | sed -n 's/^Exchange-ID: //p' | head -1)"
AVP="$("$AM" path "$IDAV")/prompt.md"
grep -qi "challenge\|assumption" "$AVP" && ok || fail "adversarial framing missing"
assert_eq "$("$AM" status "$IDAV" | val review_mode)" "adversarial"
out="$(cd "$TMP/repoA" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" review --base main --task "t" --timeout 60 2>/dev/null)"
IDBV="$(echo "$out" | sed -n 's/^Exchange-ID: //p' | head -1)"
grep -q "main...HEAD\|main\.\.\.HEAD" "$("$AM" path "$IDBV")/prompt.md" && ok || fail "base scope missing from prompt"
before_count="$(ls "$SECONDOPINION_DIR/exchanges" | wc -l)"
out="$(cd "$TMP/repoA" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" review --base does-not-exist --task t 2>&1)"; rc=$?
assert_eq "$rc" 1 "(bad --base)"
assert_eq "$(ls "$SECONDOPINION_DIR/exchanges" | wc -l)" "$before_count" "(no exchange for a bad ref)"

t "review-result: schema-valid JSON parses; invalid/truncated JSON falls back honestly with the raw preserved; tampering refused"
GOODJSON='```json
{"verdict":"needs-attention","summary":"one problem","findings":[{"severity":"major","title":"t","body":"b","file":"f.c","line_start":1,"line_end":2,"confidence":"high","recommendation":"fix"}],"next_steps":["fix it"]}
```'
out="$(cd "$TMP/repoA" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" STUB_BODY="Prose first.
$GOODJSON" "$AM" review --task "structured" --timeout 60 2>/dev/null)"
IDSJ="$(echo "$out" | sed -n 's/^Exchange-ID: //p' | head -1)"
rr="$("$AM" review-result "$IDSJ" 2>/dev/null)"; rc=$?
assert_eq "$rc" 0 "(review-result rc on valid json)"
assert_eq "$(echo "$rr" | val parse_ok)" "yes"
assert_eq "$(echo "$rr" | val verdict)" "needs-attention"
assert_eq "$(echo "$rr" | val findings)" "1"
out="$(cd "$TMP/repoA" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" STUB_BODY='```json
{"verdict":"broken...' "$AM" review --task "broken structured" --timeout 60 2>/dev/null)"
IDBJ="$(echo "$out" | sed -n 's/^Exchange-ID: //p' | head -1)"
rr="$("$AM" review-result "$IDBJ" 2>&1)"; rc=$?
assert_eq "$rc" 3 "(honest parse-failure rc)"
assert_eq "$(echo "$rr" | val parse_ok)" "no"
echo "$rr" | grep -q "broken structured\|verdict.:.broken" && ok || fail "raw response not preserved on parse failure"
d="$("$AM" path "$IDSJ")"; printf 'x' >> "$d/response.md"
rr="$("$AM" review-result "$IDSJ" 2>&1)"; rc=$?
assert_eq "$rc" 1 "(tampered response refused)"
echo "$rr" | grep -q "parse_ok=yes" && fail "tampered response still reported parsed" || ok

t "ask --max-turns: first-class turn budget — default 60, env override, flag beats env, invalid values refused"
(cd "$TMP/repoA" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "mt default" --file "$TMP/request.md" --timeout 60 >/dev/null 2>&1)
grep -qx -- "--max-turns" "$STUB_ARGV_FILE" && grep -qx -- "60" "$STUB_ARGV_FILE" && ok || fail "default --max-turns 60 missing from argv"
(cd "$TMP/repoA" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" SECONDOPINION_MAX_TURNS=90 "$AM" ask --topic "mt env" --file "$TMP/request.md" --timeout 60 >/dev/null 2>&1)
grep -qx -- "90" "$STUB_ARGV_FILE" && ok || fail "SECONDOPINION_MAX_TURNS env not honoured"
(cd "$TMP/repoA" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" SECONDOPINION_MAX_TURNS=90 "$AM" ask --topic "mt flag" --file "$TMP/request.md" --max-turns 137 --timeout 60 >/dev/null 2>&1)
grep -qx -- "137" "$STUB_ARGV_FILE" && ok || fail "--max-turns flag does not override the env"
grep -qx -- "90" "$STUB_ARGV_FILE" && fail "env value leaked into argv alongside the flag" || ok
before_count="$(ls "$SECONDOPINION_DIR/exchanges" | wc -l)"
assert_rc 1 env SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "mt zero" --file "$TMP/request.md" --max-turns 0
assert_rc 1 env SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "mt abc" --file "$TMP/request.md" --max-turns abc
assert_eq "$(ls "$SECONDOPINION_DIR/exchanges" | wc -l)" "$before_count" "(no exchange for invalid --max-turns)"

t "review --max-turns passes through"
(cd "$TMP/repoA" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" review --task "mt review" --max-turns 141 --timeout 60 >/dev/null 2>&1)
grep -qx -- "141" "$STUB_ARGV_FILE" && ok || fail "review did not pass --max-turns through"

# ===========================================================================
# Retention notice (stderr-only, transition-only)

t "archive: an over-bound bucket prints a retention note on STDERR only; stdout stays parseable; idempotent re-archive is silent"
NSTORE="$TMP/store-notice"; mkrepo "$TMP/repoF"
N1="$( (cd "$TMP/repoF" && SECONDOPINION_DIR="$NSTORE" "$AM" new --topic n1) | val exchange_id )"
N2="$( (cd "$TMP/repoF" && SECONDOPINION_DIR="$NSTORE" "$AM" new --topic n2) | val exchange_id )"
N3="$( (cd "$TMP/repoF" && SECONDOPINION_DIR="$NSTORE" "$AM" new --topic n3) | val exchange_id )"
SECONDOPINION_DIR="$NSTORE" SECONDOPINION_RETAIN=2 "$AM" archive "$N1" --force >/dev/null 2>"$TMP/n.err"
[ -s "$TMP/n.err" ] && fail "note printed although the bucket is under the bound: $(cat "$TMP/n.err")" || ok
SECONDOPINION_DIR="$NSTORE" SECONDOPINION_RETAIN=2 "$AM" archive "$N2" --force >/dev/null 2>/dev/null
out="$(SECONDOPINION_DIR="$NSTORE" SECONDOPINION_RETAIN=2 "$AM" archive "$N3" --force 2>"$TMP/n.err")"
grep -q "retention" "$TMP/n.err" && grep -q "prune" "$TMP/n.err" && ok || fail "no retention note on stderr for an over-bound bucket: $(cat "$TMP/n.err")"
echo "$out" | grep -q "retention" && fail "retention note leaked into archive stdout" || ok
assert_eq "$(echo "$out" | tail -1)" "archive_dir=$NSTORE/archive/$N3" "(stdout record shape unchanged)"
out="$(SECONDOPINION_DIR="$NSTORE" SECONDOPINION_RETAIN=2 "$AM" archive "$N3" 2>"$TMP/n.err")"
[ -s "$TMP/n.err" ] && fail "idempotent re-archive printed a note: $(cat "$TMP/n.err")" || ok

t "jobs: repo-scoped listing appends the retention note on STDERR when the bucket is over the bound"
out="$(cd "$TMP/repoF" && SECONDOPINION_DIR="$NSTORE" SECONDOPINION_RETAIN=2 "$AM" jobs 2>"$TMP/n.err")"
grep -q "retention" "$TMP/n.err" && grep -q "prune" "$TMP/n.err" && ok || fail "no jobs retention note: $(cat "$TMP/n.err")"
echo "$out" | grep -q "retention" && fail "retention note leaked into the jobs table" || ok

# ===========================================================================
# Sandbox fixes: startup handshake, ask --attach, PID-namespace warning

t "ask --background: a responder that dies at startup is reported startup-failed (exit 1); the exchange stays published"
out="$(cd "$TMP/repoA" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" STUB_MODE=fail "$AM" ask --topic "hs fail" --file "$TMP/request.md" --background 2>&1)"; rc=$?
assert_eq "$rc" 1 "(startup failure must be nonzero)"
echo "$out" | grep -q "responder=startup-failed" && ok || fail "no startup-failed report: $out"
IDHF="$(echo "$out" | val exchange_id)"
assert_eq "$("$AM" status "$IDHF" | val state)" "published" "(exchange stays recoverable)"
echo "$out" | grep -q "responder_log=" && ok || fail "startup failure does not point at the log"

t "ask --background: healthy slow and fast responders still report background/answered with exit 0"
out="$(cd "$TMP/repoA" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" STUB_MODE=slow "$AM" ask --topic "hs slow" --file "$TMP/request.md" --background 2>/dev/null)"; rc=$?
assert_eq "$rc" 0 "(slow responder)"
echo "$out" | grep -q "responder=background" && ok || fail "healthy background not reported: $out"
IDHS="$(echo "$out" | val exchange_id)"; "$AM" cancel "$IDHS" >/dev/null 2>&1
out="$(cd "$TMP/repoA" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --topic "hs fast" --file "$TMP/request.md" --background 2>/dev/null)"; rc=$?
assert_eq "$rc" 0 "(fast responder)"
IDHA="$(echo "$out" | val exchange_id)"
assert_rc 0 "$AM" wait "$IDHA" --timeout 30

t "ask --attach: re-launches a responder for an existing published exchange; refuses claimed/answered/mixed arguments"
res="$(cd "$TMP/repoA" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --attach "$IDHF" --timeout 60 2>/dev/null)"; rc=$?
assert_eq "$rc" 0 "(attach to the startup-failed exchange)"
echo "$res" | grep -q "stub-answer" && ok || fail "attach did not return the validated answer: $res"
assert_eq "$("$AM" status "$IDHF" | val state)" "answered"
out="$(cd "$TMP/repoA" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --attach "$IDHF" 2>&1)"; rc=$?
assert_eq "$rc" 1 "(attach to an answered exchange)"
echo "$out" | grep -q "result" && ok || fail "answered-attach refusal lacks the result hint: $out"
CLID="$(cd "$TMP/repoA" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" STUB_MODE=fail "$AM" ask --topic "attach claimed" --file "$TMP/request.md" --background 2>/dev/null | val exchange_id)"
"$AM" claim "$CLID" --owner someone-else >/dev/null 2>&1
out="$(cd "$TMP/repoA" && SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --attach "$CLID" 2>&1)"; rc=$?
assert_eq "$rc" 1 "(attach to a claimed exchange)"
echo "$out" | grep -qi "claim" && ok || fail "claimed-attach refusal does not explain the claim: $out"
assert_rc 1 env SECONDOPINION_CLAUDE="$STUB_DIR/claude" "$AM" ask --attach "$IDHF" --task "extra"

t "sandbox: --background inside a PID namespace prints a teardown warning; the post-mortem is honest"
if unshare -Ur -pf true 2>/dev/null; then
  out="$(env SECONDOPINION_CLAUDE="$STUB_DIR/claude" STUB_MODE=slow unshare -Ur -pf --mount-proc bash -c "cd '$TMP/repoA' && '$AM' ask --topic sbx --file '$TMP/request.md' --background" 2>&1)"; rc=$?
  echo "$out" | grep -qi "sandbox" && echo "$out" | grep -qi "killed\|will not survive" && ok || fail "no sandbox teardown warning: $out"
  IDSB="$(echo "$out" | val exchange_id)"
  sleep 1
  assert_eq "$("$AM" status "$IDSB" | val responder_status)" "exited" "(responder died with the namespace)"
  assert_rc 1 "$AM" result "$IDSB"
  "$AM" archive "$IDSB" --force >/dev/null 2>&1
else
  echo "note: unprivileged user+pid namespaces unavailable; sandbox reproduction skipped"
fi

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
