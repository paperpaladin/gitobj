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
# refute NAME CMD... -- the command must exit 1 exactly.
#
# This was `if "$@"; then no; else ok; fi`, which accepted any nonzero status
# as a refusal. PLAN.md:52 gives the contract as "0 success, 1 refused or not
# found, 2 the command line was wrong" and nothing asserted it, so a crash
# counted as a clean refusal across all 15 refusal assertions: replacing
# die()'s exit(1) with a null-pointer store left "1002 passed, 0 failed" and
# exit 0, with four segfaults printed by the shell.
#
# It also makes the Makefile's ASAN_OPTIONS=exitcode=86 true. That comment
# says exitcode=86 is load-bearing "because t/run.sh asserts exit 1 to mean
# cleanly refused" -- which it did not, anywhere; a sanitizer abort exiting 1
# was indistinguishable from a refusal. Now it is.
refute() {
	local n=$1; shift
	"$@" >/dev/null 2>&1
	local rc=$?
	if [ "$rc" -eq 1 ]; then ok
	elif [ "$rc" -eq 0 ]; then no "$n (succeeded)"
	else no "$n (exit $rc, not a clean refusal)"; fi
}

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
# A corpus this suite builds itself, with git, so that the oracle does not
# depend on which other repositories happen to be sitting next to this one.
#
# That dependency was not a theoretical weakness. Cloned on its own and run,
# this suite failed five assertions: the two corpus-completeness checks, the
# 300-object floor, and the corruption test, which hardcoded ../cc and sent
# its cp errors to /dev/null -- so with no sibling it copied nothing, looked
# for a victim object in an empty directory, and "tested" that verify rejects
# a corruption that was never planted. A reader's first `make test` is not the
# place to discover any of that.
#
# These are bare repositories, which makes $G/objects the same shape as a
# copied .git. Blobs go in through one `hash-object --stdin-paths` rather than
# one process each; the tree, commit and tag are plumbing, so all four object
# types are present. Nothing is packed, which also means the whole-repository
# `ls` comparison below has something to run against -- every sibling in the
# collection has a packfile, so that oracle was skipping entirely.
SELF_CORPUS="self_a self_b self_c self_p"
SELF_BLOBS=120

mk_selfcorpus() {
	name=$1
	G="$TMP/corpus/$name"
	mkdir -p "$G" "$TMP/mk/$name"
	$GIT init -q --bare "$G" || return 1
	i=0
	: > "$TMP/mk/$name/paths"
	while [ "$i" -lt "$SELF_BLOBS" ]; do
		printf '%s blob %d\n' "$name" "$i" > "$TMP/mk/$name/b$i"
		echo "$TMP/mk/$name/b$i" >> "$TMP/mk/$name/paths"
		i=$((i+1))
	done
	$GIT --git-dir="$G" hash-object -w --stdin-paths \
		< "$TMP/mk/$name/paths" > "$TMP/mk/$name/shas" || return 1
	b=$(head -1 "$TMP/mk/$name/shas")
	tree=$(printf '100644 blob %s\tb0\n' "$b" | $GIT --git-dir="$G" mktree) || return 1
	# Fixed dates: these objects are compared against git by name, and a name
	# that moves every run is a fixture that cannot be reasoned about.
	commit=$(GIT_AUTHOR_NAME=corpus GIT_AUTHOR_EMAIL=corpus@invalid \
		GIT_COMMITTER_NAME=corpus GIT_COMMITTER_EMAIL=corpus@invalid \
		GIT_AUTHOR_DATE='2001-01-01T00:00:00Z' \
		GIT_COMMITTER_DATE='2001-01-01T00:00:00Z' \
		$GIT --git-dir="$G" commit-tree "$tree" -m "corpus commit in $name") || return 1
	printf 'object %s\ntype commit\ntag %s\ntagger corpus <corpus@invalid> 978307200 +0000\n\nannotated\n' \
		"$commit" "$name" | $GIT --git-dir="$G" mktag > /dev/null || return 1
	# A ref, so that `git clone -s` has something to clone. It points at an
	# object that is already there and so moves no name; everything else
	# here reads the object store directly and does not care.
	$GIT --git-dir="$G" update-ref refs/heads/main "$commit" || return 1
	# One of them is moved wholesale into a pack. A clone with no siblings
	# otherwise has nothing but loose objects in its corpus, and every
	# comparison below would run over one half of the store while reporting
	# a count that looks like the whole of it. `repack` is no use here:
	# nothing in these repositories is reachable from a ref, so it would
	# leave 119 of the 120 blobs loose and drop the rest.
	case $name in
	*_p)
		$GIT --git-dir="$G" cat-file --batch-all-objects --batch-check |
			awk '{print $1}' > "$TMP/mk/$name/all" || return 1
		$GIT --git-dir="$G" pack-objects --non-empty --delta-base-offset \
			--threads=1 "$G/objects/pack/pack" \
			< "$TMP/mk/$name/all" > /dev/null || return 1
		rm -rf "$G/objects"/??
		;;
	esac
	echo "$name"
}

HAVE_SELF=
for r in $SELF_CORPUS; do
	HAVE_SELF="$HAVE_SELF $(mk_selfcorpus "$r")"
done
# Deterministic, so this is pinned rather than reported: if building a corpus
# starts failing, every floor below becomes easier to clear by accident.
eq "the self-built corpus has all its repos" \
	"$(printf '%s\n' $HAVE_SELF | grep -c .)" \
	"$(printf '%s\n' $SELF_CORPUS | grep -c .)"
for r in $HAVE_SELF; do
	assert "$r has all four object types" \
		test "$($GIT --git-dir="$TMP/corpus/$r" cat-file --batch-all-objects \
			--batch-check | awk '{print $2}' | sort -u | tr '\n' ' ')" \
		= "blob commit tag tree "
	# Which half of the store this repository is. Both shapes have to be
	# present, and the assertion is per repository rather than over the set
	# because a corpus that drifted to all-loose or all-packed would still
	# clear a floor. No .idx, rather than no pack/ directory: `git init
	# --bare` creates an empty objects/pack/, so testing for the
	# directory's absence asserted something that is never true.
	case $r in
	*_p) assert "$r is packed, so the packed half of the store is read" \
		test -n "$(ls "$TMP/corpus/$r/objects/pack/"*.idx 2>/dev/null)" ;;
	*)   assert "$r is unpacked, so the loose half of the store is read" \
		test -z "$(ls "$TMP/corpus/$r/objects/pack/"*.idx 2>/dev/null)" ;;
	esac
done

# The sibling repositories are an ADDITIONAL corpus: real histories, far more
# varied than anything built here. They are optional, because a clone of this
# repository alone has none of them -- what is reported is how many were
# found, not an assertion that all of them were. notally-molly is gone from
# the list: it is an unrelated fork that happened to be adjacent.
CORPUS_SMALL="cc tarx inflate"
CORPUS_BIG="psh unrepro cmark httpd wasmi"
# Three things this did not do: report a repo it skipped, check that cp
# succeeded, or tell the caller how many it got. A sibling that is not a git
# repo was skipped in silence, and `cp -r ... 2>/dev/null` discarded both the
# error text and the status -- so a half-copied repo was still echoed as
# present, which happened for real during an audit when a transient file
# vanished mid-copy. The only backstops were slack floors (nloose >= 20,
# total_verified >= 300 against an actual 650), so 5 of the 9 repos -- 49% of
# the objects -- could disappear and leave the suite green.
copy_corpus() {
	local r
	for r in "$@"; do
		if [ ! -d "$ROOT/../$r/.git" ]; then
			echo "SKIP corpus repo $r: no .git" >&2
			continue
		fi
		mkdir -p "$TMP/corpus"
		if ! cp -r "$ROOT/../$r/.git" "$TMP/corpus/$r" 2>"$TMP/cp.err"; then
			echo "SKIP corpus repo $r: cp failed: $(head -1 "$TMP/cp.err")" >&2
			rm -rf "$TMP/corpus/$r"
			continue
		fi
		chmod -R u+rw "$TMP/corpus/$r"
		echo "$r"
	done
}
FOUND_SMALL=$(copy_corpus $CORPUS_SMALL)
printf 'sibling corpus (small): %d of %d present\n' \
	"$(printf '%s\n' $FOUND_SMALL | grep -c .)" \
	"$(printf '%s\n' $CORPUS_SMALL | grep -c .)"
# Reported, not asserted. The count used to be pinned so that a repo which
# silently stopped being copied was a failure -- the right instinct, but
# applied to the wrong thing: it made "you cloned only this repository" a test
# failure. What must not shrink silently is the corpus this suite controls,
# and that is pinned above.
HAVE_SMALL="$HAVE_SELF $FOUND_SMALL"

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

# git enumerates the set under test. `cat-file --batch-all-objects` lists
# every object in the store, loose and packed alike, so the sweep covers
# whatever is there rather than whatever we happened to look for. It used to
# drive off loose_shas, which found nothing at all in cc, tarx or inflate:
# every sibling has been repacked, so the sweep that the README described as
# running over three real histories was running over the self corpus alone
# and clearing its floor of 20 with that.
nobj=0
nloose=0
swept_from=
for r in $HAVE_SMALL; do
	G="$TMP/corpus/$r"
	OD="$G/objects"
	nl=$(loose_shas "$G" | grep -c .)
	nloose=$((nloose + nl))
	# Kept per repository rather than overwritten, because section 12 wants
	# the same list: git's account of what is in the store.
	$GIT --git-dir="$G" cat-file --batch-all-objects --batch-check |
		sort > "$TMP/corpus-all.$r"
	n=0
	while read -r sha gt gsz; do
		n=$((n+1))
		nobj=$((nobj+1))
		eq "type $r/$sha" "$("$GITOBJ" type "$OD" "$sha")" "$gt"
		eq "size $r/$sha" "$("$GITOBJ" size "$OD" "$sha")" "$gsz"
		"$GITOBJ" raw "$OD" "$sha" > "$TMP/ours" 2>/dev/null
		$GIT --git-dir="$G" cat-file "$gt" "$sha" > "$TMP/theirs"
		assert "raw $r/$sha" cmp -s "$TMP/ours" "$TMP/theirs"
		"$GITOBJ" cat "$OD" "$sha" > "$TMP/ours" 2>/dev/null
		$GIT --git-dir="$G" cat-file -p "$sha" > "$TMP/theirs"
		assert "cat -p $r/$sha" cmp -s "$TMP/ours" "$TMP/theirs"
	done < "$TMP/corpus-all.$r"
	[ "$n" -gt 0 ] && swept_from="$swept_from $r($n, $nl loose)"
done
[ "$nobj" -ge 20 ] && ok || no "only $nobj objects in the small corpora"
# Both halves of the store, counted. A sweep over an all-packed repository
# and a sweep over an all-loose one exercise entirely different code for
# every one of the four comparisons above, and the floor cannot tell them
# apart.
[ "$((nobj - nloose))" -ge 20 ] && ok ||
	no "only $((nobj - nloose)) of the swept objects came out of a pack"
printf 'per-object cat-file sweep:%s\n' "${swept_from:- nothing}"

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
# An abbreviated name is resolved rather than refused now, which is section
# 12's subject; this one stays here because it is the loose-object path.
eq "a 7-character prefix of a loose object resolves" \
	"$("$GITOBJ" type "$OD2" "${hb:0:7}")" "$("$GITOBJ" type "$OD2" "$hb")"
refute "a prefix below git's minimum of 4 characters is refused" \
	"$GITOBJ" type "$OD2" "${hb:0:3}"
refute "a missing object is refused" "$GITOBJ" type "$OD2" \
	0000000000000000000000000000000000000000

# =====================================================================
# 3. the hard invariant: every object hashes back to its own name
# =====================================================================
# git chose these filenames; we recompute the hash. There is no fixture to
# maintain and nothing of ours on the other side of the comparison.
HAVE_BIG=$(copy_corpus $CORPUS_BIG)
printf 'sibling corpus (big): %d of %d present\n' \
	"$(printf '%s\n' $HAVE_BIG | grep -c .)" \
	"$(printf '%s\n' $CORPUS_BIG | grep -c .)"
total_verified=0
for r in $HAVE_SMALL $HAVE_BIG; do
	out=$("$GITOBJ" verify "$TMP/corpus/$r/objects" 2>"$TMP/v.census")
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
# also reports zero mismatches. It counted only loose objects until `verify`
# learned to read a pack, and 8 of the 11 repositories here hold nothing but
# packed objects, so what it was really pinning was the self corpus.
[ "$total_verified" -ge 300 ] && ok || no "only $total_verified objects verified"
printf 'verified %d objects across %s\n' "$total_verified" \
	"$(echo $HAVE_SMALL $HAVE_BIG | tr '\n' ' ')"

# `gitobj ls` against `git cat-file --batch-all-objects --batch-check`, which
# emits exactly the same three fields for the same set of objects: every
# object in the store, loose and packed, each listed once even when it is
# both. This used to run only over a repository with no packfile, and 8 of
# the 11 have one, so it was skipping almost everything and saying so in a
# line nobody counted.
#
# Per line rather than as a file diff for the same reason the index and the
# pack comparisons are: over three thousand objects, `cmp` says only that
# something somewhere disagreed.
ls_compared=0
ls_objs=0
ls_loose=0
ls_packed=0
for r in $HAVE_SMALL $HAVE_BIG; do
	$GIT --git-dir="$TMP/corpus/$r" cat-file --batch-all-objects \
		--batch-check | sort > "$TMP/theirs"
	"$GITOBJ" ls "$TMP/corpus/$r/objects" > "$TMP/ours" 2> "$TMP/ls.census"
	eq "ls $r exits 0" "$?" 0
	nl=$(wc -l < "$TMP/theirs" | tr -d ' ')
	eq "ls $r lists as many objects as git does" \
		"$(wc -l < "$TMP/ours" | tr -d ' ')" "$nl"
	a=; b=
	while IFS= read -r a <&3 && IFS= read -r b <&4; do
		ls_objs=$((ls_objs + 1))
		eq "ls $r ${b%% *}" "$a" "$b"
	done 3< "$TMP/ours" 4< "$TMP/theirs"
	[ "$nl" -ge 50 ] && ok || no "ls corpus $r has only $nl objects"
	ls_compared=$((ls_compared + 1))
	ls_loose=$((ls_loose + $(sed -n 's/.*, \([0-9]*\) loose.*/\1/p' "$TMP/ls.census")))
	ls_packed=$((ls_packed + $(sed -n 's/.*loose, \([0-9]*\) from.*/\1/p' "$TMP/ls.census")))
done
eq "every corpus repository was compared whole" "$ls_compared" \
	"$(printf '%s\n' $HAVE_SMALL $HAVE_BIG | grep -c .)"
[ "$ls_objs" -ge 300 ] && ok ||
	no "only $ls_objs objects compared by the whole-repository ls"
# Both halves of every store. 8 of the 11 repositories hold nothing but
# packed objects and the other 3 nothing but loose ones, so without this the
# comparison could be whole and still have read only one kind.
[ "$ls_loose" -ge 300 ] && ok || no "only $ls_loose of the listed objects were loose"
[ "$ls_packed" -ge 100 ] && ok || no "only $ls_packed of the listed objects were packed"
printf 'ls against git batch-check: %d objects over %d repositories, %d loose and %d packed\n' \
	"$ls_objs" "$ls_compared" "$ls_loose" "$ls_packed"

# A deliberately corrupted loose object: same filename, different content.
# verify must notice, because that is the only thing it is for.
# Built from a self corpus, not ../cc. The sibling version copied with
# `2>/dev/null` and no status check, so on a standalone clone it copied
# nothing, found no victim in an empty directory, and asserted that verify
# rejects a corruption that had never been planted. A corruption test that
# passes without a corruption is the one test here that must not be allowed
# to fail open, so the planting is now checked at every step.
mkdir -p "$TMP/corrupt/objects"
# set -- to split on whitespace: `printf '%s' $HAVE_SELF` repeats the format
# once per word and so ran the three names together into one nonexistent path.
set -- $HAVE_SELF
corpus_src=$1
assert "the corruption test has a corpus to corrupt" \
	test -d "$TMP/corpus/$corpus_src/objects"
cp -r "$TMP/corpus/$corpus_src/objects/"[0-9a-f][0-9a-f] "$TMP/corrupt/objects/"
# git writes loose objects read-only (0444), so the swap below cannot
# overwrite one without this. copy_corpus does the same thing for the sibling
# copies; the self corpus needs it too.
chmod -R u+rw "$TMP/corrupt"
victim=$("$GITOBJ" ls "$TMP/corrupt/objects" 2>/dev/null |
	awk '$2=="blob"{print $1; exit}')
assert "and found a blob in it to be the victim" test -n "$victim"
printf 'tampered\n' > "$TMP/t.in"
# (A `"$GITOBJ" hash blob` on this file used to sit here with its output sent
# to /dev/null and its status ignored. git writes the object on the next line
# and names it on the one after, so nothing used gitobj's answer.)
$SG hash-object -w "$TMP/t.in" >/dev/null
nb=$($SG hash-object "$TMP/t.in")
cp "$SCRATCH/.git/objects/${nb:0:2}/${nb:2}" \
	"$TMP/corrupt/objects/${victim:0:2}/${victim:2}"
# The swap has to have actually changed the file, or the refutation below is
# refuting nothing.
assert "the swap really replaced the victim's bytes" \
	test "$(cd "$TMP/corrupt/objects" && cat "${victim:0:2}/${victim:2}" | cksum)" \
	!= "$(cd "$TMP/corpus/$corpus_src/objects" && cat "${victim:0:2}/${victim:2}" | cksum)"
refute "verify catches a loose object whose content was swapped" \
	"$GITOBJ" verify "$TMP/corrupt/objects"
assert "and says which one" sh -c \
	"'$GITOBJ' verify '$TMP/corrupt/objects' | grep -q '^MISMATCH $victim '"

# =====================================================================
# 4. trees: all five modes, and names git has to escape
# =====================================================================
# The corpora only contain 100644 and 40000, so the other three modes have to
# be built. git writes the tree, we read it: one tree carrying a regular
# file, an executable, a symlink, a subdirectory and a gitlink.
W=$TMP/work
mkdir -p "$W"
TG="$GIT -C $W"
$TG init -q
$TG config user.name PLACEHOLDER
$TG config user.email placeholder@invalid
printf 'plain\n' > "$W/plain.txt"
printf '#!/bin/sh\necho hi\n' > "$W/run.sh"
chmod 755 "$W/run.sh"
ln -s plain.txt "$W/link"
mkdir -p "$W/sub"
printf 'nested\n' > "$W/sub/deep.txt"
# Names that are awkward on purpose: a space, non-ASCII UTF-8, and the pair
# that settles the sort rule -- "a.c" against the directory "a".
printf 'spaced\n' > "$W/sp ace.txt"
printf 'unicode\n' > "$W/naïve.txt"
# Names that force git's C-style quoting in `cat-file -p`, which is the part
# of the tree pretty-printer the oracle caught us getting wrong: a quote, a
# backslash, a bell, a DEL and a high byte all escape differently.
printf 'q\n' > "$W/$(printf 'ta"b\\x')"
printf 'q\n' > "$W/$(printf 'bell\007x')"
printf 'q\n' > "$W/$(printf 'del\177x')"
printf 'q\n' > "$W/$(printf 'tab\tx')"
printf 'dotc\n' > "$W/a.c"
mkdir -p "$W/a"
printf 'in a dir\n' > "$W/a/inner"
$TG add -A
# A gitlink: mode 160000 pointing at a commit that is not in this repository.
# update-index --cacheinfo is the only way to make one without a submodule.
$TG update-index --add --cacheinfo \
	160000,0123456789abcdef0123456789abcdef01234567,gitlink
TREE=$($TG write-tree)
TOD=$W/.git/objects

