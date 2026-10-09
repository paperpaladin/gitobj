#!/bin/bash
# gitobj test harness. git is the oracle: if git and gitobj disagree about
# git's own object database, gitobj is wrong, because git IS the format.
#
# Usage: t/run.sh [path-to-gitobj-binary]
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
GITOBJ=${1:-$ROOT/gitobj}
case $GITOBJ in /*) ;; *) GITOBJ="$ROOT/${GITOBJ#./}" ;; esac
GIT=${GIT:-git}

# Scratch carries the pid AND the binary name: `make test` and `make
# test-asan` must be able to run at once, and so must two concurrent agents.
# A fixed scratch path in a sibling repo has already caused one suite to
# delete another's fixtures mid-run.
TMP=$HERE/tmp.$(basename "$GITOBJ").$$
trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT INT TERM
rm -rf "$TMP"
mkdir -p "$TMP"

pass=0
fail=0
ok() { pass=$((pass+1)); }
no() { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }
eq() { if [ "$2" = "$3" ]; then ok; else no "$1 (got '$2' want '$3')"; fi; }
assert() { local n=$1; shift; if "$@" >/dev/null 2>&1; then ok; else no "$n"; fi; }
refute() { local n=$1; shift; if "$@" >/dev/null 2>&1; then no "$n (succeeded)"; else ok; fi; }

[ -x "$GITOBJ" ] || { echo "no $GITOBJ -- run make first"; exit 1; }

# A throwaway repository we own, for anything that writes.
SCRATCH=$TMP/scratch
$GIT init -q "$SCRATCH"
$GIT -C "$SCRATCH" config user.name PLACEHOLDER
$GIT -C "$SCRATCH" config user.email placeholder@invalid
SG="$GIT -C $SCRATCH"

# =====================================================================
# 1. object names: git hash-object is the authority
# =====================================================================
# The name of an object is the SHA-1 of its own serialisation, so agreeing
# with git here is agreeing about the header format, the length field and the
# NUL, all at once.
mkdir -p "$TMP/fix"
: > "$TMP/fix/empty"
printf 'hello\n' > "$TMP/fix/hello"
printf 'no trailing newline' > "$TMP/fix/nonl"
printf 'a\000b\377\n' > "$TMP/fix/binary"
printf 'crlf\r\nand\r\ntrailing   \n\n\n' > "$TMP/fix/crlf"
head -c 100000 /dev/urandom > "$TMP/fix/rand"
# Spans the 56-byte SHA-1 padding boundary from both sides, plus a multiple
# of 64 exactly: the three lengths where a hand-written SHA-1 breaks.
for n in 54 55 56 57 63 64 65 119 120 128; do
	head -c $n /dev/zero | tr '\0' 'z' > "$TMP/fix/len$n"
done

for f in "$TMP"/fix/*; do
	for t in blob commit tree tag; do
		got=$("$GITOBJ" hash "$t" "$f")
		want=$($SG hash-object -t "$t" --literally -w "$f")
		eq "hash $t $(basename "$f")" "$got" "$want"
	done
done

# stdin path
eq "hash blob via stdin" \
	"$("$GITOBJ" hash blob < "$TMP/fix/hello")" \
	"$($SG hash-object -t blob --stdin < "$TMP/fix/hello")"

refute "hash rejects an unknown type" "$GITOBJ" hash frobnicate "$TMP/fix/hello"

# =====================================================================
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
