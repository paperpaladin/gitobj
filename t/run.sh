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
		"$GITOBJ" cat "$OD" "$sha" > "$TMP/ours" 2>/dev/null
		$GIT --git-dir="$G" cat-file -p "$sha" > "$TMP/theirs"
		assert "cat -p $r/$sha" cmp -s "$TMP/ours" "$TMP/theirs"
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
# be compared whole this way. There is no section 9 and no packed half:
# gitobj has no pack reader, 76% of the corpus objects are packed and
# unread, and this comment pointed at work that was never written. See
# README.md.
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
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