# Every tree reachable from it, plus the root, pretty-printed both ways.
ntree=0
for t in $($TG cat-file --batch-all-objects --batch-check |
		awk '$2=="tree"{print $1}'); do
	ntree=$((ntree+1))
	"$GITOBJ" cat "$TOD" "$t" > "$TMP/ours"
	$TG cat-file -p "$t" > "$TMP/theirs"
	assert "tree -p $t" cmp -s "$TMP/ours" "$TMP/theirs"
	"$GITOBJ" raw "$TOD" "$t" > "$TMP/ours"
	$TG cat-file tree "$t" > "$TMP/theirs"
	assert "tree raw $t" cmp -s "$TMP/ours" "$TMP/theirs"
done
[ "$ntree" -ge 3 ] && ok || no "only $ntree trees in the mode fixture"

# The modes are asserted individually, because "cmp of two identical
# pretty-prints" would also pass if git and gitobj both printed nothing.
for m in 100644 100755 120000 040000 160000; do
	assert "mode $m appears in our listing" sh -c \
		"'$GITOBJ' cat '$TOD' '$TREE' | grep -q '^$m '"
done
eq "gitlink is printed as a commit" \
	"$("$GITOBJ" cat "$TOD" "$TREE" | awk '$1=="160000"{print $2}')" commit
eq "symlink is printed as a blob" \
	"$("$GITOBJ" cat "$TOD" "$TREE" | awk '$1=="120000"{print $2}')" blob
# 40000 is stored without its leading zero and printed with it. Both halves
# are checked, because getting one right and the other wrong is the bug.
# python rather than grep: the raw tree is binary with no line structure, so
# an anchored grep can only ever see the first entry, and the directory
# entry is not first -- git sorts "a" as "a/", which puts it after "a.c".
"$GITOBJ" raw "$TOD" "$TREE" > "$TMP/rawtree"
assert "40000 is stored without a leading zero" python3 -c \
	'import sys;sys.exit(0 if b"40000 a\x00" in open(sys.argv[1],"rb").read() else 1)' \
	"$TMP/rawtree"
refute "and 040000 is NOT what is stored" python3 -c \
	'import sys;sys.exit(0 if b"040000 a\x00" in open(sys.argv[1],"rb").read() else 1)' \
	"$TMP/rawtree"
assert "040000 is printed with one" sh -c \
	"'$GITOBJ' cat '$TOD' '$TREE' | grep -q '^040000 tree'"

# Malformed trees. Each is a valid object -- its name really is its own hash,
# because git computed it -- that is not a valid tree, so these exercise the
# parser and not the hash. The fixtures go through FILES, not command
# substitution: $() silently drops NUL bytes, and a tree without NULs is not
# the fixture any of these meant to build.
# python builds the bytes, not printf: bash printf's \0nnn octal escape runs
# into the digits that follow it, so '\00012345...' is not NUL-then-"12345"
# and the first version of these fixtures was 31 bytes where it meant 30.
mkbad() {
	python3 -c 'import sys;sys.stdout.buffer.write(eval(sys.argv[1]))' "$1" \
		> "$TMP/badtree"
	$SG hash-object -t tree -w --literally "$TMP/badtree"
}
S20='b"12345678901234567890"'
b=$(mkbad "b'40000 nonul'")
refute "tree entry with no NUL" "$GITOBJ" cat "$OD2" "$b"
b=$(mkbad "b'100644 short\0tooshort'")
refute "tree entry with a truncated object name" "$GITOBJ" cat "$OD2" "$b"
b=$(mkbad "b'nomode name\0'+$S20")
refute "tree entry with a non-octal mode" "$GITOBJ" cat "$OD2" "$b"
b=$(mkbad "b'100644 \0'+$S20")
refute "tree entry with an empty name" "$GITOBJ" cat "$OD2" "$b"
b=$(mkbad "b'100644 a/b\0'+$S20")
refute "tree entry name containing a slash" "$GITOBJ" cat "$OD2" "$b"
b=$(mkbad "b'1234567 name\0'+$S20")
refute "tree entry mode of more than six digits" "$GITOBJ" cat "$OD2" "$b"
b=$(mkbad "b'100644name\0'+$S20")
refute "tree entry mode with no space after it" "$GITOBJ" cat "$OD2" "$b"
# ... and the same shape as a VALID tree must still parse, so the refusals
# above are failing for their own reason rather than because mkbad is broken.
b=$(mkbad "b'100644 ok\0'+$S20")
assert "mkbad can build a tree that parses" "$GITOBJ" cat "$OD2" "$b"
eq "and git agrees it is a tree" "$($SG cat-file -t "$b")" tree

# =====================================================================
# 5. commits and tags: headers, folding, and a byte-exact message
# =====================================================================
# Real commits first: a root commit with no parent, then a merge with two.
# git log --format= is the oracle for the fields; for the message bytes the
# oracle is git cat-file itself, split in python, because %B is formatted
# output and this has to be byte-exact.
$TG add -A >/dev/null
$TG commit -q -m "root commit"
ROOT=$($TG rev-parse HEAD)
$TG checkout -q -b side
printf 'side\n' > "$W/side.txt"
$TG add side.txt >/dev/null && $TG commit -q -m "on the side"
$TG checkout -q -
printf 'main\n' > "$W/main.txt"
$TG add main.txt >/dev/null && $TG commit -q -m "on main"
$TG merge -q --no-ff -m "a merge with two parents" side
MERGE=$($TG rev-parse HEAD)

# A forged commit carrying everything a real one here cannot: three parents,
# an encoding header, a folded gpgsig whose armor contains a blank line
# (stored as a line of exactly one space -- the detail that keeps the "LF LF"
# ending the header block unambiguous), CRLF inside the message, and trailing
# whitespace on a message line. git signs nothing here, so this is built byte
# by byte and handed to git hash-object --literally; git then reads it back,
# which is the whole point.
# The three parents and the tree are REAL objects in this repository, because
# git log refuses to print even %T for a commit whose parents it cannot read
# ("Failed to traverse parents"), and losing the git-side oracle to make the
# fixture tidier would be the wrong trade.
P1=$ROOT
P2=$($TG rev-parse side)
P3=$($TG rev-parse HEAD)
FT=$($TG rev-parse 'HEAD^{tree}')
python3 - "$TMP/forged" "$P1" "$P2" "$P3" "$FT" <<'PYEOF2'
import sys
sig = ("-----BEGIN PGP SIGNATURE-----\n"
       "\n"                       # the armor blank line
       "iQEzBAABCgAdFiEE\n"
       "=abcd\n"
       "-----END PGP SIGNATURE-----")
folded = "\n".join(" " + l if i else l for i, l in enumerate(sig.split("\n")))
p1, p2, p3, ft = sys.argv[2:6]
body = ("tree " + ft + "\n"
        "parent " + p1 + "\n"
        "parent " + p2 + "\n"
        "parent " + p3 + "\n"
        "author A U Thor <author@example.com> 1700000000 +0100\n"
        "committer C O Mitter <committer@example.com> 1700000001 -0730\n"
        "encoding ISO-8859-1\n"
        "gpgsig " + folded + "\n"
        "\n"
        "subject with trailing space   \r\n"
        "\r\n"
        "a CRLF body line\r\n"
        "and a line ending in a tab\t\n"
        "\n\n")
open(sys.argv[1], "wb").write(body.encode("latin-1"))
PYEOF2
FORGED=$($TG hash-object -t commit -w --literally "$TMP/forged")
eq "git accepts the forged commit as a commit" "$($TG cat-file -t "$FORGED")" commit
# It must be byte-identical going in and coming out, or the fixture is lying
# about what is being parsed.
$TG cat-file commit "$FORGED" > "$TMP/theirs"
assert "the forged commit round-trips through git byte for byte" \
	cmp -s "$TMP/forged" "$TMP/theirs"

# A tag object, real, plus one forged with a folded signature.
$TG tag -a -m "an annotated tag" v1 >/dev/null
TAGOBJ=$($TG rev-parse v1)

# --- the oracle loop -------------------------------------------------
# (objdir, sha, git-dir) triples: real root, real merge, real tag, forged.
hdr_check() { # <label> <objdir> <sha> <key> <expected>
	got=$("$GITOBJ" hdr "$2" "$3" "$4" 2>/dev/null)
	eq "$1 hdr $4" "$got" "$5"
}
for pair in "$ROOT:$W/.git" "$MERGE:$W/.git"; do
	sha=${pair%%:*}; gd=${pair#*:}
	hdr_check "$sha" "$gd/objects" "$sha" tree \
		"$($GIT --git-dir="$gd" log -1 --format=%T "$sha")"
	# %P is space-separated; we print one parent per line.
	hdr_check "$sha" "$gd/objects" "$sha" parent \
		"$($GIT --git-dir="$gd" log -1 --format=%P "$sha" | tr ' ' '\n')"
	hdr_check "$sha" "$gd/objects" "$sha" author \
		"$($GIT --git-dir="$gd" log -1 --format='%an <%ae> %ad' --date=raw "$sha")"
	hdr_check "$sha" "$gd/objects" "$sha" committer \
		"$($GIT --git-dir="$gd" log -1 --format='%cn <%ce> %cd' --date=raw "$sha")"
done
# A root commit has no parent header at all, and that is an exit-1 answer
# rather than an empty-string answer.
refute "a root commit has no parent header" \
	"$GITOBJ" hdr "$W/.git/objects" "$ROOT" parent
eq "a merge has two parents" \
	"$("$GITOBJ" hdr "$W/.git/objects" "$MERGE" parent | wc -l)" 2

# The forged commit, against git's own reading of it.
FOD=$W/.git/objects
eq "forged: three parents" "$("$GITOBJ" hdr "$FOD" "$FORGED" parent | wc -l)" 3
hdr_check forged "$FOD" "$FORGED" parent \
	"$($TG log -1 --format=%P "$FORGED" | tr ' ' '\n')"
hdr_check forged "$FOD" "$FORGED" tree "$($TG log -1 --format=%T "$FORGED")"
hdr_check forged "$FOD" "$FORGED" encoding "$($TG log -1 --format=%e "$FORGED")"
hdr_check forged "$FOD" "$FORGED" author \
	"$($TG log -1 --format='%an <%ae> %ad' --date=raw "$FORGED")"
# The folded gpgsig, unfolded. git prints the same block with %GG only for a
# signature it can verify, so the oracle here is git's own cat-file bytes
# with the fold undone in python -- still git's bytes, not ours.
$TG cat-file commit "$FORGED" | python3 -c '
import sys
raw = sys.stdin.buffer.read()
hdrs = raw.split(b"\n\n", 1)[0]
out, want = [], False
for line in hdrs.split(b"\n"):
    if line.startswith(b" "):
        if want: out.append(line[1:])
        continue
    k, _, v = line.partition(b" ")
    want = k == b"gpgsig"
    if want: out.append(v)
sys.stdout.buffer.write(b"\n".join(out) + b"\n")
' > "$TMP/theirs"
"$GITOBJ" hdr "$FOD" "$FORGED" gpgsig > "$TMP/ours"
assert "forged: the folded gpgsig unfolds to git's bytes" cmp -s "$TMP/ours" "$TMP/theirs"
assert "forged: the gpgsig armor blank line survives as an empty line" \
	grep -qx '' "$TMP/ours"

# The message, byte for byte, for every commit and tag in play. This is what
# makes CRLF and trailing whitespace a tested claim rather than a hope.
msgcheck() { # <label> <objdir> <sha> <git-dir>
	$GIT --git-dir="$4" cat-file "$($GIT --git-dir="$4" cat-file -t "$3")" "$3" |
		python3 -c 'import sys;b=sys.stdin.buffer.read();sys.stdout.buffer.write(b.split(b"\n\n",1)[1] if b"\n\n" in b else b"")' \
		> "$TMP/theirs"
	"$GITOBJ" msg "$2" "$3" > "$TMP/ours"
	assert "$1 message is byte-exact" cmp -s "$TMP/ours" "$TMP/theirs"
}
msgcheck root "$W/.git/objects" "$ROOT" "$W/.git"
msgcheck merge "$W/.git/objects" "$MERGE" "$W/.git"
msgcheck tag "$W/.git/objects" "$TAGOBJ" "$W/.git"
msgcheck forged "$FOD" "$FORGED" "$W/.git"
# And explicitly: the CR bytes and the trailing space are still there.
"$GITOBJ" msg "$FOD" "$FORGED" > "$TMP/ours"
# python, not grep: the trailing space sits BEFORE the CR, so a "space at
# end of line" grep does not see it, and the first version of this check
# passed only because it was looking at the wrong byte.
assert "forged message keeps trailing space, CR and tab exactly" python3 -c '
import sys
b = open(sys.argv[1], "rb").read()
assert b.startswith(b"subject with trailing space   \r\n"), b[:40]
assert b"\r\n" in b and b"a CRLF body line\r\n" in b
assert b"and a line ending in a tab\t\n" in b
assert b.endswith(b"\n\n")
' "$TMP/ours"
eq "forged message length" "$(wc -c < "$TMP/ours")" \
	"$(python3 -c 'import sys;b=open(sys.argv[1],"rb").read();print(len(b.split(b"\n\n",1)[1]))' "$TMP/forged")"

# The tag headers, against git.
hdr_check tag "$W/.git/objects" "$TAGOBJ" object "$($TG rev-parse v1^{commit})"
hdr_check tag "$W/.git/objects" "$TAGOBJ" type commit
hdr_check tag "$W/.git/objects" "$TAGOBJ" tag v1

# Every commit and tag in the small corpora, all four common headers.
for r in $HAVE_SMALL; do
	G=$TMP/corpus/$r
	for sha in $(loose_shas "$G"); do
		gt=$($GIT --git-dir="$G" cat-file -t "$sha")
		[ "$gt" = commit ] || continue
		hdr_check "$r/$sha" "$G/objects" "$sha" tree \
			"$($GIT --git-dir="$G" log -1 --format=%T "$sha")"
		hdr_check "$r/$sha" "$G/objects" "$sha" committer \
			"$($GIT --git-dir="$G" log -1 --format='%cn <%ce> %cd' --date=raw "$sha")"
		msgcheck "$r/$sha" "$G/objects" "$sha" "$G"
	done
done

BOD=$SCRATCH/.git/objects
refute "msg refuses a blob" "$GITOBJ" msg "$BOD" "$hb"
refute "hdr refuses a blob" "$GITOBJ" hdr "$BOD" "$hb" tree

# =====================================================================
# 6. writing loose objects: git reads what we write
# =====================================================================
# The other direction of the oracle, and until now the missing one: every
# check above reads what git wrote. Here git is the reader. The target is a
# bare repository git created and nothing else has touched, so an object that
# can be read out of it is an object gitobj put there. The hazard with a
# write test is that it passes by finding the thing already present.
WREPO=$TMP/written
$GIT init -q --bare "$WREPO"
WOD=$WREPO/objects
WG="$GIT --git-dir=$WREPO"

# Pass 1: re-store every loose object of the mode/commit/tag fixture, which
# holds all four types with content git itself produced. The payload comes
# out of `git cat-file <type>`, goes in through `gitobj write`, and the name
# gitobj prints must be the name git gave it: git chose that filename, and
# we recompute the hash over bytes we re-serialised.
nwritten=0
for sha in $(loose_shas "$W/.git"); do
	gt=$($TG cat-file -t "$sha")
	$TG cat-file "$gt" "$sha" > "$TMP/payload"
	got=$("$GITOBJ" write "$WOD" "$gt" "$TMP/payload")
	eq "write $gt $sha keeps its name" "$got" "$sha"
	assert "write $sha put a file at the fan-out path" \
		test -f "$WOD/${sha:0:2}/${sha:2}"
	# git reading our file, pretty-printed, against git reading its own.
	$WG cat-file -p "$sha" > "$TMP/ours" 2>/dev/null
	$TG cat-file -p "$sha" > "$TMP/theirs"
	assert "git cat-file -p agrees on our $gt $sha" cmp -s "$TMP/ours" "$TMP/theirs"
	nwritten=$((nwritten+1))
done
[ "$nwritten" -ge 15 ] && ok || no "only $nwritten objects re-stored"
# All four types, or the pass above proved one of them.
eq "the re-stored objects cover all four types" \
	"$($WG cat-file --batch-all-objects --batch-check | awk '{print $2}' |
		sort -u | tr '\n' ' ')" "blob commit tag tree "
# And git holds exactly what we wrote, so the fsck below has something to
# look at: a clean fsck of an empty repository is also clean.
eq "git sees exactly the objects we wrote" \
	"$($WG cat-file --batch-all-objects --batch-check | wc -l)" "$nwritten"

# `git fsck --strict` is the strongest reader there is: it inflates every
# object, re-hashes it, and parses trees and commits. Everything here is
# unreachable (the repository has no refs), so "dangling" is expected and
# must not be read as a failure; an error is anything else.
$WG fsck --strict > "$TMP/fsck.out" 2>&1
eq "git fsck --strict exits 0 over our objects" "$?" 0
assert "git fsck --strict reports no error over our objects" \
	sh -c "! grep -Eiv '^(notice|dangling)' '$TMP/fsck.out' | grep -q ."

# Pass 2: sizes around the stored-block boundary. LEN is 16 bits, so a block
# holds 65535 bytes and the plaintext is the payload plus an 11- or 12-byte
# header. The sizes below put the block edge on either side of the header,
# exactly on it, and twice over.
for n in 0 1 2 65522 65523 65524 65525 65526 131057 131058 131059 200000; do
	head -c "$n" /dev/urandom > "$TMP/wblob"
	got=$("$GITOBJ" write "$WOD" blob "$TMP/wblob")
	eq "write blob of $n bytes names it as git does" "$got" \
		"$($SG hash-object -t blob "$TMP/wblob")"
	$WG cat-file blob "$got" > "$TMP/ours" 2>/dev/null
	assert "git inflates our $n-byte blob byte for byte" cmp -s "$TMP/ours" "$TMP/wblob"
	nwritten=$((nwritten+1))
done

# Payloads chosen for what they are rather than for their length. A round
# trip over an empty blob exercises almost nothing and would be a poor
# single case; a blob that is mostly NUL bytes catches anything in the
# writer that treats the payload as a C string; and a large repetitive one
# is the case a real deflate collapses to nothing, which is where our stored
# blocks differ most from what git would have written. git has to inflate
# all three and agree on the bytes, the type and the size.
python3 -c 'open("'"$TMP"'/pay.nul","wb").write(b"\x00"*4096+b"a\x00b\x00"*256)'
python3 -c 'open("'"$TMP"'/pay.squish","wb").write((b"the same line over and over\n")*12000)'
# The empty blob by its own name. It is the same object as the 0-byte case
# in the loop above, so it is NOT counted again below: nwritten is checked
# against what git finds in the store, and counting one object twice there
# cost a red run to notice.
eq "the empty blob is e69de29" "$("$GITOBJ" write "$WOD" blob /dev/null)" \
	"$($SG hash-object -t blob /dev/null)"
eq "git reads our empty blob as a blob of size 0" \
	"$($WG cat-file -s "$($SG hash-object -t blob /dev/null)")" 0

for f in nul squish; do
	got=$("$GITOBJ" write "$WOD" blob "$TMP/pay.$f")
	eq "write blob $f names it as git does" "$got" \
		"$($SG hash-object -t blob "$TMP/pay.$f")"
	$WG cat-file blob "$got" > "$TMP/ours" 2>/dev/null
	assert "git inflates our $f blob byte for byte" cmp -s "$TMP/ours" "$TMP/pay.$f"
	eq "git calls our $f blob a blob" "$($WG cat-file -t "$got")" blob
	eq "git agrees on the size of our $f blob" "$($WG cat-file -s "$got")" \
		"$(wc -c < "$TMP/pay.$f")"
	nwritten=$((nwritten+1))
done

