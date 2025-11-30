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
# 2. reading loose objects: git cat-file is the authority
# =====================================================================
# The corpora are real histories. They are COPIED here rather than read in
# place: anything in this suite that repacks would otherwise be writing into
# a sibling repository's .git, and a reader has no business doing that.
CORPUS_SMALL="cc tarx inflate"
CORPUS_BIG="psh unrepro cmark httpd wasmi notally-molly"
copy_corpus() {
	local r
	for r in "$@"; do
		[ -d "$ROOT/../$r/.git" ] || continue
		mkdir -p "$TMP/corpus"
		cp -r "$ROOT/../$r/.git" "$TMP/corpus/$r" 2>/dev/null
		chmod -R u+rw "$TMP/corpus/$r"
		echo "$r"
	done
}
HAVE_SMALL=$(copy_corpus $CORPUS_SMALL)

# Every loose object in the small corpora, all four fields, against git.
# `git cat-file <type> <sha>` prints the RAW payload for any type, which is
# what `gitobj raw` must reproduce byte for byte -- including for trees,
# whose raw form is binary and whose `-p` form is not.
loose_shas() {
	# -regextype matters: find's default is emacs regex, where "+" is a
	# LITERAL plus, so the default-syntax version of this matched nothing
	# useful and quietly handed the pack .idx/.rev files to git as object
	# names. The guard below is what caught it.
	find "$1/objects" -type f -regextype posix-extended \
		-regex '.*/objects/[0-9a-f]{2}/[0-9a-f]{38}' 2>/dev/null |
		sed -E 's|.*/([0-9a-f]{2})/([0-9a-f]+)$|\1\2|' | sort
}

nloose=0
for r in $HAVE_SMALL; do
	G="$TMP/corpus/$r"
	OD="$G/objects"
	for sha in $(loose_shas "$G"); do
		nloose=$((nloose+1))
		t=$("$GITOBJ" type "$OD" "$sha")
		gt=$($GIT --git-dir="$G" cat-file -t "$sha")
		eq "type $r/$sha" "$t" "$gt"
		eq "size $r/$sha" "$("$GITOBJ" size "$OD" "$sha")" \
			"$($GIT --git-dir="$G" cat-file -s "$sha")"
		"$GITOBJ" raw "$OD" "$sha" > "$TMP/ours" 2>/dev/null
		$GIT --git-dir="$G" cat-file "$gt" "$sha" > "$TMP/theirs"
		assert "raw $r/$sha" cmp -s "$TMP/ours" "$TMP/theirs"
	done
done
[ "$nloose" -ge 20 ] && ok || no "only $nloose loose objects in the small corpora"

# Refusals. A loose object file is one zlib stream and nothing else, so each
# of these is a distinct lie about the bytes.
OD2=$SCRATCH/.git/objects
hb=$($SG hash-object -w --stdin < "$TMP/fix/hello")
HBPATH="$OD2/${hb:0:2}/${hb:2}"
mkdir -p "$TMP/bad/objects/ab"
head -c 10 "$HBPATH" > "$TMP/bad/objects/ab/${hb:2}"
refute "a truncated loose object is refused" \
	"$GITOBJ" raw "$TMP/bad/objects" "ab${hb:2}"
cp "$HBPATH" "$TMP/bad/objects/ab/${hb:2}"
printf 'junk' >> "$TMP/bad/objects/ab/${hb:2}"
refute "trailing bytes after the zlib stream are refused" \
	"$GITOBJ" raw "$TMP/bad/objects" "ab${hb:2}"
printf 'not a zlib stream at all' > "$TMP/bad/objects/ab/${hb:2}"
refute "a non-zlib loose object is refused" \
	"$GITOBJ" raw "$TMP/bad/objects" "ab${hb:2}"
refute "a short object name is refused" "$GITOBJ" type "$OD2" "${hb:0:7}"
refute "a missing object is refused" "$GITOBJ" type "$OD2" \
	0000000000000000000000000000000000000000

# =====================================================================
# 3. the hard invariant: every object hashes back to its own name
# =====================================================================
# git chose these filenames; we recompute the hash. There is no fixture to
# maintain and nothing of ours on the other side of the comparison.
HAVE_BIG=$(copy_corpus $CORPUS_BIG)
total_verified=0
for r in $HAVE_SMALL $HAVE_BIG; do
	out=$("$GITOBJ" verify "$TMP/corpus/$r/objects")
	rc=$?
	eq "verify $r exits 0" "$rc" 0
	n=${out##*$'\n'}
	n=${n%% *}
	case $(printf '%s' "$out" | tail -1) in
	*", 0 mismatched") ok ;;
	*) no "verify $r reported a mismatch: $(printf '%s' "$out" | tail -1)" ;;
	esac
	total_verified=$((total_verified + n))
done
# The count itself is an assertion: a verify that walked an empty directory
# also reports zero mismatches.
[ "$total_verified" -ge 300 ] && ok || no "only $total_verified objects verified"
printf 'verified %d loose objects across %s\n' "$total_verified" \
	"$(echo $HAVE_SMALL $HAVE_BIG | tr '\n' ' ')"

# `gitobj ls` against `git cat-file --batch-all-objects --batch-check`, which
# emits exactly the same three fields. Only repositories with no packfile can
# be compared whole this way; the packed ones come back in section 9.
for r in $HAVE_SMALL $HAVE_BIG; do
	[ -n "$(ls "$TMP/corpus/$r/objects/pack/"*.idx 2>/dev/null)" ] && continue
	$GIT --git-dir="$TMP/corpus/$r" cat-file --batch-all-objects \
		--batch-check | sort > "$TMP/theirs"
	"$GITOBJ" ls "$TMP/corpus/$r/objects" > "$TMP/ours"
	assert "ls $r matches git batch-check" cmp -s "$TMP/ours" "$TMP/theirs"
	nl=$(wc -l < "$TMP/theirs")
	[ "$nl" -ge 50 ] && ok || no "ls corpus $r has only $nl objects"
done

# A deliberately corrupted loose object: same filename, different content.
# verify must notice, because that is the only thing it is for.
mkdir -p "$TMP/corrupt/objects"
cp -r "$TMP/corpus/cc/objects/"[0-9a-f][0-9a-f] "$TMP/corrupt/objects/" 2>/dev/null
victim=$("$GITOBJ" ls "$TMP/corrupt/objects" | awk '$2=="blob"{print $1; exit}')
printf 'tampered\n' > "$TMP/t.in"
"$GITOBJ" hash blob "$TMP/t.in" >/dev/null
$SG hash-object -w "$TMP/t.in" >/dev/null
nb=$($SG hash-object "$TMP/t.in")
cp "$SCRATCH/.git/objects/${nb:0:2}/${nb:2}" \
	"$TMP/corrupt/objects/${victim:0:2}/${victim:2}"
refute "verify catches a loose object whose content was swapped" \
	"$GITOBJ" verify "$TMP/corrupt/objects"
assert "and says which one" sh -c \
	"'$GITOBJ' verify '$TMP/corrupt/objects' | grep -q '^MISMATCH $victim '"

# =====================================================================
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