# What the compression comes to. The encoder is vendored from ../inflate,
# which measures it against `gzip -6` over seven corpora; what is checked
# here is that the choice between the three block types is being made, since
# a cost model that always picked one of them would pass every assertion
# above. Three payloads, one for each answer.
python3 -c 'open("'"$TMP"'/pay.zero","wb").write(b"\x00"*100000)'
cp "$TMP/fix/rand" "$TMP/pay.rand"
# Not a copy of pay.squish: that object is already in the store, and
# counting one object twice against what git finds there is the mistake the
# comment above records. A different line, so it is a different blob.
python3 -c 'open("'"$TMP"'/pay.text","wb").write((b"a line that repeats, and compresses accordingly\n")*7000)'
csize() { wc -c < "$WOD/${1:0:2}/${1:2}" | tr -d ' '; }
for f in zero text rand; do
	got=$("$GITOBJ" write "$WOD" blob "$TMP/pay.$f")
	eq "write blob $f names it as git does" "$got" \
		"$($SG hash-object -t blob "$TMP/pay.$f")"
	$WG cat-file blob "$got" > "$TMP/ours" 2>/dev/null
	assert "git inflates our $f blob byte for byte" cmp -s "$TMP/ours" "$TMP/pay.$f"
	eval "sz_$f=\$(csize $got)"
	eval "in_$f=\$(wc -c < \"\$TMP/pay.\$f\")"
	nwritten=$((nwritten+1))
done
# 100KB of zeros collapses to almost nothing, which only a coded block can
# do: a stored block of it is 100KB plus framing.
[ "$sz_zero" -lt 2000 ] && ok ||
	no "100000 zero bytes came to $sz_zero, so no coded block was chosen"
# Repetitive text, where git's own loose objects sit around a third.
[ "$((sz_text * 100 / in_text))" -lt 50 ] && ok ||
	no "the repetitive payload came to $sz_text of $in_text, over half"
# urandom cannot be compressed, so the cost model has to fall back to stored
# blocks: five bytes of block header per 65535 of payload, plus six of
# framing. Anything much over that is a coded block being chosen when it
# should not have been, and anything under it is impossible.
[ "$sz_rand" -ge "$in_rand" ] && ok ||
	no "100000 random bytes came to $sz_rand, under the $in_rand that went in"
[ "$sz_rand" -le "$((in_rand + 100))" ] && ok ||
	no "100000 random bytes came to $sz_rand, so stored blocks were not chosen"
printf 'loose object sizes: %d zero bytes to %d, %d of repeated text to %d, %d random to %d\n' \
	"$in_zero" "$sz_zero" "$in_text" "$sz_text" "$in_rand" "$sz_rand"
# git's own, for the same content, reported rather than asserted: git's
# default for a loose object is compression level 1, so it is not a
# comparison either of us is trying to win.
gsz=$($SG hash-object -t blob -w "$TMP/pay.text" > /dev/null &&
	wc -c < "$OD2/$(
		g=$($SG hash-object -t blob "$TMP/pay.text"); echo "${g:0:2}/${g:2}")" | tr -d ' ')
printf 'the same repeated text: %d bytes here, %d from git at its own default\n' \
	"$sz_text" "$gsz"

# stdin, and writing the same content twice.
printf 'written from stdin\n' > "$TMP/wstdin"
got=$("$GITOBJ" write "$WOD" blob < "$TMP/wstdin")
eq "write reads stdin when given no file" "$got" \
	"$($SG hash-object -t blob "$TMP/wstdin")"
nwritten=$((nwritten+1))
sz1=$(wc -c < "$WOD/${got:0:2}/${got:2}")
again=$("$GITOBJ" write "$WOD" blob "$TMP/wstdin")
eq "writing the same object twice names it the same" "$again" "$got"
eq "and leaves the stored file alone" \
	"$(wc -c < "$WOD/${got:0:2}/${got:2}")" "$sz1"
$WG cat-file blob "$got" > "$TMP/ours" 2>/dev/null
assert "git still reads it after the second write" cmp -s "$TMP/ours" "$TMP/wstdin"

# Our own reader over our own writer, and the hard invariant over the lot.
# `verify` recomputes every name from the inflated bytes, so this is the
# whole write path checked against the names git agreed with above.
out=$("$GITOBJ" verify "$WOD" 2>/dev/null)
eq "verify over everything we wrote exits 0" "$?" 0
case $out in *", 0 mismatched") ok ;; *) no "verify of our own objects: $out" ;; esac
eq "verify counted every object we wrote" "${out##*$'\n'}" "$nwritten objects, 0 mismatched"
$WG cat-file --batch-all-objects --batch-check | sort > "$TMP/theirs"
"$GITOBJ" ls "$WOD" > "$TMP/ours" 2>/dev/null
assert "ls of our own store matches git batch-check" cmp -s "$TMP/ours" "$TMP/theirs"

refute "write rejects an unknown type" \
	"$GITOBJ" write "$WOD" frobnicate "$TMP/wstdin"
refute "write refuses an object directory that does not exist" \
	"$GITOBJ" write "$TMP/no/such/objects" blob "$TMP/wstdin"
refute "write refuses a file it cannot read" \
	"$GITOBJ" write "$WOD" blob "$TMP/no/such/file"

# =====================================================================
# 7. mktree: git's sort order, and git reads the tree we built
# =====================================================================
# Section 6 proved git can read bytes we re-serialised from an object git
# had already built, so the entry order came from git. Here it comes from
# us, and the sort is the one rule in this format an implementation can get
# wrong while still producing something that parses: entries compare as if
# a directory name carried a trailing slash, so "a" sorts between "a.c" and
# "a0" rather than before both. `git fsck --strict` calls the wrong order
# treeNotSorted, which makes fsck an oracle for the ordering and not only
# for the framing.
MREPO=$TMP/mktree
$GIT init -q --bare "$MREPO"
MOD=$MREPO/objects
MG="$GIT --git-dir=$MREPO"

# Everything in the mode/commit/tag fixture EXCEPT its trees. The children
# have to be present for fsck to have anything to check the links against,
# and withholding the trees means no tree in this repository can have got
# there any way but mktree -- a write test that passes by finding the object
# already stored is the hazard, and for trees it is excluded by
# construction here.
for sha in $(loose_shas "$W/.git"); do
	gt=$($TG cat-file -t "$sha")
	[ "$gt" = tree ] && continue
	$TG cat-file "$gt" "$sha" > "$TMP/payload"
	"$GITOBJ" write "$MOD" "$gt" "$TMP/payload" > /dev/null
done
eq "the mktree target starts with no trees in it" \
	"$($MG cat-file --batch-all-objects --batch-check | awk '$2=="tree"' | wc -l)" 0

# Every tree in the fixture, rebuilt from its own listing in three input
# orders. `git ls-tree` prints exactly git-mktree's input format, C-quoted
# names and all, so the listing travels unaltered; reversed and
# name-sorted are the two orders that a sorter doing nothing would leave
# wrong. git mktree is fed the same bytes and must name the same object.
nmk=0
for t in $($TG cat-file --batch-all-objects --batch-check |
		awk '$2=="tree"{print $1}'); do
	$TG ls-tree "$t" > "$TMP/entries"
	tac "$TMP/entries" > "$TMP/entries.rev"
	LC_ALL=C sort -t"$(printf '\t')" -k2 "$TMP/entries" > "$TMP/entries.naive"
	for ord in entries entries.rev entries.naive; do
		got=$("$GITOBJ" mktree "$MOD" < "$TMP/$ord")
		eq "mktree $t from $ord names the tree git named" "$got" "$t"
		eq "git mktree agrees on $t from $ord" "$($TG mktree < "$TMP/$ord")" "$got"
	done
	$MG cat-file -p "$t" > "$TMP/ours" 2>/dev/null
	$TG cat-file -p "$t" > "$TMP/theirs"
	assert "git cat-file -p reads the $t we built" cmp -s "$TMP/ours" "$TMP/theirs"
	eq "git calls the $t we built a tree" "$($MG cat-file -t "$t")" tree
	eq "git agrees on the size of the $t we built" \
		"$($MG cat-file -s "$t")" "$($TG cat-file -s "$t")"
	nmk=$((nmk+1))
done
[ "$nmk" -ge 3 ] && ok || no "only $nmk trees rebuilt by mktree"
# Set equality, not a count: a tree we built under the wrong name would
# leave the right one missing and the wrong one present.
eq "mktree built every tree the fixture has and no others" \
	"$($MG cat-file --batch-all-objects --batch-check |
		awk '$2=="tree"{print $1}' | sort | tr '\n' ' ')" \
	"$($TG cat-file --batch-all-objects --batch-check |
		awk '$2=="tree"{print $1}' | sort | tr '\n' ' ')"

# A tree built from scratch whose names straddle the slash. '-' is 0x2d,
# '.' is 0x2e, '/' is 0x2f and '0' is 0x30, so the directory "a" belongs
# after "a-b" and "a.c" and before "a0", where plain byte order over the
# stored names would put it first. The entries are fed in exactly that
# wrong order. The blobs exist in both repositories because git mktree
# verifies that an entry's object is present before it will write a tree.
sb=$($SG hash-object -t blob -w "$TMP/fix/hello")
"$GITOBJ" write "$MOD" blob "$TMP/fix/hello" > /dev/null
printf '100644 blob %s\tinner\n' "$sb" > "$TMP/subin"
sub=$("$GITOBJ" mktree "$MOD" < "$TMP/subin")
eq "mktree and git mktree agree on the subtree" "$sub" "$($SG mktree < "$TMP/subin")"
printf '040000 tree %s\ta\n100644 blob %s\ta-b\n100644 blob %s\ta.c\n100644 blob %s\ta0\n100644 blob %s\taa\n' \
	"$sub" "$sb" "$sb" "$sb" "$sb" > "$TMP/sortin"
sorted=$("$GITOBJ" mktree "$MOD" < "$TMP/sortin")
eq "mktree sorts the slash cases as git mktree does" "$sorted" \
	"$($SG mktree < "$TMP/sortin")"
eq "the directory lands between a.c and a0" \
	"$("$GITOBJ" cat "$MOD" "$sorted" | cut -f2 | tr '\n' ' ')" "a-b a.c a a0 aa "
# And the fixture discriminates: sorting the names as plain bytes is a
# DIFFERENT object, computed here without git and without gitobj, so the
# two checks above are not both satisfiable by a sorter that ignores the
# rule. Without this the whole section could pass against strcmp order.
naive=$(python3 -c '
import hashlib, sys
sub, sb = sys.argv[1], sys.argv[2]
ents = [(b"40000", b"a", sub), (b"100644", b"a-b", sb), (b"100644", b"a.c", sb),
        (b"100644", b"a0", sb), (b"100644", b"aa", sb)]
ents.sort(key=lambda e: e[1])
body = b"".join(m + b" " + n + b"\x00" + bytes.fromhex(i) for m, n, i in ents)
print(hashlib.sha1(b"tree %d\x00" % len(body) + body).hexdigest())
' "$sub" "$sb")
assert "plain byte order over the names is a different tree" \
	test "$naive" != "$sorted"
refute "and git does not have that tree" $SG cat-file -e "$naive"

# The empty tree. git's own 4b825dc is not a special case in the code, it
# is what hashing zero entries produces, and it is the one tree whose name
# can be written down.
EMPTYTREE=4b825dc642cb6eb9a060e54bf8d69288fbee4904
eq "mktree of no entries is the empty tree" \
	"$("$GITOBJ" mktree "$MOD" < /dev/null)" "$EMPTYTREE"
eq "git mktree says the same" "$($SG mktree < /dev/null)" "$EMPTYTREE"
assert "the empty tree really was stored" \
	test -f "$MOD/${EMPTYTREE:0:2}/${EMPTYTREE:2}"
eq "git reads our empty tree as a tree of size 0" \
	"$($MG cat-file -s "$EMPTYTREE")" 0
eq "git calls our empty tree a tree" "$($MG cat-file -t "$EMPTYTREE")" tree

# Our pretty-printer is this parser's inverse: cat a tree and feed it
# straight back. This one is us against ourselves, which is why it comes
# after the oracle and not instead of it -- but it is the only check that
# runs a name with a diaeresis, a bell, a DEL, a tab, a quote and a
# backslash back through the unquoter.
eq "cat | mktree round-trips the fixture root tree" \
	"$("$GITOBJ" cat "$MOD" "$TREE" | "$GITOBJ" mktree "$MOD")" "$TREE"

# fsck over the lot. Everything is unreachable, so dangling is expected;
# treeNotSorted, badFilemode and a broken link are not.
$MG fsck --strict > "$TMP/fsck.out" 2>&1
eq "git fsck --strict exits 0 over the trees we built" "$?" 0
assert "git fsck --strict reports no error over the trees we built" \
	sh -c "! grep -Eiv '^(notice|dangling)' '$TMP/fsck.out' | grep -q ."
assert "fsck had trees to look at" \
	test "$($MG cat-file --batch-all-objects --batch-check |
		awk '$2=="tree"' | wc -l)" -ge 4

# Refusals git agrees with: each of these makes git mktree die too, so the
# refusal is not a rule we invented.
mk_ref() { # NAME FORMAT [printf args...]
	local n=$1 f=$2; shift 2
	printf "$f" "$@" > "$TMP/mkin"
	refute "mktree refuses $n" sh -c "'$GITOBJ' mktree '$MOD' < '$TMP/mkin'"
	assert "git mktree refuses $n too" sh -c "! $SG mktree < '$TMP/mkin'"
}
mk_ref "an entry with no tab" '100644 blob %s x\n' "$sb"
mk_ref "a 38-character object name" '100644 blob %.38s\tx\n' "$sb"
mk_ref "a non-hex object name" '100644 blob %s\tx\n' \
	zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz
mk_ref "a type that disagrees with the mode" '100644 tree %s\tx\n' "$sb"
mk_ref "a quoted name with no closing quote" '100644 blob %s\t"abc\n' "$sb"
mk_ref "an invalid escape in a quoted name" '100644 blob %s\t"a\\zc"\n' "$sb"
mk_ref "a name containing a slash" '100644 blob %s\ta/b\n' "$sb"

# Refusals git mktree does NOT make, where the authority is fsck instead:
# git writes the object and then `git fsck --strict` complains about it, so
# accepting these would mean producing a tree git itself calls broken.
nstrict=0
mk_strict() { # NAME FORMAT [printf args...]
	local n=$1 f=$2; shift 2
	printf "$f" "$@" > "$TMP/mkin"
	refute "mktree refuses $n" sh -c "'$GITOBJ' mktree '$MOD' < '$TMP/mkin'"
	nstrict=$((nstrict+1))
	local R=$TMP/strict$nstrict
	$GIT init -q --bare "$R"
	$GIT --git-dir="$R" hash-object -t blob -w "$TMP/fix/hello" > /dev/null
	$GIT --git-dir="$R" mktree < "$TMP/mkin" > /dev/null 2>&1
	$GIT --git-dir="$R" fsck --strict > "$TMP/strict.out" 2>&1
	assert "git fsck --strict complains about $n" \
		sh -c "grep -Eiv '^(notice|dangling)' '$TMP/strict.out' | grep -q ."
}
mk_strict "a file mode git does not use" '100645 blob %s\tx\n' "$sb"
mk_strict "a zero-padded file mode" '000000 blob %s\tx\n' "$sb"
mk_strict "an empty entry name" '100644 blob %s\t\n' "$sb"

refute "mktree refuses an object directory that does not exist" \
	sh -c "'$GITOBJ' mktree '$TMP/no/such/objects' < '$TMP/sortin'"

# =====================================================================
# 8. the pack v2 index: fanout, names, CRCs, and both offset widths
# =====================================================================
# Nothing in a .idx is self-describing. The object count is the last fanout
# entry and the length of the 64-bit offset table is whatever is left over
# once everything else is accounted for, so a lie about any length is a lie
# about where every later field begins.
#
# Three oracles, none of which need a pack reader:
#
#   git show-index      offset, name and CRC for every object, and the only
#                       one that works on an index with no pack beside it,
#                       which is what makes a hand-built 64-bit offset
#                       table checkable at all.
#   git verify-pack     reads the index AND the pack, so it is the authority
#                       on whether an index we accept is one git accepts.
#   git index-pack      builds an index from the pack's own bytes, so the
#                       corpus index can be compared against one git wrote
#                       today from the same pack.
#
# `--object-format=sha1` is not decoration on show-index: outside a
# repository it has no config to read the hash algorithm from and segfaults,
# which looks exactly like a corrupt fixture.
cat > "$TMP/idxtool.py" <<'PYIDX'
# Reads, rebuilds and mutates a pack v2 index. The suite checks that a
# rebuild of git's own index is byte-identical to it, so a fixture built
# here differs from what git wrote only where it was asked to.
import hashlib, struct, sys

HDR = 1032  # magic, version, 256 fanout entries

def parse(b):
    assert b[:4] == b'\377tOc', 'not a v2 index'
    assert struct.unpack('>I', b[4:8])[0] == 2, 'not version 2'
    fan = list(struct.unpack('>256I', b[8:HDR]))
    n = fan[255]
    o = HDR
    names = [b[o + 20 * i:o + 20 * i + 20] for i in range(n)]; o += 20 * n
    crcs = list(struct.unpack('>%dI' % n, b[o:o + 4 * n])); o += 4 * n
    off = list(struct.unpack('>%dI' % n, b[o:o + 4 * n])); o += 4 * n
    rest = len(b) - 40 - o
    assert rest % 8 == 0, 'trailing bytes are not whole 64-bit offsets'
    big = list(struct.unpack('>%dQ' % (rest // 8), b[o:o + rest]))
    return dict(fan=fan, names=names, crcs=crcs, off=off, big=big,
                packsum=b[-40:-20])

def build(d, fan=None, sum_ok=True):
    n = len(d['names'])
    if fan is None:
        # Counted from the names, so a fixture that reorders names keeps a
        # fanout that agrees with them and the defect stays the one intended.
        c = [0] * 256
        for nm in d['names']:
            c[nm[0]] += 1
        fan, t = [], 0
        for i in range(256):
            t += c[i]
            fan.append(t)
    out = b'\377tOc' + struct.pack('>I', 2) + struct.pack('>256I', *fan)
    out += b''.join(d['names'])
    out += struct.pack('>%dI' % n, *d['crcs'])
    out += struct.pack('>%dI' % n, *d['off'])
    out += struct.pack('>%dQ' % len(d['big']), *d['big'])
    out += d['packsum']
    return out + (hashlib.sha1(out).digest() if sum_ok else bytes(20))

# Offsets that span the whole 64-bit range, including both sides of 2^31
# (where the escape begins), both sides of 2^32, and the top bit, which is
# where a reader holding an offset in a signed type goes negative. The first
# value is UNDER 2^31 and still reached through the table: git follows the
# indirection on the top bit alone, never on the magnitude.
BIGVALS = [(1 << 31) - 1, 1 << 31, (1 << 31) + 1, (1 << 32) - 1, 1 << 32,
           1 << 40, 1 << 48, (1 << 52) + 12345, 1 << 62, 1 << 63,
           (1 << 63) + 7, (1 << 64) - 1]

def resum(b):
    # Every fixture carries a CORRECT trailing checksum, so each one is a
    # single lie. Without this, a mutation of the raw bytes is two lies and
    # the checksum is what gets caught, which makes the check it was built
    # for impossible to tell apart from the checksum check.
    return b[:-20] + hashlib.sha1(b[:-20]).digest()

def mutate(kind, raw, d):
    n = len(d['names'])
    if kind == 'trunc':
        return resum(raw[:len(raw) // 2])
    if kind == 'magic':       # what a v1 index looks like: no magic at all
        return resum(bytes(4) + raw[4:])
    if kind == 'ver':
        return resum(raw[:4] + struct.pack('>I', 3) + raw[8:])
    if kind == 'partial8':    # four bytes where only multiples of eight fit
        return resum(raw[:-20] + bytes(4) + raw[-20:])
    if kind == 'idxsum':
        return build(d, sum_ok=False)
    if kind == 'fanback':
        # One entry below its predecessor, with the count intact. The bucket
        # chosen is an EMPTY one, which is where the walk over the names
        # cannot see the decrease: it skips a bucket whose end is behind
        # where it has already reached, and every later name still lands in
        # the bucket that claims it. Put the decrease next to a non-empty
        # bucket instead and the bucket check catches it, which is exactly
        # how this fixture was built first and why deleting the monotonic
        # check changed nothing.
        fan = list(d['fan'])
        k = next(i for i in range(1, 255) if fan[i] == fan[i - 1] and fan[i - 1] > 0)
        fan[k] = fan[k - 1] - 1
        return build(d, fan=fan)
    if kind == 'unsorted':    # two adjacent objects exchanged, data and all
        for key in ('names', 'crcs', 'off'):
            d[key][0], d[key][1] = d[key][1], d[key][0]
        return build(d)
    if kind == 'dupname':     # the same object name twice, in order
        d['names'][1] = d['names'][0]
        return build(d)
    if kind == 'fanbucket':
        # One bucket boundary moved up by one. Monotonic, the count is
        # unchanged, the names are still sorted, and the object at the new
        # boundary is claimed by a bucket its first byte does not belong to.
        fan = list(d['fan'])
        k = next(i for i in range(255) if fan[i] < fan[i + 1])
        fan[k] += 1
        return build(d, fan=fan)
    if kind == 'bigpast':     # indirection one entry past the table
        d['off'][0] = 0x80000000 | len(d['big'])
        return build(d)
    if kind == 'crcbit':
        d['crcs'][0] ^= 1
        return build(d)
    if kind == 'offpast':     # inside the 32-bit field, outside the pack
        d['off'][0] = 0x7ffffffe
        return build(d)
    if kind == 'offdup':      # two objects claiming one offset
        d['off'][1] = d['off'][0]
        return build(d)
    if kind == 'indirect':
        # Every offset but the first through the 64-bit table. Not every
        # offset: git's index size check allows at most n-1 large offsets,
        # since the first object in a pack is at offset 12 and cannot need
        # one, and it calls an index with n of them "wrong index v2 file
        # size". `bigtoomany` below is that index.
        d['big'] = list(d['off'][1:])
        d['off'] = [d['off'][0]] + [0x80000000 | i for i in range(n - 1)]
        return build(d)
    if kind == 'bigtoomany':  # one more large offset than git will allow
        d['big'] = list(d['off'])
        d['off'] = [0x80000000 | i for i in range(n)]
        return build(d)
    if kind == 'bigoff':      # offsets no real pack here could reach
        d['big'] = list(BIGVALS)
        d['off'] = [0x80000000 | i if i < len(BIGVALS) else 12 + i
                    for i in range(n)]
        return build(d)
    raise SystemExit('unknown mutation ' + kind)

kind, src, dst = sys.argv[1], sys.argv[2], sys.argv[3]
raw = open(src, 'rb').read()
d = parse(raw)
out = build(d) if kind == 'rebuild' else mutate(kind, raw, d)
open(dst, 'wb').write(out)
PYIDX

# The pack header's object count and the pack's own trailing checksum, which
# the index carries a copy of. Both are cross-checks between the two files
# rather than anything inside either one.
cat > "$TMP/packmut.py" <<'PYPACK'
import struct, sys
kind, src, dst = sys.argv[1], sys.argv[2], sys.argv[3]
b = open(src, 'rb').read()
if kind == 'count':
    b = b[:8] + struct.pack('>I', struct.unpack('>I', b[8:12])[0] + 1) + b[12:]
elif kind == 'sum':
    b = b[:-1] + bytes([b[-1] ^ 0xff])
else:
    raise SystemExit('unknown pack mutation ' + kind)
open(dst, 'wb').write(b)
PYPACK

# git creates packs and indexes read-only (0444), so copying one over a copy
# made a moment earlier fails with EACCES and the harness goes on to compare
# the file it did not write. Every copy below goes through this.
cpw() { rm -f "$2"; cp "$1" "$2"; chmod u+rw "$2"; }

# A pack of our own, so a clone with no siblings still has one. The self
# corpus is deliberately unpacked (section 2 compares `ls` over a whole
# repository, which only works with no pack), so the pack is built beside it
# rather than in it.
mkdir -p "$TMP/packs"
SELFREPO=$TMP/corpus/$(printf '%s\n' $HAVE_SELF | head -1)
$GIT --git-dir="$SELFREPO" cat-file --batch-all-objects --batch-check |
	awk '{print $1}' > "$TMP/packs/in"
NSELF=$(wc -l < "$TMP/packs/in" | tr -d ' ')
SELFPACK=$($GIT --git-dir="$SELFREPO" pack-objects --non-empty \
	"$TMP/packs/self" < "$TMP/packs/in")
SELFIDX="$TMP/packs/self-$SELFPACK.idx"
assert "a pack was built from the self corpus" test -f "$SELFIDX"
eq "and it holds every object of the self corpus" \
	"$($GIT show-index --object-format=sha1 < "$SELFIDX" | wc -l | tr -d ' ')" \
	"$NSELF"

# Every index in reach: ours first, then whichever siblings were copied.
IDXES="$SELFIDX"
for r in $HAVE_SMALL $HAVE_BIG; do
	for i in "$TMP/corpus/$r/objects/pack/"*.idx; do
		[ -f "$i" ] && IDXES="$IDXES $i"
	done
done

# Per object, not per index. A whole-file diff over a thousand objects says
# only that something somewhere disagreed; this names the object.
# via32_total and via64_total are the census: how many objects were read
# through each of the two offset encodings, summed over every index. A
# 64-bit offset test over a corpus with no large offsets passes while
# reading nothing, so these are counted here rather than assumed, and the
# accumulation lives inside this function so no caller can forget it.
via32_total=0
via64_total=0
idx_vs_showindex() { # <label> <idx>
	"$GITOBJ" idx "$2" > "$TMP/i.ours" 2> "$TMP/i.census"
	eq "$1: idx exits 0" "$?" 0
	$GIT show-index --object-format=sha1 < "$2" > "$TMP/i.theirs"
	eq "$1: same number of objects as show-index" \
		"$(wc -l < "$TMP/i.ours" | tr -d ' ')" "$(wc -l < "$TMP/i.theirs" | tr -d ' ')"
	local a b sha
	while IFS= read -r a <&3 && IFS= read -r b <&4; do
		sha=${b#* }; sha=${sha%% *}
		eq "$1 $sha" "$a" "$b"
	done 3< "$TMP/i.ours" 4< "$TMP/i.theirs"
	via32_total=$((via32_total + $(sed -n \
		's/.*objects, \([0-9]*\) direct.*/\1/p' "$TMP/i.census")))
	via64_total=$((via64_total + $(sed -n \
		's/.*, \([0-9]*\) via the 64-bit.*/\1/p' "$TMP/i.census")))
}

nidx=0
npackobj=0
for i in $IDXES; do
	tag="idx $(basename "$i")"
	nidx=$((nidx + 1))
	idx_vs_showindex "$tag" "$i"
	npackobj=$((npackobj + $(wc -l < "$TMP/i.ours")))
	# The CRC in the index is over the object's bytes AS PACKED, which means
	# the extent of each object in the pack: from its own offset to the next
	# one in PACK order, which the index only yields once its offsets are
	# sorted. git wrote these CRCs; we recompute them over git's pack bytes.
	eq "$tag: every CRC matches the packed data" \
		"$("$GITOBJ" idxcrc "$i" 2>/dev/null | tail -1)" \
		"$(wc -l < "$TMP/i.ours" | tr -d ' ') objects, 0 bad crcs"
	# And git agrees the index is good, so accepting it is not acceptance of
	# something git would reject.
	assert "$tag: git verify-pack accepts it" \
		$GIT -C "$SCRATCH" verify-pack "$i"
	# The index rebuilt from the pack alone, by git, today. This is the one
	# comparison where both sides are git's own writers, so a disagreement
	# would be a repacked corpus rather than a bug here.
	cpw "$i" "$TMP/orig.idx"
	cpw "${i%.idx}.pack" "$TMP/re.pack"
	rm -f "$TMP/re.idx"
	if $GIT -C "$SCRATCH" index-pack -o "$TMP/re.idx" "$TMP/re.pack" > /dev/null 2>&1; then
		assert "$tag: git index-pack rebuilds it byte for byte" \
			cmp -s "$TMP/re.idx" "$TMP/orig.idx"
		"$GITOBJ" idx "$TMP/re.idx" > "$TMP/i.re" 2>/dev/null
		assert "$tag: and we read the rebuilt index the same way" \
			cmp -s "$TMP/i.re" "$TMP/i.ours"
	else
		no "$tag: git index-pack could not rebuild it"
	fi
	# The mutation fixtures below are only about what was changed if the
	# rebuild is otherwise exact.
	python3 "$TMP/idxtool.py" rebuild "$i" "$TMP/rb.idx"
	assert "$tag: the fixture builder round-trips it byte for byte" \
		cmp -s "$TMP/rb.idx" "$i"
done
[ "$nidx" -ge 1 ] && ok || no "no pack index to read"
printf 'read %d pack indexes, %d objects\n' "$nidx" "$npackobj"

# --- the 64-bit offset table ----------------------------------------
# An offset at or above 2^31 does not fit the 32-bit entry, so the entry
# carries the top bit plus an index into a separate table of 64-bit offsets.
# A pack that needs it is over two gigabytes, so nothing in any corpus here
# reaches it and no amount of real data ever will. It is built instead.
#
# First over a REAL pack, with every offset routed through the table and the
# values unchanged. git follows the indirection on the top bit alone, so this
# is a valid index for that pack: `git verify-pack` reads the pack through it,
# `git cat-file` gets object content out of it, and both must agree with the
# plain index they came from.
IND=$TMP/packs/ind
mkdir -p "$IND"
python3 "$TMP/idxtool.py" indirect "$SELFIDX" "$IND/pack-$SELFPACK.idx"
cpw "$TMP/packs/self-$SELFPACK.pack" "$IND/pack-$SELFPACK.pack"
assert "the indirect index really differs from the plain one" \
	sh -c "! cmp -s '$IND/pack-$SELFPACK.idx' '$SELFIDX'"
idx_vs_showindex "indirect" "$IND/pack-$SELFPACK.idx"
# Every object, through the table, and nothing left on the direct path.
ind_census=$(cat "$TMP/i.census")
eq "the indirect index sends all but the first object through the table" \
	"$ind_census" \
	"$NSELF objects, 1 direct, $((NSELF - 1)) via the 64-bit table of $((NSELF - 1))"
# The offsets have to come out as the plain index's, object for object.
"$GITOBJ" idx "$SELFIDX" > "$TMP/i.plain" 2>/dev/null
"$GITOBJ" idx "$IND/pack-$SELFPACK.idx" > "$TMP/i.ind" 2>/dev/null
assert "the table resolves to the same offsets as the 32-bit entries" \
	cmp -s "$TMP/i.plain" "$TMP/i.ind"
eq "and the CRCs still check out, with the extents derived through it" \
	"$("$GITOBJ" idxcrc "$IND/pack-$SELFPACK.idx" 2>/dev/null | tail -1)" \
	"$NSELF objects, 0 bad crcs"
assert "git verify-pack reads the pack through the 64-bit table" \
	$GIT -C "$SCRATCH" verify-pack "$IND/pack-$SELFPACK.idx"
# git resolving a NAME to an offset through the table, and inflating what it
# finds there: the whole lookup path, with git on the far side of it.
IREPO=$TMP/packs/irepo
$GIT init -q --bare "$IREPO"
cpw "$IND/pack-$SELFPACK.idx" "$IREPO/objects/pack/pack-$SELFPACK.idx"
cpw "$IND/pack-$SELFPACK.pack" "$IREPO/objects/pack/pack-$SELFPACK.pack"
eq "git lists every object in the repository whose only index is that one" \
	"$($GIT --git-dir="$IREPO" cat-file --batch-all-objects --batch-check | wc -l | tr -d ' ')" \
	"$NSELF"
iblob=$($GIT --git-dir="$IREPO" cat-file --batch-all-objects --batch-check |
	awk '$2=="blob"{print $1; exit}')
eq "and reads a blob out of it, through the table" \
	"$($GIT --git-dir="$IREPO" cat-file blob "$iblob" | wc -c)" \
	"$($GIT --git-dir="$SELFREPO" cat-file blob "$iblob" | wc -c)"
$GIT --git-dir="$IREPO" fsck > "$TMP/fsck.out" 2>&1
assert "git fsck is clean over the repository indexed through the table" \
	sh -c "! grep -Eiv '^(notice|dangling)' '$TMP/fsck.out' | grep -q ."

# Then the offsets a real pack cannot have: both sides of 2^31 and 2^32, the
# top bit set, and 2^64-1. There is no pack to go with these, which is why
# show-index is the oracle: it reads the index and nothing else. The first
# value is BELOW 2^31 and still goes through the table, so the indirection is
# tested separately from the magnitude.
python3 "$TMP/idxtool.py" bigoff "$SELFIDX" "$TMP/big.idx"
idx_vs_showindex "bigoff" "$TMP/big.idx"
for v in 2147483647 2147483648 4294967296 9223372036854775808 18446744073709551615; do
	assert "bigoff: offset $v is read back exactly" \
		grep -qx "$v [0-9a-f]\{40\} ([0-9a-f]\{8\})" "$TMP/i.ours"
done
# The guard against the whole of the above passing vacuously.
[ "$via64_total" -ge 100 ] && ok ||
	no "only $via64_total objects went through the 64-bit offset table"
[ "$via32_total" -ge 100 ] && ok ||
	no "only $via32_total objects went through a 32-bit offset entry"
printf '%d objects read through a 32-bit offset, %d through the 64-bit table\n' \
	"$via32_total" "$via64_total"

# --- refusals -------------------------------------------------------
# Each of these is one lie about the index, and each refusal has to name a
# position: "corrupt index" sends a reader back to a megabyte of binary.
# git is the authority for the lie being a lie, and which git command
# notices differs -- show-index checks the parts it has to walk, verify-pack
# checks the index against the pack.
BAD=$TMP/packs/bad
mkdir -p "$BAD"
# The message is asserted, not just the exit status. Refusing for the wrong
# reason is how a check stops being load-bearing without anything noticing:
# delete the size arithmetic and a truncated index is still refused, by the
# count of 64-bit offsets that the broken arithmetic then produces, so the
# exit status is identical and `refute` cannot tell the two apart. Two
# mutations survived the whole of this section for exactly that reason, and
# both die on the text.
idx_refuse() { # <kind> <what it is> <expected message, an extended regex>
	python3 "$TMP/idxtool.py" "$1" "$SELFIDX" "$BAD/$1.idx"
	refute "idx refuses $2" "$GITOBJ" idx "$BAD/$1.idx"
	assert "and names the rule and the place: $2" sh -c \
		"'$GITOBJ' idx '$BAD/$1.idx' 2>&1 | grep -Eq '$3'"
}
# Caught by reading the index alone.
idx_refuse trunc "a truncated index" \
	'too small for the object count it declares: [0-9]+'
idx_refuse ver "an index version it does not know" \
	'unsupported pack index version: 3'
idx_refuse partial8 "a trailing partial 64-bit offset" \
	'ends in a partial 64-bit offset at [0-9]+'
idx_refuse fanback "a fanout entry that goes backwards" \
	'fanout entry goes backwards at [0-9]+'
idx_refuse unsorted "a name list out of order" \
	'names are not in increasing order at [0-9]+'
idx_refuse dupname "the same name twice" \
	'names are not in increasing order at [0-9]+'
idx_refuse fanbucket "a fanout entry that disagrees with the names" \
	'fanout bucket disagrees with the name it indexes at [0-9]+'
idx_refuse bigpast "a 64-bit indirection past the end of the table" \
	'64-bit offset index past the end of the table at [0-9]+'
idx_refuse bigtoomany "more 64-bit offsets than objects" \
	'more 64-bit offsets than objects that could need one: [0-9]+'
idx_refuse idxsum "an index whose own checksum does not match" \
	'pack index checksum mismatch at [0-9]+' 
# No position for this one: the magic is the first four bytes, and a v1
# index is not corrupt, it is a format with no reader here.
python3 "$TMP/idxtool.py" magic "$SELFIDX" "$BAD/magic.idx"
refute "idx refuses an index with no v2 magic" "$GITOBJ" idx "$BAD/magic.idx"
assert "and names v1 as the reason" sh -c \
	"'$GITOBJ' idx '$BAD/magic.idx' 2>&1 | grep -q 'v1'"

# git refuses the same files. show-index walks names and the 64-bit table, so
# it sees five of them; verify-pack also reads the pack, so it sees all.
for k in trunc ver partial8 fanback unsorted dupname fanbucket bigpast bigtoomany idxsum magic; do
	cpw "$TMP/packs/self-$SELFPACK.pack" "$BAD/pack-$SELFPACK.pack"
	cpw "$BAD/$k.idx" "$BAD/pack-$SELFPACK.idx"
	assert "git verify-pack refuses $k too" sh -c \
		"! $GIT -C '$SCRATCH' verify-pack '$BAD/pack-$SELFPACK.idx' >/dev/null 2>&1"
done
for k in trunc ver fanback magic; do
	assert "git show-index refuses $k too" sh -c \
		"! $GIT show-index --object-format=sha1 < '$BAD/$k.idx' >/dev/null 2>&1"
done
# The ones show-index reads happily are the ones it never has to resolve: it
# walks the name list in order without consulting the fanout, it does not
# check either checksum, and its bounds check on the 64-bit table does not
# fire for an index into a table that is empty. verify-pack is the authority
# for all of them.
for k in unsorted dupname idxsum partial8 bigpast bigtoomany; do
	assert "git show-index does not notice $k, so verify-pack is the authority" \
		sh -c "$GIT show-index --object-format=sha1 < '$BAD/$k.idx' >/dev/null 2>&1"
done
# A fanout that disagrees with the names is the one corruption with a
# visible consequence rather than a parse error: git's binary search looks
# in the wrong range and the object it misplaces becomes unfindable.
cpw "$TMP/packs/self-$SELFPACK.pack" "$IREPO/objects/pack/pack-bad-$SELFPACK.pack"
cpw "$BAD/fanbucket.idx" "$IREPO/objects/pack/pack-bad-$SELFPACK.idx"
rm -f "$IREPO/objects/pack/pack-$SELFPACK.idx" "$IREPO/objects/pack/pack-$SELFPACK.pack"
# The victim is computed from the GOOD index: it is the first object of the
# bucket after the boundary the tool moves, which the moved boundary then
# claims for the bucket below it.
lost=$(python3 -c '
import sys, struct
b = open(sys.argv[1], "rb").read()
fan = struct.unpack(">256I", b[8:1032])
k = next(i for i in range(255) if fan[i] < fan[i + 1])
s = 1032 + 20 * fan[k]
print(b[s:s + 20].hex())
' "$SELFIDX")
refute "git cannot find the object a shifted fanout misplaces" \
	$GIT --git-dir="$IREPO" cat-file -e "$lost"

# Refusals that need the pack as well: the CRC, the offsets and the two
# cross-checks between the files.
crc_refuse() { # <kind> <what it is> <expected message> [pack-mutation]
	rm -rf "$BAD/c"
	mkdir -p "$BAD/c"
	if [ -n "${4:-}" ]; then
		python3 "$TMP/packmut.py" "$4" "$TMP/packs/self-$SELFPACK.pack" \
			"$BAD/c/pack-$SELFPACK.pack"
		cpw "$SELFIDX" "$BAD/c/pack-$SELFPACK.idx"
	else
		python3 "$TMP/idxtool.py" "$1" "$SELFIDX" "$BAD/c/pack-$SELFPACK.idx"
		cpw "$TMP/packs/self-$SELFPACK.pack" "$BAD/c/pack-$SELFPACK.pack"
	fi
	refute "idxcrc refuses $2" "$GITOBJ" idxcrc "$BAD/c/pack-$SELFPACK.idx"
	assert "and names the rule and the place: $2" sh -c \
		"'$GITOBJ' idxcrc '$BAD/c/pack-$SELFPACK.idx' 2>&1 | grep -Eq '$3'"
	assert "git verify-pack refuses $2 too" sh -c \
		"! $GIT -C '$SCRATCH' verify-pack '$BAD/c/pack-$SELFPACK.idx' >/dev/null 2>&1"
}
crc_refuse offpast "an offset outside the pack" \
	'index offset is outside the pack at [0-9]+'
crc_refuse offdup "two objects at one offset" \
	'two objects share a pack offset at [0-9]+'
crc_refuse packcount "a pack whose header counts different objects" \
	'pack object count disagrees with the index: [0-9]+' count
crc_refuse packsum "a pack whose checksum is not the one the index carries" \
	'not the trailer the pack carries at [0-9]+' sum
# A wrong CRC is not a refusal, it is a finding: the index parses, so the
# object is named and counted the way `verify` names a loose object whose
# content was swapped.
rm -f "$BAD/c/pack-$SELFPACK.idx"
python3 "$TMP/idxtool.py" crcbit "$SELFIDX" "$BAD/c/pack-$SELFPACK.idx"
cpw "$TMP/packs/self-$SELFPACK.pack" "$BAD/c/pack-$SELFPACK.pack"
refute "idxcrc exits 1 on a CRC that does not match the pack" \
	"$GITOBJ" idxcrc "$BAD/c/pack-$SELFPACK.idx"
eq "and counts exactly the one bad CRC" \
	"$("$GITOBJ" idxcrc "$BAD/c/pack-$SELFPACK.idx" 2>/dev/null | tail -1)" \
	"$NSELF objects, 1 bad crcs"
# crcbit breaks the CRC of the FIRST object in index order, which is the
# first line show-index prints.
crcvictim=$($GIT show-index --object-format=sha1 < "$SELFIDX" | awk 'NR==1{print $2}')
assert "and names the object whose CRC is wrong" sh -c \
	"'$GITOBJ' idxcrc '$BAD/c/pack-$SELFPACK.idx' 2>/dev/null |
		grep -q '^CRC MISMATCH $crcvictim '"
assert "git verify-pack refuses the broken CRC too" sh -c \
	"! $GIT -C '$SCRATCH' verify-pack '$BAD/c/pack-$SELFPACK.idx' >/dev/null 2>&1"

refute "idx refuses a file that is not an index at all" \
	"$GITOBJ" idx "$TMP/fix/rand"
refute "idx refuses an index that does not exist" \
	"$GITOBJ" idx "$TMP/no/such/pack.idx"
refute "idxcrc refuses a path that does not end in .idx" \
	"$GITOBJ" idxcrc "$TMP/packs/self-$SELFPACK.pack"
rm -f "$BAD/nopack.pack"
cpw "$SELFIDX" "$BAD/nopack.idx"
refute "idxcrc refuses an index with no pack beside it" \
	"$GITOBJ" idxcrc "$BAD/nopack.idx"

# =====================================================================
# 9. the pack walk: the type/size varint, and objects stored whole
# =====================================================================
# `git verify-pack -v` is the oracle here and it prints more than an index
# can answer: an object's TYPE and its inflated SIZE come out of the entry
# header in the pack, which section 8 never opened. The fourth column, the
# bytes the entry occupies, is the extent the index's sorted offsets give.
#
# A corpus of its own, because the self corpus cannot do this job. Its blobs
# are a few dozen bytes each and git does not attempt a delta below 50
# bytes, so `pack-objects` leaves every one of them whole whatever window it
# is given, and a standalone clone would have no delta to read anywhere. 400
# lines with one rewritten per revision is a shape git deltas readily.
#
# The tree grows by one entry per revision and the entry added names that
# revision's blob, so consecutive trees are append-only edits of each other.
# That matters because a delta entry carries no type of its own: it inherits
# the type of the object at the end of its chain, so a corpus whose deltas
# are all blobs cannot tell a type read from the base apart from one read
# anywhere else.
DREPO=$TMP/dcorpus
DW=$TMP/mk/dcorpus
mkdir -p "$DW"
$GIT init -q --bare "$DREPO"
seq 1 400 | sed 's/^/line /' > "$DW/f"
: > "$DW/tree"
dparent=
i=0
while [ "$i" -lt 40 ]; do
	i=$((i+1))
	sed -i "${i}s/.*/line $i rewritten in revision $i/" "$DW/f"
	db=$($GIT --git-dir="$DREPO" hash-object -w "$DW/f")
	printf '100644 blob %s\tf%03d\n' "$db" "$i" >> "$DW/tree"
	dt=$($GIT --git-dir="$DREPO" mktree < "$DW/tree")
	# Fixed dates, so every name in this corpus is the same on every run.
	dparent=$(GIT_AUTHOR_NAME=deltas GIT_AUTHOR_EMAIL=deltas@invalid \
		GIT_COMMITTER_NAME=deltas GIT_COMMITTER_EMAIL=deltas@invalid \
		GIT_AUTHOR_DATE='2002-02-02T00:00:00Z' \
		GIT_COMMITTER_DATE='2002-02-02T00:00:00Z' \
		$GIT --git-dir="$DREPO" commit-tree \
			${dparent:+-p $dparent} "$dt" -m "revision $i of the delta corpus")
done
# Three large revisions as well, because the copy instruction's implicit
# length of 0x10000 is only reached over a base of at least 64KB: git's
# encoder omits the length bytes for exactly that value and splits any
# longer run into 0x10000 pieces. With 400-line blobs alone, taking the
# absent length as 0 instead of 0x10000 is a mutation nothing here can kill,
# and a standalone clone had no pack that reached it. The edit goes near the
# END of the file so the unchanged prefix is what gets copied.
seq 1 20000 | sed 's/^/a line of the big file, number /' > "$DW/big"
i=0
while [ "$i" -lt 3 ]; do
	i=$((i+1))
	sed -i "$((19990 + i))s/.*/rewritten in big revision $i/" "$DW/big"
	$GIT --git-dir="$DREPO" hash-object -w "$DW/big" > /dev/null
done
printf 'object %s\ntype commit\ntag deltas\ntagger deltas <deltas@invalid> 1012608000 +0000\n\nannotated\n' \
	"$dparent" | $GIT --git-dir="$DREPO" mktag > /dev/null
$GIT --git-dir="$DREPO" cat-file --batch-all-objects --batch-check |
	awk '{print $1}' > "$TMP/packs/din"
NDOBJ=$(wc -l < "$TMP/packs/din" | tr -d ' ')
[ "$NDOBJ" -ge 100 ] && ok || no "the delta corpus has only $NDOBJ objects"

# Two packs of the same objects: one full of OFS_DELTA, one with no delta at
# all. `--delta-base-offset` is not optional here. Plumbing `pack-objects`
# leaves `pack.useDeltaBaseOffset` off and writes REF_DELTA, where `git gc`
# and `git repack` pass the flag, so every pack in the corpus is OFS_DELTA
# and a fixture built without it is the OTHER encoding. That was caught by
# this section going red, REF_DELTA being the one thing still refused.
mkdir -p "$TMP/packs/d"
# --threads=1 because the delta search is threaded and its result is not
# otherwise reproducible: two runs of the same command over the same objects
# gave 76 delta entries and then 75.
DPACK=$($GIT --git-dir="$DREPO" pack-objects --non-empty --delta-base-offset \
	--threads=1 "$TMP/packs/d/dd" < "$TMP/packs/din")
NDPACK=$($GIT --git-dir="$DREPO" pack-objects --window=0 --non-empty \
	--threads=1 "$TMP/packs/d/nd" < "$TMP/packs/din")
DIDX="$TMP/packs/d/dd-$DPACK.idx"
NDIDX="$TMP/packs/d/nd-$NDPACK.idx"
assert "both packs were built from the delta corpus" test -f "$DIDX" -a -f "$NDIDX"
# verify-pack -v prints five fields for an entry stored whole and seven for
# a delta, which is how the two packs are told apart without trusting the
# flag that was meant to produce them.
vpv() { $GIT -C "$SCRATCH" verify-pack -v "$1" | awk '$1 ~ /^[0-9a-f]{40}$/'; }
eq "git says the window=0 pack has no delta in it at all" \
	"$(vpv "$NDIDX" | awk 'NF>=7' | grep -c .)" 0
eq "and that it holds every object of the delta corpus" \
	"$(vpv "$NDIDX" | grep -c .)" "$NDOBJ"
# The other half: the pack git chose the layout for is mostly deltas, and
# their chains are deep. Without this the refusal below could be measured
# against a pack that happened to have none either.
ndelta=$(vpv "$DIDX" | awk 'NF>=7' | grep -c .)
ddepth=$(vpv "$DIDX" | awk 'NF>=7{if($6>m)m=$6}END{print m+0}')
[ "$ndelta" -ge 50 ] && ok ||
	no "the delta corpus packs to only $ndelta delta entries"
[ "$ddepth" -ge 5 ] && ok ||
	no "the deepest delta chain in the delta corpus is only $ddepth"
printf 'the delta corpus: %d objects, %d delta entries, deepest chain %d\n' \
	"$NDOBJ" "$ndelta" "$ddepth"

# Two lies about an entry header, which is the only way to reach the checks
# that the header is not self-consistent. Both need the pack edited, and an
# edit invalidates four things that have nothing to do with the defect: the
# pack's trailing checksum, the copy of it the index carries, the object's
# CRC, and the index's own checksum. All four are re-stamped, so each
# fixture is a single lie and cannot be refused for the wrong reason. The
# guard on that is that `gitobj idxcrc` still accepts the edited pair.
cat > "$TMP/packedit.py" <<'PYEDIT'
import hashlib, struct, sys, zlib
kind, pk, ix, opk, oix = sys.argv[1:6]
arg = sys.argv[6] if len(sys.argv) > 6 else None
p = bytearray(open(pk, 'rb').read())
b = open(ix, 'rb').read()
HDR = 1032
fan = struct.unpack('>256I', b[8:HDR])
n = fan[255]
o = HDR
names = [b[o + 20 * i:o + 20 * i + 20] for i in range(n)]; o += 20 * n
crcs = list(struct.unpack('>%dI' % n, b[o:o + 4 * n])); o += 4 * n
off = list(struct.unpack('>%dI' % n, b[o:o + 4 * n])); o += 4 * n
rest = len(b) - 40 - o
big = list(struct.unpack('>%dQ' % (rest // 8), b[o:o + rest]))
assert not any(v & 0x80000000 for v in off), 'this edits 32-bit offsets only'
order = sorted(range(n), key=lambda i: off[i])
i0 = order[0]
at = off[i0]
recrc = True
if kind == 'type5':      # 5 is the one type number git has never assigned
    p[at] = (p[at] & 0x8f) | (5 << 4)
elif kind == 'badsize':   # the declared size, one away from the real one
    p[at] ^= 1
elif kind == 'dropname':
    # Stop the index naming one object, and tell the pack header it holds
    # one object fewer, which is the only way to reach a REF_DELTA whose
    # base this pack does not hold. The base's BYTES stay where they are:
    # what goes is the index entry that would have found them.
    k = names.index(bytes.fromhex(arg))
    del names[k], crcs[k], off[k]
    n -= 1
    p[8:12] = struct.pack('>I', n)
    recrc = False
else:
    raise SystemExit('unknown pack edit ' + kind)
p[-20:] = hashlib.sha1(bytes(p[:-20])).digest()
if recrc:
    end = off[order[1]] if n > 1 else len(p) - 20
    crcs[i0] = zlib.crc32(bytes(p[at:end])) & 0xffffffff
else:
    # The fanout is counted from the names that are left, so it still
    # agrees with them.
    c = [0] * 256
    for nm in names:
        c[nm[0]] += 1
    fan, t = [], 0
    for j in range(256):
        t += c[j]
        fan.append(t)
out = b'\377tOc' + struct.pack('>I', 2) + struct.pack('>256I', *fan)
out += b''.join(names)
out += struct.pack('>%dI' % n, *crcs)
out += struct.pack('>%dI' % n, *off)
out += struct.pack('>%dQ' % len(big), *big)
out += bytes(p[-20:])
out += hashlib.sha1(out).digest()
open(opk, 'wb').write(bytes(p))
open(oix, 'wb').write(out)
PYEDIT

# Per object, not per file: a diff over a hundred objects says only that
# something somewhere disagreed. And the census is checked against git's own
# numbers rather than reported, because every one of these comparisons
# passes over a pack with no delta in it while the delta code never runs.
pls_objs=0
pls_delta=0
pls_depth=0
pls_inf=0
pls_hit=0
pls_nocache=0
last_ofs=0
last_ref=0
packls_vs_vpv() { # <label> <idx>
	local nobj gd gm cd cm
	"$GITOBJ" packls "$2" > "$TMP/p.ours" 2> "$TMP/p.census"
	eq "$1: packls exits 0" "$?" 0
	vpv "$2" > "$TMP/p.theirs"
	nobj=$(wc -l < "$TMP/p.theirs" | tr -d ' ')
	eq "$1: a line per object, as verify-pack -v prints" \
		"$(wc -l < "$TMP/p.ours" | tr -d ' ')" "$nobj"
	local a b
	while IFS= read -r a <&3 && IFS= read -r b <&4; do
		pls_objs=$((pls_objs + 1))
		eq "$1 ${b%% *}" "$a" "$b"
	done 3< "$TMP/p.ours" 4< "$TMP/p.theirs"
	# git counts the deltas and the deepest chain from its own output: a
	# delta line has seven fields where an entry stored whole has five, and
	# the sixth is the chain length.
	gd=$(awk 'NF>=7' "$TMP/p.theirs" | grep -c .)
	gm=$(awk 'NF>=7{if($6>m)m=$6}END{print m+0}' "$TMP/p.theirs")
	cd=$(sed -n 's/.*, \([0-9]*\) through a delta chain.*/\1/p' "$TMP/p.census")
	cm=$(sed -n 's/.*deepest chain \([0-9]*\).*/\1/p' "$TMP/p.census")
	eq "$1: the census agrees with git on how many entries are deltas" "$cd" "$gd"
	eq "$1: and on the deepest chain walked" "$cm" "$gm"
	# Which encoding carried them, which git's output cannot say: a delta
	# line looks the same either way. Counted per link rather than per
	# object, so a chain of 9 contributes 9.
	last_ofs=$(sed -n 's/.*, \([0-9]*\) ofs-delta and.*/\1/p' "$TMP/p.census")
	last_ref=$(sed -n 's/.*and \([0-9]*\) ref-delta links.*/\1/p' "$TMP/p.census")
	pls_delta=$((pls_delta + gd))
	[ "$gm" -gt "$pls_depth" ] && pls_depth=$gm
	# The base cache, against arithmetic and against git. Every entry the
	# reader reaches is either inflated or served from the cache, so those
	# two counts have to add up to the objects plus the links walked; the
	# inflations can never fall below the object count, because a cache
	# that answered for the object ASKED for would make a walk over a pack
	# answer out of itself; and git's own sum of chain lengths is what the
	# walk would cost with no cache at all, so the saving is measured
	# rather than asserted to exist.
	local cinf chit cofs cref gsum
	cinf=$(sed -n 's/.*, \([0-9]*\) inflations.*/\1/p' "$TMP/p.census")
	chit=$(sed -n 's/.*and \([0-9]*\) base-cache hits.*/\1/p' "$TMP/p.census")
	cofs=$(sed -n 's/.*, \([0-9]*\) ofs-delta and.*/\1/p' "$TMP/p.census")
	cref=$(sed -n 's/.*and \([0-9]*\) ref-delta links.*/\1/p' "$TMP/p.census")
	gsum=$(awk 'NF>=7{s+=$6}END{print s+0}' "$TMP/p.theirs")
	eq "$1: every entry reached was either inflated or found in the cache" \
		"$((cinf + chit))" "$((nobj + cofs + cref))"
	if [ "$cinf" -ge "$nobj" ]; then ok
	else no "$1: $cinf inflations for $nobj objects, so the cache answered for an object rather than a base"; fi
	if [ "$gsum" -eq 0 ]; then
		eq "$1: a pack with no delta needs no cache hit" "$chit" 0
	elif [ "$gd" -lt 20 ]; then
		# Too few deltas for a cache to have anything to save: a base read
		# once is a base read once. All that is asked here is that the
		# cache has not made it worse.
		if [ "$cinf" -le "$((nobj + gsum))" ]; then ok
		else no "$1: $cinf inflations where no cache at all needs $((nobj + gsum))"; fi
	elif [ "$cinf" -lt "$((nobj + gsum))" ]; then
		ok
	else
		no "$1: the base cache saved nothing: $cinf inflations where git's chain lengths say $((nobj + gsum))"
	fi
	pls_inf=$((pls_inf + cinf))
	pls_hit=$((pls_hit + chit))
	pls_nocache=$((pls_nocache + nobj + gsum))
	# The hard invariant, on the far side of the pack: every name git filed
	# an object under is the SHA-1 of what came back out of the entry, delta
	# chain and all.
	eq "$1: every object hashes back to its own name" \
		"$("$GITOBJ" packverify "$2" 2>/dev/null)" "$nobj objects, 0 mismatched"
}

# The delta-free pack first, where the census has to say that nothing took
# the delta path at all.
packls_vs_vpv "packls nd" "$NDIDX"
eq "and every entry of the delta-free pack was read whole" \
	"$(cat "$TMP/p.census")" \
	"$NDOBJ objects, $NDOBJ read whole, 0 through a delta chain, deepest chain 0, 0 ofs-delta and 0 ref-delta links, $NDOBJ inflations and 0 base-cache hits"

# Then the pack git chose the layout for, and every pack in the corpus. The
# sibling packs are the real evidence here: 2815 objects across eight
# histories, chains up to 29 deep, none of it arranged by this suite.
packls_vs_vpv "packls dd" "$DIDX"
[ "$last_ofs" -ge 70 ] && ok ||
	no "the OFS_DELTA fixture resolved only $last_ofs ofs-delta links"
eq "and not one of its links was a REF_DELTA" "$last_ref" 0
for i in $IDXES; do
	packls_vs_vpv "packls $(basename "$i")" "$i"
	# Every pack in the collection came out of `git gc`, which passes
	# --delta-base-offset, so the corpus provides no REF_DELTA coverage at
	# all. That is the whole reason the fixture below is built.
	eq "packls $(basename "$i"): no REF_DELTA, as git gc writes none" \
		"$last_ref" 0
done
# The same objects again, packed the other way. `--no-delta-base-offset` is
# what makes git write REF_DELTA, and nothing in the collection has one,
# since everything here was packed by `git gc`.
#
# A REF_DELTA names its base by hash, so the base can sit anywhere in the
# pack, before this entry or after it, and finding it is a binary search in
# the index rather than a subtraction. The resolved objects have to come out
# the same as from the OFS_DELTA pack, which is the strongest thing available
# here: the same 124 objects, two encodings, one set of names.
RD=$TMP/packs/rd
mkdir -p "$RD"
RDPACK=$($GIT --git-dir="$DREPO" pack-objects --non-empty --threads=1 \
	--no-delta-base-offset "$RD/rd" < "$TMP/packs/din")
RDIDX="$RD/rd-$RDPACK.idx"
assert "a REF_DELTA pack was built from the same objects" test -f "$RDIDX"
packls_vs_vpv "packls rd" "$RDIDX"
[ "$last_ref" -ge 70 ] && ok ||
	no "the REF_DELTA fixture resolved only $last_ref ref-delta links"
eq "and not one of its links was an OFS_DELTA" "$last_ofs" 0
# Chains, not just single links: a base reached by name can itself be a
# REF_DELTA, and that is the half of this item depth is for.
rdepth=$(sed -n 's/.*deepest chain \([0-9]*\).*/\1/p' "$TMP/p.census")
[ "$rdepth" -ge 5 ] && ok ||
	no "the deepest REF_DELTA chain was only $rdepth"
# The two packs hold the same objects, so `gitobj ls` over the two must
# agree about every name, type and size. Sorted, because pack order differs
# between the two layouts and that is not the claim.
"$GITOBJ" packls "$RDIDX" 2>/dev/null | awk '{print $1, $2}' | sort > "$TMP/p.rd"
"$GITOBJ" packls "$DIDX" 2>/dev/null | awk '{print $1, $2}' | sort > "$TMP/p.dd"
assert "both encodings give the same objects the same types" \
	cmp -s "$TMP/p.rd" "$TMP/p.dd"
eq "and every object of the REF_DELTA pack hashes back to its own name" \
	"$("$GITOBJ" packverify "$RDIDX" 2>/dev/null)" "$NDOBJ objects, 0 mismatched"
# A base that is not in the pack at all is a thin pack, which git sends down
# a wire and never stores. `git index-pack --fix-thin` is what completes one,
# so a stored pack whose REF_DELTA base is missing is not a thing git reads
# either; refusing it is the whole handling.
# An object that is loose AND packed, which nothing else here is: the self
# corpus has no pack and every sibling has no loose object. git lists such an
# object once, so `gitobj ls` must too, and without this fixture dropping the
# de-duplication is a mutation nothing can kill. The pack built above holds
# exactly the objects of the repository it was built from, so copying it in
# beside them gives every object two copies.
BOTH=$TMP/packs/both
rm -rf "$BOTH"
$GIT init -q --bare "$BOTH"
for d in "$SELFREPO/objects/"??; do cp -r "$d" "$BOTH/objects/"; done
cpw "$SELFIDX" "$BOTH/objects/pack/pack-$SELFPACK.idx"
cpw "$TMP/packs/self-$SELFPACK.pack" "$BOTH/objects/pack/pack-$SELFPACK.pack"
eq "the both-copies fixture has every object twice" \
	"$(($(loose_shas "$BOTH" | grep -c .) + $("$GITOBJ" idx "$SELFIDX" 2>/dev/null | wc -l)))" \
	"$((NSELF * 2))"
$GIT --git-dir="$BOTH" cat-file --batch-all-objects --batch-check |
	sort > "$TMP/b.theirs"
"$GITOBJ" ls "$BOTH/objects" > "$TMP/b.ours" 2> "$TMP/b.census"
eq "ls lists an object that is both loose and packed exactly once" \
	"$(wc -l < "$TMP/b.ours" | tr -d ' ')" "$NSELF"
assert "and agrees with git line for line" cmp -s "$TMP/b.ours" "$TMP/b.theirs"
# Loose first, which is the order git looks in.
eq "and reads the loose copy rather than the packed one" \
	"$(cat "$TMP/b.census")" \
	"$NSELF objects, $NSELF loose, 0 from 1 pack, 1 object directory"

TH=$TMP/packs/thin
rm -rf "$TH"
mkdir -p "$TH"
thinvictim=$(vpv "$RDIDX" | awk 'NF>=7{print $7; exit}')
python3 "$TMP/packedit.py" dropname "$RD/rd-$RDPACK.pack" "$RDIDX" \
	"$TH/pack-t.pack" "$TH/pack-t.idx" "$thinvictim"
eq "the thin fixture's index names one object fewer" \
	"$(($("$GITOBJ" idx "$TH/pack-t.idx" 2>/dev/null | wc -l) + 1))" "$NDOBJ"
refute "packls refuses a REF_DELTA whose base the pack does not hold" \
	"$GITOBJ" packls "$TH/pack-t.idx"
assert "and says so rather than reading some other object" sh -c \
	"'$GITOBJ' packls '$TH/pack-t.idx' 2>&1 >/dev/null |
		grep -q 'not an object this pack holds'"
assert "git verify-pack refuses it too" sh -c \
	"! $GIT -C '$SCRATCH' verify-pack '$TH/pack-t.idx' >/dev/null 2>&1"

refute "packls refuses a path that does not end in .idx" \
	"$GITOBJ" packls "$TMP/packs/self-$SELFPACK.pack"
refute "packls refuses an index with no pack beside it" \
	"$GITOBJ" packls "$BAD/nopack.idx"
refute "packls refuses an index it cannot parse" "$GITOBJ" packls "$BAD/trunc.idx"

PE=$TMP/packs/pe
pack_refuse() { # <kind> <what it is> <expected message, an extended regex>
	rm -rf "$PE"
	mkdir -p "$PE"
	python3 "$TMP/packedit.py" "$1" "$TMP/packs/d/nd-$NDPACK.pack" "$NDIDX" \
		"$PE/pack-e.pack" "$PE/pack-e.idx"
	assert "the index and the CRCs of the edited pack are still good: $2" \
		"$GITOBJ" idxcrc "$PE/pack-e.idx"
	refute "packls refuses $2" "$GITOBJ" packls "$PE/pack-e.idx"
	assert "and names the rule and the place: $2" sh -c \
		"'$GITOBJ' packls '$PE/pack-e.idx' 2>&1 >/dev/null | grep -Eq '$3'"
	assert "git verify-pack refuses $2 too" sh -c \
		"! $GIT -C '$SCRATCH' verify-pack '$PE/pack-e.idx' >/dev/null 2>&1"
}
pack_refuse type5 "an entry whose type number git does not use" \
	'type number git does not use at [0-9]+'
pack_refuse badsize "an entry that inflated to a size other than its own" \
	'inflated to a size other than the one it declares at [0-9]+'
# =====================================================================
# 10. a pack built by hand: the lengths git never gets wrong
# =====================================================================
# Every length in a pack is a number chosen by whoever wrote the file, and
# git writes them all correctly, so the checks on them cannot be reached by
# any fixture git produces. Three mutations of the delta code survived the
# whole of section 9 for exactly that reason: the declared base size, the
# declared result size, and the bound that keeps a varint or a zlib stream
# off the pack trailer.
#
# So this builds packs itself, which puts the fixture builder in the
# position of being the thing that has to be trusted. git settles that: it
# must accept the well-formed one, resolve its chain, and rebuild its index
# from the pack alone byte for byte. Only then is a mutation of it one lie.
cat > "$TMP/packgen.py" <<'PYGEN'
import hashlib, struct, sys, zlib

HDR = 1032


def ent_hdr(t, n):
    """A pack entry header: continuation bit, three bits of type, four of
    size, then seven bits per byte."""
    out = bytearray()
    c = (t << 4) | (n & 15)
    n >>= 4
    while n:
        out.append(c | 0x80)
        c = n & 0x7f
        n >>= 7
    out.append(c)
    return bytes(out)


def ofs_varint(ofs):
    """git's own encoder for the OFS_DELTA distance, where every
    continuation byte takes one off before shifting."""
    out = [ofs & 127]
    ofs >>= 7
    while ofs:
        ofs -= 1
        out.append(128 | (ofs & 127))
        ofs >>= 7
    return bytes(reversed(out))


def dvarint(n):
    out = bytearray()
    while True:
        c = n & 0x7f
        n >>= 7
        out.append(c | (0x80 if n else 0))
        if not n:
            return bytes(out)


def copy(off, size):
    c = 0x80
    b = bytearray()
    for k in range(4):
        byte = (off >> (8 * k)) & 0xff
        if byte:
            c |= 1 << k
            b.append(byte)
    if size != 0x10000:       # absent length bytes mean 0x10000
        for k in range(3):
            byte = (size >> (8 * k)) & 0xff
            if byte:
                c |= 0x10 << k
                b.append(byte)
    return bytes([c]) + bytes(b)


def insert(data):
    assert 0 < len(data) < 128
    return bytes([len(data)]) + data


TYPES = {1: 'commit', 2: 'tree', 3: 'blob', 4: 'tag'}


def oid(t, data):
    return hashlib.sha1(('%s %d' % (TYPES[t], len(data))).encode() + b'\0' + data).digest()


def apply_instr(base, instr):
    out = bytearray()
    for op in instr:
        if op[0] == 'copy':
            out += base[op[1]:op[1] + op[2]]
        elif op[0] == 'insert':
            out += op[1]
    return bytes(out)


def build(spec, kind, flip=None):
    """spec is a list of entries in pack order. Returns (pack, idx).

    flip is (offset, mask), applied to the pack body before either checksum
    or any CRC is computed, so a flipped byte is the fixture's only lie."""
    n = len(spec)
    content = [None] * n
    types = [None] * n
    payload = [None] * n
    etype = [None] * n
    for i, e in enumerate(spec):
        if 'data' in e:
            content[i] = e['data']
            types[i] = e['type']
            payload[i] = e['data']
            etype[i] = e['type']
    # Resolved in dependency order rather than in pack order, because a
    # REF_DELTA may name a base that comes AFTER it in the pack: the base is
    # found by hash, not by position.
    todo = True
    while todo:
        todo = False
        for i, e in enumerate(spec):
            if content[i] is not None:
                continue
            b = e['base']
            if content[b] is None:
                todo = True
                continue
            res = apply_instr(content[b], e['instr'])
            content[i] = res
            types[i] = types[b]
            bs = e.get('base_size', len(content[b]))
            rs = e.get('res_size', len(res))
            payload[i] = dvarint(bs) + dvarint(rs) + b''.join(
                op[1] if op[0] == 'raw' else
                copy(op[1], op[2]) if op[0] == 'copy' else insert(op[1])
                for op in e['instr'])
            etype[i] = 6 if e['how'] == 'ofs' else 7
    assert all(c is not None for c in content), 'a delta base that is not there'

    names = [oid(types[i], content[i]) for i in range(len(spec))]
    if kind == 'wrongname':
        # The pack then holds bytes that are not what the index says they
        # are: one byte of the base blob is changed AFTER the names are
        # computed, so it and everything delta'd against it come out under a
        # hash the index does not carry. Everything else about the files
        # stays true, both checksums and all the CRCs included.
        b = bytearray(payload[0])
        b[0] ^= 0xff
        payload[0] = bytes(b)

    # Lay the entries out, which is what fixes the offsets the deltas need.
    body = bytearray()
    offs = []
    for i, e in enumerate(spec):
        offs.append(12 + len(body))
        n = len(payload[i])
        if kind == 'bigsize' and i == len(spec) - 1:
            n = (256 << 20) + 1      # a size no allocation should be made for
        body += ent_hdr(etype[i], n)
        if etype[i] == 6:
            d = offs[i] - offs[e['base']]
            if kind == 'ofszero':
                d = 0                # names the delta entry itself
            elif kind == 'ofspast':
                d = offs[i]          # one byte before the pack header
            body += ofs_varint(d)
        elif etype[i] == 7:
            nm = names[e['base']]
            if kind == 'refself' and i == len(spec) - 1:
                nm = names[i]        # a delta whose base is itself
            body += nm
        body += zlib.compress(payload[i], 6)

    pack = bytearray(b'PACK' + struct.pack('>II', 2, len(spec)) + bytes(body))
    if flip:
        pack[flip[0]] ^= flip[1]
    if kind == 'trunc':
        # Cut the last entry's zlib stream in half. Everything else stays
        # true, including both checksums and the CRCs, so the only lie is
        # that the pack ends early.
        cut = (len(pack) + offs[-1]) // 2
        pack = pack[:cut]
    pack += hashlib.sha1(bytes(pack)).digest()

    order = sorted(range(len(spec)), key=lambda i: names[i])
    crcs = []
    for i in order:
        end = offs[order_next(offs, i)] if order_next(offs, i) is not None \
            else len(pack) - 20
        crcs.append(zlib.crc32(bytes(pack[offs[i]:max(offs[i], end)])) & 0xffffffff)
    fan, t = [], 0
    c = [0] * 256
    for i in order:
        c[names[i][0]] += 1
    for k in range(256):
        t += c[k]
        fan.append(t)
    idx = b'\377tOc' + struct.pack('>I', 2) + struct.pack('>256I', *fan)
    idx += b''.join(names[i] for i in order)
    idx += struct.pack('>%dI' % len(order), *crcs)
    idx += struct.pack('>%dI' % len(order), *[offs[i] for i in order])
    idx += bytes(pack[-20:])
    idx += hashlib.sha1(idx).digest()
    return bytes(pack), idx


def order_next(offs, i):
    """The entry that follows entry i in PACK order, or None for the last."""
    later = [o for o in offs if o > offs[i]]
    if not later:
        return None
    return offs.index(min(later))


# A base big enough that a copy of exactly 0x10000 is reachable, and a chain
# two links deep with the second link a REF_DELTA, so one pack exercises
# both encodings and a base that is itself a delta.
BIG = bytes(bytearray((i * 7 + 11) & 0xff for i in range(70000)))

# A REF_DELTA whose base comes AFTER it in the pack, which only a REF_DELTA
# can do. It is the one shape in which an object is asked for by name having
# already been read as somebody's base, so it is the only thing that can see
# whether the base cache answers for the object asked for or only for bases.
SPEC_FWD = [
    {'how': 'ref', 'base': 1, 'instr': [
        ('copy', 0, 1024),
        ('insert', b'a REF_DELTA that comes before its own base'),
    ]},
    {'type': 3, 'data': BIG},
]

SPEC = [
    {'type': 3, 'data': BIG},
    {'how': 'ofs', 'base': 0, 'instr': [
        ('copy', 0, 0x10000),            # the implicit length
        ('copy', 0x10000, len(BIG) - 0x10000 - 16),
        ('insert', b'OFS DELTA TAIL..'),
    ]},
    {'how': 'ref', 'base': 1, 'instr': [
        ('copy', 0, 1000),
        ('insert', b'REF DELTA, on a base that is itself a delta'),
        ('copy', 2000, 3000),
    ]},
]

if __name__ == '__main__':
    kind = sys.argv[1]
    if kind == 'fuzz':
        # One flipped bit each, anywhere in the entry area, with both
        # checksums and every CRC recomputed afterwards so the flip is the
        # only lie and the parser is what has to deal with it. Without the
        # recomputation every mutant is refused by the checksum and the
        # fuzzer never reaches a single length field.
        import os
        import random
        outdir, count = sys.argv[2], int(sys.argv[3])
        os.makedirs(outdir, exist_ok=True)
        rnd = random.Random(20261105)
        base = build([dict(e) for e in SPEC], 'ok')[0]
        for i in range(count):
            at = rnd.randrange(12, len(base) - 20)
            pk, ix = build([dict(e) for e in SPEC], 'ok',
                           flip=(at, 1 << rnd.randrange(8)))
            open('%s/pack-f%d.pack' % (outdir, i), 'wb').write(pk)
            open('%s/pack-f%d.idx' % (outdir, i), 'wb').write(ix)
        raise SystemExit(0)
    outpack, outidx = sys.argv[2], sys.argv[3]
    spec = [dict(e) for e in (SPEC_FWD if kind == 'reffwd' else SPEC)]
    if kind == 'basesize':
        spec[1]['base_size'] = len(BIG) + 1
    elif kind == 'ressize':
        spec[1]['res_size'] = 99          # a copy overruns it
    elif kind == 'ressize_ins':
        spec[1]['instr'] = [('insert', b'OFS DELTA TAIL..')]
        spec[1]['res_size'] = 4           # an insert overruns it
    elif kind == 'ressize_long':
        spec[1]['res_size'] = 70000 + 100  # nothing overruns it and it is
                                           # still not what came out
    elif kind == 'bigres':
        spec[1]['res_size'] = (256 << 20) + 1
    elif kind == 'instr0':
        spec[1]['instr'] = spec[1]['instr'] + [('raw', b'\0')]
    elif kind == 'copyout':
        spec[1]['instr'] = [('copy', len(BIG) - 8, 16)]
    elif kind not in ('ok', 'reffwd', 'wrongname', 'trunc', 'bigsize',
                      'ofszero', 'ofspast', 'refself'):
        raise SystemExit('unknown pack fixture ' + kind)
    pack, idx = build(spec, kind)
    open(outpack, 'wb').write(pack)
    open(outidx, 'wb').write(idx)
PYGEN

PG=$TMP/packs/gen
mkdir -p "$PG"
python3 "$TMP/packgen.py" ok "$PG/pack-g.pack" "$PG/pack-g.idx"
assert "git verify-pack accepts the hand-built pack" \
	$GIT -C "$SCRATCH" verify-pack "$PG/pack-g.idx"
rm -f "$PG/re.idx"
cp "$PG/pack-g.pack" "$PG/re.pack"
if $GIT -C "$SCRATCH" index-pack -o "$PG/re.idx" "$PG/re.pack" > /dev/null 2>&1; then
	assert "and git index-pack rebuilds its index byte for byte" \
		cmp -s "$PG/re.idx" "$PG/pack-g.idx"
else
	no "git index-pack could not index the hand-built pack"
fi
packls_vs_vpv "packls gen" "$PG/pack-g.idx"
# Three entries: a 70000-byte blob, an OFS_DELTA of it, and a REF_DELTA of
# THAT, so one pack holds both encodings and a base that is itself a delta.
# The first copy instruction asks for exactly 0x10000 bytes with its length
# bytes absent, which is the implicit default.
eq "the hand-built pack holds both encodings and a chain of two" \
	"$(cat "$TMP/p.census")" \
	"3 objects, 1 read whole, 2 through a delta chain, deepest chain 2, 2 ofs-delta and 1 ref-delta links, 5 inflations and 1 base-cache hits"
# git on the far side of the chain: a repository whose only object source is
# this pack, read by git.
GREPO=$PG/repo
$GIT init -q --bare "$GREPO"
cpw "$PG/pack-g.pack" "$GREPO/objects/pack/pack-g.pack"
cpw "$PG/pack-g.idx" "$GREPO/objects/pack/pack-g.idx"
eq "git lists all three objects of the hand-built pack" \
	"$($GIT --git-dir="$GREPO" cat-file --batch-all-objects --batch-check | wc -l | tr -d ' ')" 3
gblob=$("$GITOBJ" packls "$PG/pack-g.idx" 2>/dev/null | awk 'NR==3{print $1}')
"$GITOBJ" raw "$GREPO/objects" "$gblob" > "$TMP/ours" 2>/dev/null
$GIT --git-dir="$GREPO" cat-file blob "$gblob" > "$TMP/theirs"
assert "and hands back the same bytes we do for the end of the chain" \
	cmp -s "$TMP/ours" "$TMP/theirs"
$GIT --git-dir="$GREPO" fsck > "$TMP/fsck.out" 2>&1
assert "git fsck is clean over the hand-built pack" sh -c \
	"! grep -Eiv '^(notice|dangling)' '$TMP/fsck.out' | grep -q ."

# A REF_DELTA that comes BEFORE its base, which no OFS_DELTA can be and
# which nothing git packs here is. It is the only shape in which an object is
# asked for by name after having already been read as another object's base,
# and so the only one that can tell whether the base cache answers for the
# object asked for or only for bases. Serving the asked-for object out of the
# cache would make a walk over a pack answer out of itself, and `packverify`
# would then be hashing the cache.
python3 "$TMP/packgen.py" reffwd "$PG/pack-f.pack" "$PG/pack-f.idx"
assert "git verify-pack accepts a REF_DELTA that precedes its base" \
	$GIT -C "$SCRATCH" verify-pack "$PG/pack-f.idx"
packls_vs_vpv "packls reffwd" "$PG/pack-f.idx"
eq "and reading it inflates both entries rather than one and a cache hit" \
	"$(cat "$TMP/p.census")" \
	"2 objects, 1 read whole, 1 through a delta chain, deepest chain 1, 0 ofs-delta and 1 ref-delta links, 3 inflations and 0 base-cache hits"

# One lie each, and git must call each one a lie too. The message is
# asserted, not only the status: every one of these refusals would otherwise
# be indistinguishable from the next.
gen_refuse() { # <kind> <what it is> <expected message, an extended regex>
	rm -rf "$PG/$1"
	mkdir -p "$PG/$1"
	python3 "$TMP/packgen.py" "$1" "$PG/$1/pack-g.pack" "$PG/$1/pack-g.idx" || {
		no "could not build the $1 fixture"
		return
	}
	refute "packls refuses $2" "$GITOBJ" packls "$PG/$1/pack-g.idx"
	assert "and names the rule and the place: $2" sh -c \
		"'$GITOBJ' packls '$PG/$1/pack-g.idx' 2>&1 >/dev/null | grep -Eq '$3'"
	assert "git verify-pack refuses $2 too" sh -c \
		"! $GIT -C '$SCRATCH' verify-pack '$PG/$1/pack-g.idx' >/dev/null 2>&1"
}
gen_refuse basesize "a delta whose declared base size is not the base's" \
	'delta base size disagrees with the base object at [0-9]+'
gen_refuse ressize "a delta that writes past its own declared result size" \
	'delta writes past the result size it declares at [0-9]+'
gen_refuse ressize_ins "a delta whose INSERT overruns its declared result" \
	'delta writes past the result size it declares at [0-9]+'
gen_refuse ressize_long "a delta that produces less than its declared result" \
	'delta result is not the size the delta declares at [0-9]+'
gen_refuse bigres "a delta result size above OBJ_MAX" \
	'delta header declares a size above OBJ_MAX at [0-9]+'
gen_refuse bigsize "an entry size above OBJ_MAX" \
	'pack entry declares a size above OBJ_MAX at [0-9]+'
gen_refuse instr0 "a delta instruction byte of 0" \
	'delta instruction 0 is not an instruction at [0-9]+'
gen_refuse copyout "a copy instruction reaching past the end of the base" \
	'delta copies from outside the base object at [0-9]+'
gen_refuse ofszero "an OFS_DELTA at a distance of zero, naming itself" \
	'OFS_DELTA base offset is outside the pack at [0-9]+'
gen_refuse ofspast "an OFS_DELTA whose base is before the pack header" \
	'OFS_DELTA base offset is outside the pack at [0-9]+'
gen_refuse refself "a REF_DELTA naming itself, which is a cycle" \
	'delta chain is deeper than gitobj will follow at [0-9]+'
gen_refuse trunc "a pack cut off in the middle of its last entry" \
	'gitobj: .* at [0-9]+'
# The last one is the only refusal here whose message is not pinned to a
# rule: a truncated zlib stream fails wherever the decoder happens to run
# out, and which error that is depends on the bytes. What is asserted is
# that it refuses, says where, and is not a crash.

# One flipped bit at a time, over the whole entry area, with both checksums
# and every CRC recomputed so the flip is the only lie. Two things are
# asserted per mutant. That gitobj never does anything but succeed or refuse
# cleanly, which is what `refute`'s insistence on exit 1 exists for: a
# segfault counted as a refusal in all 15 refusal assertions here once. And
# that gitobj and git agree about whether the pack is still readable, which
# is a differential comparison rather than an opinion: `packverify` hashes
# every object back to its name, so it answers the same question
# `git verify-pack` does.
FZ=$PG/fz
FZN=300
python3 "$TMP/packgen.py" fuzz "$FZ" "$FZN"
fz_ref=0
fz_ok=0
i=0
: > "$TMP/fz.msgs"
while [ "$i" -lt "$FZN" ]; do
	"$GITOBJ" packverify "$FZ/pack-f$i.idx" 2>> "$TMP/fz.msgs" > /dev/null
	rc=$?
	$GIT -C "$SCRATCH" verify-pack "$FZ/pack-f$i.idx" > /dev/null 2>&1
	grc=$?
	case $rc in
	0) fz_ok=$((fz_ok + 1)); eq "fuzz $i: git agrees the pack is readable" "$grc" 0 ;;
	1) fz_ref=$((fz_ref + 1))
	   if [ "$grc" -ne 0 ]; then ok; else no "fuzz $i: we refuse a pack git reads"; fi ;;
	*) no "fuzz $i: exit $rc, not a clean refusal" ;;
	esac
	i=$((i + 1))
done
# A fuzzer whose mutants are all refused by one early check has tested that
# check and nothing else, and one whose mutants are all accepted has tested
# nothing at all. Both ends are asserted.
[ "$fz_ref" -ge 20 ] && ok || no "only $fz_ref of $FZN fuzzed packs were refused"
[ "$fz_ok" -ge 1 ] && ok || no "every one of the $FZN fuzzed packs was refused"
# And how many different things they were refused FOR, which is the part the
# counts cannot show: most of a pack is zlib stream, so most flips land
# there and are caught by the Adler-32, and a fuzzer that only ever reaches
# that one check has tested one check.
fz_kinds=$(sed 's/ at [0-9]*$//' "$TMP/fz.msgs" | sort -u | grep -c .)
[ "$fz_kinds" -ge 5 ] && ok ||
	no "the fuzzed packs were refused for only $fz_kinds distinct reasons"
printf 'pack fuzz: %d mutants, %d refused for %d distinct reasons, %d still readable, all agreeing with git\n' \
	"$FZN" "$fz_ref" "$fz_kinds" "$fz_ok"

# The guard against every comparison against verify-pack -v passing
# vacuously, counted over every pack the two sections above read. A
# standalone clone gets its deltas and its chain depth from the corpora the
# suite builds; in the collection the siblings add a few thousand more.
[ "$pls_delta" -ge 150 ] && ok ||
	no "only $pls_delta delta entries were read through verify-pack -v"
[ "$pls_depth" -ge 5 ] && ok ||
	no "the deepest chain read was only $pls_depth"
printf 'packls: %d objects against verify-pack -v, %d of them deltas, deepest chain %d\n' \
	"$pls_objs" "$pls_delta" "$pls_depth"
printf 'base cache: %d inflations and %d hits, against %d inflations with no cache\n' \
	"$pls_inf" "$pls_hit" "$pls_nocache"

# =====================================================================
# 11. alternates: an object store that borrows another one
# =====================================================================
# `objects/info/alternates` lists other object directories to look in, one
# per line. It is what `git clone -s` writes and what most CI caches look
# like, and an object in an alternate is in the repository as far as every
# git command is concerned, `cat-file --batch-all-objects` included. A reader
# that ignores the file reports "object not found" for a repository git reads
# perfectly, which is what this one did.
#
# The oracle is the same one section 3 uses, over a store whose objects are
# all somebody else's: `git cat-file --batch-all-objects --batch-check`
# against `gitobj ls`, line for line.
ALTD=$TMP/alt
mkdir -p "$ALTD"
alt_vs_git() { # <label> <git-dir> <expected object count>
	# git's stderr is kept rather than discarded: for one of the fixtures
	# below it is the oracle, since git complains about an alternate it
	# cannot use and carries on, which is the behaviour being matched.
	$GIT --git-dir="$2" cat-file --batch-all-objects --batch-check \
		2> "$TMP/a.giterr" | sort > "$TMP/a.theirs"
	"$GITOBJ" ls "$2/objects" > "$TMP/a.ours" 2> "$TMP/a.census"
	eq "$1: ls exits 0" "$?" 0
	eq "$1: git finds the objects the alternate holds" \
		"$(wc -l < "$TMP/a.theirs" | tr -d ' ')" "$3"
	assert "$1: and we list exactly what git lists" \
		cmp -s "$TMP/a.ours" "$TMP/a.theirs"
	eq "$1: and verify hashes every one of them" \
		"$("$GITOBJ" verify "$2/objects" 2>/dev/null)" "$3 objects, 0 mismatched"
}

# The real shape first, both ways round: a loose source and a packed one.
# `git clone -s` is what writes the file, so the fixture is git's own doing
# rather than a line this suite composed.
for src in self_a self_p; do
	rm -rf "$ALTD/$src"
	$GIT clone -q -s --bare "$TMP/corpus/$src" "$ALTD/$src" 2>/dev/null
	assert "clone -s wrote an alternates file for $src" \
		test -s "$ALTD/$src/objects/info/alternates"
	# The borrowing store has nothing of its own: that is the whole point,
	# and without checking it the comparison could be passing on a copy.
	eq "and the clone of $src has no object of its own" \
		"$(loose_shas "$ALTD/$src" | grep -c .)" 0
	eq "nor a pack of its own" \
		"$(ls "$ALTD/$src/objects/pack/"*.idx 2>/dev/null | grep -c .)" 0
	alt_vs_git "alternates ($src)" "$ALTD/$src" "$NSELF"
	# One object, read through the alternate, against git.
	asha=$(head -1 "$TMP/a.theirs" | cut -d' ' -f1)
	eq "a single object read through the alternate of $src" \
		"$("$GITOBJ" type "$ALTD/$src/objects" "$asha")" \
		"$($GIT --git-dir="$ALTD/$src" cat-file -t "$asha")"
	"$GITOBJ" raw "$ALTD/$src/objects" "$asha" > "$TMP/ours" 2>/dev/null
	$GIT --git-dir="$ALTD/$src" cat-file "$("$GITOBJ" type "$ALTD/$src/objects" "$asha")" \
		"$asha" > "$TMP/theirs"
	assert "and byte for byte" cmp -s "$TMP/ours" "$TMP/theirs"
done
# Two directories, which is what the census has to say, and it is the guard
# against the above passing because the objects were there all along.
eq "the store that borrows reports both directories" \
	"$(sed 's/.*, //' "$TMP/a.census")" "2 object directories"

# A relative path, which is relative to the objects directory holding the
# file and not to the current directory. git writes an absolute path, so
# this form only appears when somebody writes it by hand, and it is the one
# a reader is most likely to resolve against the wrong thing.
rm -rf "$ALTD/rel"
$GIT init -q --bare "$ALTD/rel"
printf '../../../corpus/self_a/objects\n' > "$ALTD/rel/objects/info/alternates"
alt_vs_git "alternates (relative path)" "$ALTD/rel" "$NSELF"

# A chain: this store borrows one that borrows another. git follows those
# too, to a depth of five.
rm -rf "$ALTD/chain"
$GIT init -q --bare "$ALTD/chain"
printf '%s\n' "$ALTD/rel/objects" > "$ALTD/chain/objects/info/alternates"
alt_vs_git "alternates (a chain of three)" "$ALTD/chain" "$NSELF"

# A cycle. There is no object here that is not reachable anyway, so what is
# asserted is that it terminates and still answers: a reader that follows
# the file without a guard does not come back.
rm -rf "$ALTD/loop" "$ALTD/loop2"
$GIT init -q --bare "$ALTD/loop"
$GIT init -q --bare "$ALTD/loop2"
printf '%s\n' "$ALTD/loop2/objects" > "$ALTD/loop/objects/info/alternates"
printf '%s\n%s\n' "$ALTD/loop/objects" "$TMP/corpus/self_a/objects" \
	> "$ALTD/loop2/objects/info/alternates"
alt_vs_git "alternates (a cycle)" "$ALTD/loop" "$NSELF"

# The same cycle spelled with relative paths, which is the one the
# de-duplication cannot see: each hop appends to the path, so no two strings
# are ever equal and only the depth limit ends it. There is a real alternate
# in the first file as well, so the walk still has to come back with the
# objects rather than merely survive.
rm -rf "$ALTD/rloop" "$ALTD/rloop2"
$GIT init -q --bare "$ALTD/rloop"
$GIT init -q --bare "$ALTD/rloop2"
printf '../../rloop2/objects\n%s\n' "$TMP/corpus/self_a/objects" \
	> "$ALTD/rloop/objects/info/alternates"
printf '../../rloop/objects\n' > "$ALTD/rloop2/objects/info/alternates"
alt_vs_git "alternates (a cycle spelled two ways)" "$ALTD/rloop" "$NSELF"

# Lines git ignores, and a directory that is not there. git treats the file
# as a hint about where objects might be, so a stale entry is skipped rather
# than refused, and an empty store with a bad alternate is empty rather than
# broken.
rm -rf "$ALTD/junk"
$GIT init -q --bare "$ALTD/junk"
printf '# a comment\n\n%s/no/such/dir\n%s\n' "$ALTD" "$TMP/corpus/self_a/objects" \
	> "$ALTD/junk/objects/info/alternates"
alt_vs_git "alternates (comments and a missing directory)" "$ALTD/junk" "$NSELF"
assert "git complains about the directory that is not there and carries on" \
	grep -q 'no/such/dir' "$TMP/a.giterr"
rm -rf "$ALTD/gone"
$GIT init -q --bare "$ALTD/gone"
printf '%s/no/such/dir\n' "$ALTD" > "$ALTD/gone/objects/info/alternates"
eq "an alternate that is not there leaves an empty store empty" \
	"$("$GITOBJ" verify "$ALTD/gone/objects" 2>/dev/null)" "0 objects, 0 mismatched"
refute "and an object is still not found in it" \
	"$GITOBJ" type "$ALTD/gone/objects" \
	0000000000000000000000000000000000000000

# =====================================================================
# 12. abbreviated object names
# =====================================================================
# Every human-facing git command takes a 7-character prefix, and the rule
# that goes with it is that a prefix matching two objects is an error rather
# than a choice. `git rev-parse` is the oracle and it is the right one: it
# does the same lookup and nothing else.
#
# git's own minimum is four characters. An odd number of them is fine, since
# this is a prefix of the NAME and not of the bytes.
abb_ok=0
abb_amb=0
for r in $HAVE_SMALL; do
	G="$TMP/corpus/$r"
	OD="$G/objects"
	while read -r sha gt gsz; do
		# 7 characters, which is git's default abbreviation. Compared
		# against whatever git says rather than against success: a prefix
		# this short can collide, and then both of us have to refuse.
		pre=${sha:0:7}
		if want=$($GIT --git-dir="$G" rev-parse --verify "$pre" 2>/dev/null); then
			eq "name $r/$pre" "$("$GITOBJ" name "$OD" "$pre" 2>/dev/null)" "$want"
			abb_ok=$((abb_ok + 1))
		else
			refute "name $r/$pre is refused, as git refuses it" \
				"$GITOBJ" name "$OD" "$pre"
			abb_amb=$((abb_amb + 1))
		fi
	done < "$TMP/corpus-all.$r"
done
[ "$abb_ok" -ge 300 ] && ok || no "only $abb_ok prefixes resolved"
printf 'abbreviated names: %d of 7 characters resolved, %d refused\n' \
	"$abb_ok" "$abb_amb"

# Four characters, where an ambiguous prefix can be had. A store of its own
# for it, because the corpus cannot be relied on to provide one: 3061
# objects over 65536 buckets collide readily and 123 do not, so in a clone
# with no siblings the ambiguity path went untested and said so. 600 blobs
# of fixed content give two colliding prefixes, bc98 and bfae, and they are
# the same two on every run because the content decides the names.
AMB=$TMP/ambig
rm -rf "$AMB" "$TMP/mk/ambig"
mkdir -p "$TMP/mk/ambig"
$GIT init -q --bare "$AMB"
i=0
: > "$TMP/mk/ambig/paths"
while [ "$i" -lt 600 ]; do
	printf 'ambiguity probe %d\n' "$i" > "$TMP/mk/ambig/b$i"
	echo "$TMP/mk/ambig/b$i" >> "$TMP/mk/ambig/paths"
	i=$((i+1))
done
$GIT --git-dir="$AMB" hash-object -w --stdin-paths \
	< "$TMP/mk/ambig/paths" > /dev/null
$GIT --git-dir="$AMB" cat-file --batch-all-objects --batch-check |
	sort > "$TMP/corpus-all.ambig"
abb4_ok=0
abb4_amb=0
# Both halves come from GIT's listing, so which prefixes are ambiguous is
# git's account of the store and not ours.
for r in ambig $HAVE_SMALL; do
	case $r in
	ambig) G="$AMB" ;;
	*)     G="$TMP/corpus/$r" ;;
	esac
	OD="$G/objects"
	awk '{print substr($1,1,4)}' "$TMP/corpus-all.$r" | sort > "$TMP/abb4"
	for pre in $(uniq -d "$TMP/abb4" | head -4); do
		refute "a 4-character prefix matching two objects is refused: $r/$pre" \
			"$GITOBJ" name "$OD" "$pre"
		assert "and says it is ambiguous rather than absent: $r/$pre" sh -c \
			"'$GITOBJ' name '$OD' '$pre' 2>&1 | grep -q ambiguous"
		assert "git refuses it too: $r/$pre" sh -c \
			"! $GIT --git-dir='$G' rev-parse --verify '$pre' >/dev/null 2>&1"
		abb4_amb=$((abb4_amb + 1))
	done
	for pre in $(uniq -u "$TMP/abb4" | head -4); do
		eq "a 4-character prefix matching one object resolves: $r/$pre" \
			"$("$GITOBJ" name "$OD" "$pre" 2>/dev/null)" \
			"$($GIT --git-dir="$G" rev-parse --verify "$pre")"
		abb4_ok=$((abb4_ok + 1))
	done
done
# Both paths have to have run. An ambiguity check that never sees an
# ambiguous prefix is the whole hazard here, and the 600-blob store above
# exists to make sure one is always there.
[ "$abb4_amb" -ge 2 ] && ok ||
	no "only $abb4_amb ambiguous 4-character prefixes, so ambiguity went untested"
[ "$abb4_ok" -ge 4 ] && ok || no "only $abb4_ok unambiguous 4-character prefixes"
# A prefix one character longer than an ambiguous one has to resolve: that
# is the difference between a lookup that compares the prefix it was given
# and one that compares something else.
amb1=$(uniq -d < <(awk '{print substr($1,1,4)}' "$TMP/corpus-all.ambig" | sort) | head -1)
for full in $(awk -v p="$amb1" 'substr($1,1,4)==p{print $1}' "$TMP/corpus-all.ambig"); do
	eq "and one character more resolves it: ${full:0:5}" \
		"$("$GITOBJ" name "$AMB/objects" "${full:0:5}" 2>/dev/null)" "$full"
done
printf 'four-character prefixes: %d resolved, %d ambiguous\n' "$abb4_ok" "$abb4_amb"

# An odd number of characters, a full name, and the lookup reaching through
# to the object rather than stopping at its name.
SOD=$TMP/corpus/self_a/objects
SG="$GIT --git-dir=$TMP/corpus/self_a"
ssha=$(head -1 "$TMP/corpus-all.self_a" | cut -d' ' -f1)
for k in 4 5 7 11 39 40; do
	eq "a prefix of $k characters resolves" \
		"$("$GITOBJ" name "$SOD" "${ssha:0:$k}" 2>/dev/null)" "$ssha"
done
eq "and cat-file through a prefix agrees with git" \
	"$("$GITOBJ" type "$SOD" "${ssha:0:7}")" \
	"$($SG cat-file -t "$ssha")"
eq "and so does size" \
	"$("$GITOBJ" size "$SOD" "${ssha:0:7}")" \
	"$($SG cat-file -s "$ssha")"
"$GITOBJ" raw "$SOD" "${ssha:0:7}" > "$TMP/ours" 2>/dev/null
$SG cat-file "$($SG cat-file -t "$ssha")" "$ssha" > "$TMP/theirs"
assert "and raw bytes through a prefix are the same bytes" \
	cmp -s "$TMP/ours" "$TMP/theirs"

# Refusals. Three characters is below git's minimum; git calls it ambiguous,
# we call it too short, and both refuse, which is the part that matters.
refute "a prefix of 3 characters is refused" \
	"$GITOBJ" name "$SOD" "${ssha:0:3}"
assert "git refuses 3 characters too" sh -c \
	"! $SG rev-parse --verify '${ssha:0:3}' >/dev/null 2>&1"
# And a 3-character prefix that matches exactly ONE object, so that the
# length is the only possible reason to refuse it. Without this the rule
# passes on prefixes that would have been ambiguous anyway.
uniq3=$(awk '{print substr($1,1,3)}' "$TMP/corpus-all.self_a" | sort | uniq -u | head -1)
assert "the corpus has a 3-character prefix matching exactly one object" \
	test -n "$uniq3"
refute "which is still refused, for its length alone" \
	"$GITOBJ" name "$SOD" "$uniq3"
assert "and git refuses that one too" sh -c \
	"! $SG rev-parse --verify '$uniq3' >/dev/null 2>&1"
refute "a prefix that is not hex is refused" "$GITOBJ" name "$SOD" zzzz
refute "a prefix matching nothing is refused" \
	"$GITOBJ" name "$SOD" ffffffffff
assert "and says not found rather than ambiguous" sh -c \
	"'$GITOBJ' name '$SOD' ffffffffff 2>&1 | grep -q 'not found'"
refute "a 41-character name is refused" \
	"$GITOBJ" name "$SOD" "${ssha}0"
refute "and so is a prefix of a name nothing holds, through cat" \
	"$GITOBJ" cat "$SOD" ffffffffff

# =====================================================================
# 13. unpack: a pack read out into loose objects, which git then reads
# =====================================================================
# This is the two halves of the program meeting. The pack reader produces
# the bytes, the loose writer files them, and `git unpack-objects` does the
# same job from the same pack, so the two stores can be compared whole.
#
# The name is recomputed from what came out of the pack rather than copied
# from the index: a writer handed the name it is meant to produce cannot be
# caught producing another. An object whose name does not check out is
# reported and not written.
UP=$TMP/unpack
unpack_vs_git() { # <label> <idx> <count>
	local ours theirs
	rm -rf "$UP"
	mkdir -p "$UP"
	ours=$UP/ours
	theirs=$UP/theirs
	$GIT init -q --bare "$ours"
	$GIT init -q --bare "$theirs"
	# Both targets start empty, which is what makes "the object is there"
	# mean "we put it there": a write test can pass by finding its object
	# already present.
	eq "$1: the target starts empty" \
		"$($GIT --git-dir="$ours" cat-file --batch-all-objects --batch-check |
			wc -l | tr -d ' ')" 0
	eq "$1: unpack writes every object of the pack" \
		"$("$GITOBJ" unpack "$2" "$ours/objects" 2>/dev/null)" \
		"$3 objects written, 0 mismatched"
	$GIT --git-dir="$theirs" unpack-objects < "${2%.idx}.pack" > /dev/null 2>&1
	eq "$1: git unpack-objects writes the same number" \
		"$($GIT --git-dir="$theirs" cat-file --batch-all-objects --batch-check |
			wc -l | tr -d ' ')" "$3"
	$GIT --git-dir="$ours" cat-file --batch-all-objects --batch-check |
		sort > "$TMP/u.ours"
	$GIT --git-dir="$theirs" cat-file --batch-all-objects --batch-check |
		sort > "$TMP/u.theirs"
	local a b
	while IFS= read -r a <&3 && IFS= read -r b <&4; do
		eq "$1 ${b%% *}" "$a" "$b"
	done 3< "$TMP/u.ours" 4< "$TMP/u.theirs"
	# fsck --strict is the half that matters: it inflates every loose
	# object we wrote, re-hashes it against the name we filed it under, and
	# parses the trees and commits.
	$GIT --git-dir="$ours" fsck --strict > "$TMP/u.fsck" 2>&1
	assert "$1: git fsck --strict is clean over what we unpacked" sh -c \
		"! grep -Eiv '^(notice|dangling)' '$TMP/u.fsck' | grep -q ."
	# And the loose store reads back as the pack did, object for object,
	# which is the third hop: pack to loose to git.
	local nchk=0
	while read -r sha gt gsz; do
		nchk=$((nchk + 1))
		eq "$1 cat-file -p $sha" \
			"$($GIT --git-dir="$ours" cat-file -p "$sha" | cksum)" \
			"$($GIT --git-dir="$theirs" cat-file -p "$sha" | cksum)"
	done < "$TMP/u.theirs"
	[ "$nchk" -eq "$3" ] && ok || no "$1: compared $nchk of $3 objects"
}
unpack_vs_git "unpack dd" "$DIDX" "$NDOBJ"
unpack_vs_git "unpack rd" "$RDIDX" "$NDOBJ"
unpack_vs_git "unpack self" "$SELFIDX" "$NSELF"
unpack_vs_git "unpack by hand" "$PG/pack-g.idx" 3

# A pack whose bytes are not what its index says they are. Nothing is
# written: the one thing worse than refusing to unpack a pack is filing an
# object under a name that is not its hash.
rm -rf "$PG/wrongname"
mkdir -p "$PG/wrongname"
python3 "$TMP/packgen.py" wrongname "$PG/wrongname/pack-w.pack" \
	"$PG/wrongname/pack-w.idx"
rm -rf "$UP/bad"
$GIT init -q --bare "$UP/bad"
refute "unpack refuses a pack whose objects do not hash to their names" \
	"$GITOBJ" unpack "$PG/wrongname/pack-w.idx" "$UP/bad/objects"
eq "and writes none of them" \
	"$(loose_shas "$UP/bad" | grep -c .)" 0
assert "and names the object the index is wrong about" sh -c \
	"'$GITOBJ' unpack '$PG/wrongname/pack-w.idx' '$UP/bad/objects' 2>/dev/null |
		grep -q '^MISMATCH [0-9a-f]\{40\} hashes to [0-9a-f]\{40\}$'"
assert "git verify-pack refuses it too" sh -c \
	"! $GIT -C '$SCRATCH' verify-pack '$PG/wrongname/pack-w.idx' >/dev/null 2>&1"
refute "packverify refuses it as well" \
	"$GITOBJ" packverify "$PG/wrongname/pack-w.idx"


# =====================================================================
# 14. writing a pack: git's own index of our pack, byte for byte
# =====================================================================
# Reading a pack has one oracle and writing one has two, the second being
# the sharper. `git index-pack -o` builds an index FROM our pack with no
# sight of the index we wrote beside it, and the two files have to be the
# same bytes: the fanout, the name order, every CRC, every offset, the copy
# of the pack checksum and the index's own. git computing all of that from
# our pack is not a comparison we are on both sides of.
#
# `git index-pack` was checked first against a pack git wrote itself:
# re-indexing one of `pack-objects`'s packs reproduces its `.idx` byte for
# byte, so the comparison below is a test of our index and not a statement
# about how reproducible git's indexer is.
#
# Then the pack goes into a bare repository whose only object source is that
# pack, and git is asked for every object in it. `fsck --strict` inflates
# every entry, walks every delta chain and re-hashes the result against the
# name the index files it under, which is the hard invariant from git's side
# of it.
PW=$TMP/packwrite
mkdir -p "$PW"
PWN=0
pw_objs=0
pw_delta=0
pw_depth=0

# <label> <source bare repo> <names file> <count> <window> <least deltas>
pack_vs_git() {
	local label=$1 src=$2 names=$3 count=$4 win=$5 mind=$6
	local d sha gd gm nd rc
	PWN=$((PWN + 1))
	d=$PW/w$PWN
	mkdir -p "$d"
	sha=$("$GITOBJ" pack "$src/objects" "$d/ours" "$win" < "$names" 2> "$d/census")
	rc=$?
	eq "$label: pack exits 0" "$rc" 0
	pw_census=$d/census
	assert "$label: both files were written" test -f "$d/ours.pack" -a -f "$d/ours.idx"
	eq "$label: the checksum printed is forty hex characters" \
		"$(printf '%s\n' "$sha" | grep -c '^[0-9a-f]\{40\}$')" 1
	# The trailing checksum IS the pack's name, and index-pack prints what
	# it computed over the file it read.
	eq "$label: git's name for our pack is the checksum we printed" \
		"$($GIT -C "$SCRATCH" index-pack -o "$d/git.idx" "$d/ours.pack")" "$sha"
	assert "$label: git's index of our pack is byte-identical to ours" \
		cmp -s "$d/git.idx" "$d/ours.idx"
	assert "$label: git verify-pack accepts it" \
		$GIT -C "$SCRATCH" verify-pack "$d/ours.idx"
	# The reader's whole oracle, turned on our own output: verify-pack -v
	# line for line, the reader's census against git's count of deltas and
	# its deepest chain, and every object hashing back to its own name.
	#
	# The pls_* counters are saved and put back because the line that
	# prints them is about the packs this suite READS, and it has already
	# been printed by the time this section runs. Adding our own packs to
	# a total nobody prints again would quietly make it mean something
	# else; section 14 keeps its own.
	local s1=$pls_objs s2=$pls_delta s3=$pls_depth s4=$pls_inf s5=$pls_hit s6=$pls_nocache
	packls_vs_vpv "$label packls" "$d/ours.idx"
	pw_objs=$((pw_objs + pls_objs - s1))
	pw_delta=$((pw_delta + pls_delta - s2))
	pls_objs=$s1; pls_delta=$s2; pls_depth=$s3
	pls_inf=$s4; pls_hit=$s5; pls_nocache=$s6
	# What the writer said it wrote, against what git reads back out of the
	# file. A writer's own account of its output is not evidence. The depth
	# comes from git's sixth column rather than from pls_depth, which is
	# the running maximum over every pack this suite has read and would
	# hand back 29 from a sibling repository for a pack of ours holding no
	# delta at all.
	gd=$($GIT -C "$SCRATCH" verify-pack -v "$d/ours.idx" |
		awk '$1 ~ /^[0-9a-f]{40}$/ && NF >= 7' | grep -c .)
	gm=$($GIT -C "$SCRATCH" verify-pack -v "$d/ours.idx" |
		awk '$1 ~ /^[0-9a-f]{40}$/ && NF >= 7 {if ($6 > m) m = $6} END {print m + 0}')
	[ "$gm" -gt "$pw_depth" ] && pw_depth=$gm
	nd=$(sed -n 's/.*, \([0-9]*\) as ofs-delta.*/\1/p' "$d/census")
	eq "$label: the writer's delta count is what git counts in the file" "$nd" "$gd"
	eq "$label: and it packed every name it was given" \
		"$(sed -n 's/^\([0-9]*\) objects.*/\1/p' "$d/census")" "$count"
	if [ "$nd" -ge "$mind" ]; then ok
	else no "$label: wrote $nd delta entries, wanted at least $mind"; fi
	# A repository whose only object source is the pack we wrote.
	rm -rf "$d/repo"
	$GIT init -q --bare "$d/repo"
	cpw "$d/ours.pack" "$d/repo/objects/pack/pack-$sha.pack"
	cpw "$d/ours.idx" "$d/repo/objects/pack/pack-$sha.idx"
	eq "$label: git finds every object in it" \
		"$($GIT --git-dir="$d/repo" cat-file --batch-all-objects --batch-check |
			wc -l | tr -d ' ')" "$count"
	$GIT --git-dir="$d/repo" fsck --strict > "$d/fsck" 2>&1
	assert "$label: git fsck --strict is clean over it" sh -c \
		"! grep -Eiv '^(notice|dangling)' '$d/fsck' | grep -q ."
	# Object for object against the repository the objects came out of, so a
	# disagreement names the object rather than the pack.
	$GIT --git-dir="$d/repo" cat-file --batch-all-objects --batch-check |
		sort > "$d/ours.list"
	local a nchk=0
	while read -r a _; do
		nchk=$((nchk + 1))
		eq "$label cat-file -p $a" \
			"$($GIT --git-dir="$d/repo" cat-file -p "$a" | cksum)" \
			"$($GIT --git-dir="$src" cat-file -p "$a" | cksum)"
	done < "$d/ours.list"
	if [ "$nchk" -eq "$count" ]; then ok
	else no "$label: compared $nchk of $count objects"; fi
	# Deterministic, which is what makes any assertion above possible: git's
	# own delta search is threaded and gave 76 delta entries one run and 75
	# the next over the same objects, which is why every fixture here passes
	# --threads=1. The bytes are compared, not a report about them.
	"$GITOBJ" pack "$src/objects" "$d/again" "$win" < "$names" > /dev/null 2>&1
	assert "$label: the same objects and window give the same pack bytes" \
		cmp -s "$d/ours.pack" "$d/again.pack"
	assert "$label: and the same index bytes" cmp -s "$d/ours.idx" "$d/again.idx"
	# Pack order is computed from the objects, so the order the names
	# arrived in is not part of the answer. Without this the determinism
	# check above passes for a writer that simply echoes its input order,
	# and the delta search would then depend on how the caller sorted.
	sort -r "$names" | "$GITOBJ" pack "$src/objects" "$d/rev" "$win" \
		> /dev/null 2>&1
	assert "$label: the order the names arrived in does not change the pack" \
		cmp -s "$d/ours.pack" "$d/rev.pack"
}

# A number out of the writer's census line.
pw_num() { sed -n "s/$1/\1/p" "$pw_census"; }

# The premise of the comparison, checked rather than asserted in prose: git
# re-indexing a pack IT wrote reproduces that pack's own .idx byte for byte.
# Without this, an index of ours that differed from git's would be an open
# question between the two files, and the delta pack is the one to do it on
# since the offsets and CRCs it carries are not the trivial ones.
$GIT -C "$SCRATCH" index-pack -o "$PW/regen.idx" "${DIDX%.idx}.pack" > /dev/null
assert "git re-indexing its own pack reproduces its index byte for byte" \
	cmp -s "$PW/regen.idx" "$DIDX"

# Window 0 first, where every object is stored whole: the entry header, the
# index and the trailer with the delta encoder switched off entirely.
pack_vs_git "pack whole" "$DREPO" "$TMP/packs/din" "$NDOBJ" 0 0
eq "the window-0 pack holds no delta at all" \
	"$(pw_num '.*, \([0-9]*\) as ofs-delta.*')" 0
eq "and no copy or insert instruction was emitted for it" \
	"$(pw_num '.*, \([0-9]*\) copy and.*')" 0
whole_bytes=$(pw_num '.*, \([0-9]*\) pack bytes.*')

# Then the same objects with a window, which is the delta encoder.
pack_vs_git "pack delta" "$DREPO" "$TMP/packs/din" "$NDOBJ" 10 50
delta_bytes=$(pw_num '.*, \([0-9]*\) pack bytes.*')
wr_depth=$(pw_num '.*deepest chain \([0-9]*\).*')
wr_copy=$(pw_num '.*, \([0-9]*\) copy and.*')
wr_ins=$(pw_num '.*copy and \([0-9]*\) insert.*')
wr_64k=$(pw_num '.*, \([0-9]*\) with the length left implicit.*')
wr_offw=$(pw_num '.*widest copy offset \([0-9]*\) byte.*')
# A third, not merely smaller. "Smaller" is satisfied by a search that
# deltas whatever happens to sit next to it: packing in name order instead
# of by type and descending size still finds 79 deltas here and still comes
# out smaller than storing everything whole, at 97k against 52k, so the
# weaker bound leaves the ordering untested. The figure is reproducible
# because the corpus is fixed and this encoder is deterministic.
if [ "$((delta_bytes * 3))" -lt "$whole_bytes" ]; then ok
else no "the delta pack is $delta_bytes bytes against $whole_bytes stored whole, not under a third of it"; fi
# A delta on a delta: a writer that only ever deltas against a whole object
# produces chains of exactly one and never reaches the recursion in the
# reader, or the depth limit here.
if [ "$wr_depth" -ge 2 ] && [ "$wr_depth" -le 10 ]; then ok
else no "the deepest chain we wrote is $wr_depth, outside 2..10"; fi
# Which forms of the two instructions the encoder actually emitted. Three of
# these four are reachable only over a base big enough to need them, and the
# 0x10000 one is the implicit length that was a mutation nothing could kill
# on the reading side until this corpus grew a 20,000-line file.
if [ "$wr_copy" -gt 0 ]; then ok; else no "no copy instruction was emitted"; fi
if [ "$wr_ins" -gt 0 ]; then ok; else no "no insert instruction was emitted"; fi
if [ "$wr_64k" -gt 0 ]; then ok
else no "no copy went out with its length left implicit, so the 0x10000 default was never used"; fi
if [ "$wr_offw" -ge 3 ]; then ok
else no "the widest copy offset we emitted is $wr_offw bytes, so a multi-byte offset never went out"; fi
printf 'our delta encoder on the delta corpus: %d bytes against %d stored whole, %d bytes for git -- %d copy and %d insert instructions, %d of them with the length left implicit, widest offset %d bytes\n' \
	"$delta_bytes" "$whole_bytes" "$(wc -c < "${DIDX%.idx}.pack" | tr -d ' ')" \
	"$wr_copy" "$wr_ins" "$wr_64k" "$wr_offw"

# The self corpus as well, whose objects are a few dozen bytes each: git
# does not attempt a delta below 50 bytes and neither does this encoder once
# the saving is smaller than the entry that would carry it, so this is the
# other end of the decision rather than a second delta test.
pack_vs_git "pack self" "$SELFREPO" "$TMP/packs/in" "$NSELF" 10 0

# A pack of one object, which is where an off-by-one in the fanout or the
# offset table has nowhere to hide behind a neighbour.
printf '%s\n' "$($GIT --git-dir="$DREPO" cat-file --batch-all-objects \
	--batch-check | awk '$2=="tag"{print $1}' | head -1)" > "$PW/one"
pack_vs_git "pack one" "$DREPO" "$PW/one" 1 10 0

printf 'our packs: %d objects against verify-pack -v, %d of them deltas, deepest chain %d\n' \
	"$pw_objs" "$pw_delta" "$pw_depth"

# Abbreviated names on the way in, since `name` resolves them everywhere
# else and a writer that only took forty characters would be the odd one.
head -1 "$TMP/packs/din" | cut -c1-8 > "$PW/abbrev"
assert "pack takes an abbreviated name" sh -c \
	"'$GITOBJ' pack '$DREPO/objects' '$PW/ab' 0 < '$PW/abbrev'"
eq "and files it under its full name" \
	"$($GIT -C "$SCRATCH" verify-pack -v "$PW/ab.idx" | awk 'NR==1{print $1}')" \
	"$(head -1 "$TMP/packs/din")"

# The refusals. Each is a caller whose list was not what it thought it was.
refute "pack refuses an empty list" \
	"$GITOBJ" pack "$DREPO/objects" "$PW/empty" 10 < /dev/null
assert "and writes no pack for it" test ! -f "$PW/empty.pack"
head -1 "$TMP/packs/din" > "$PW/dup"
head -1 "$TMP/packs/din" >> "$PW/dup"
refute "pack refuses a name listed twice" \
	"$GITOBJ" pack "$DREPO/objects" "$PW/dup2" 10 < "$PW/dup"
echo 1111111111111111111111111111111111111111 > "$PW/absent"
refute "pack refuses a name the store does not hold" \
	"$GITOBJ" pack "$DREPO/objects" "$PW/absent2" 10 < "$PW/absent"
refute "pack refuses a window that is not a number" \
	sh -c "'$GITOBJ' pack '$DREPO/objects' '$PW/bw' ten < '$TMP/packs/din'"
refute "pack refuses a negative window" \
	sh -c "'$GITOBJ' pack '$DREPO/objects' '$PW/bw' -1 < '$TMP/packs/din'"
eq "pack with the wrong number of arguments is a usage error" \
	"$("$GITOBJ" pack "$DREPO/objects" "$PW/bw" > /dev/null 2>&1; echo $?)" 2
# =====================================================================
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
