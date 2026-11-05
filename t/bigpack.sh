#!/bin/bash
# A pack over two gigabytes, which is the only way git itself writes a
# 64-bit offset into an index. Everything else about the 64-bit offset table
# is tested in t/run.sh section 8, against indexes this project rewrites or
# builds by hand; what no fixture can be is an index git PRODUCED with a
# large offset in it, because that needs a pack git had a reason to put one
# in.
#
# Not part of `make test`: it writes about 5GB and takes minutes. `make
# bigpack` runs it, and the README says when it was last run and what it
# said. A target nobody runs is a claim nobody has checked, so re-run it
# rather than quoting the README.
#
# Usage: t/bigpack.sh [path-to-gitobj-binary]
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
GITOBJ=${1:-$ROOT/gitobj}
case $GITOBJ in /*) ;; *) GITOBJ="$ROOT/${GITOBJ#./}" ;; esac
GIT=${GIT:-git}
[ -x "$GITOBJ" ] || { echo "no $GITOBJ -- run make first"; exit 1; }

# Not under /tmp: that is tmpfs here and 5GB of it is not available.
WORK=${BIGPACK_DIR:-$(mktemp -d "$ROOT/t/bigpack.XXXXXX")}
trap 'rm -rf "$WORK"' EXIT INT TERM

pass=0
fail=0
ok() { pass=$((pass+1)); }
no() { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }
eq() { if [ "$2" = "$3" ]; then ok; else no "$1 (got '$2' want '$3')"; fi; }
assert() { local n=$1; shift; if "$@" >/dev/null 2>&1; then ok; else no "$n"; fi; }

# Eleven blobs of 230MB of urandom. Incompressible, so the pack keeps its
# size, and under gitobj's own OBJ_MAX of 256MB so that each object is one
# it would agree to read. Eleven of them put the last object's offset past
# 2^31, which is where the escape begins.
NBLOB=11
MB=230
G=$WORK/repo
mkdir -p "$G" "$WORK/in"
$GIT init -q --bare "$G"
printf 'building %d blobs of %dMB\n' "$NBLOB" "$MB"
: > "$WORK/paths"
i=0
while [ "$i" -lt "$NBLOB" ]; do
	dd if=/dev/urandom of="$WORK/in/b$i" bs=1M count="$MB" status=none
	echo "$WORK/in/b$i" >> "$WORK/paths"
	i=$((i+1))
done
# Level 1 throughout: the data is incompressible, so the level changes the
# size by nothing and the time by a lot.
printf 'hashing them into the repository\n'
$GIT -c core.compression=1 --git-dir="$G" hash-object -w --stdin-paths \
	< "$WORK/paths" > "$WORK/shas" || { echo "hash-object failed"; exit 1; }
rm -rf "$WORK/in"
printf 'packing\n'
# --window=0 is not a detail. With a delta window these eleven 230MB blobs
# are read into memory together to be compared, which on this machine is an
# out-of-memory kill and an empty pack name: the first run of this script
# died exactly there and said nothing, because the status of a command
# substitution was never looked at. They are urandom and would not delta
# anyway.
PK=$($GIT -c pack.compression=1 --git-dir="$G" pack-objects --non-empty \
	--window=0 --threads=1 "$WORK/pack" < "$WORK/shas") || {
	echo "pack-objects failed"
	exit 1
}
[ -n "$PK" ] || { echo "pack-objects named no pack"; exit 1; }
IDX=$WORK/pack-$PK.idx
assert "a pack was written" test -f "$IDX"
SZ=$(wc -c < "$WORK/pack-$PK.pack" | tr -d ' ')
printf 'pack is %s bytes\n' "$SZ"
if [ "$SZ" -gt 2147483648 ]; then ok
else no "the pack is $SZ bytes, under 2^31, so git had no reason to write a large offset"; fi

# git's own account of the index. An offset at or above 2^31 in it is git
# having chosen the escape, which is the one thing no fixture here can be.
$GIT show-index --object-format=sha1 < "$IDX" > "$WORK/theirs"
nbig=$(awk '$1 >= 2147483648' "$WORK/theirs" | grep -c .)
printf 'git wrote %d offsets at or above 2^31\n' "$nbig"
if [ "$nbig" -ge 1 ]; then ok
else no "git wrote no offset at or above 2^31, so the escape was not exercised"; fi

"$GITOBJ" idx "$IDX" > "$WORK/ours" 2> "$WORK/census"
eq "gitobj idx exits 0" "$?" 0
eq "same number of objects as show-index" \
	"$(wc -l < "$WORK/ours" | tr -d ' ')" "$(wc -l < "$WORK/theirs" | tr -d ' ')"
a=; b=
while IFS= read -r a <&3 && IFS= read -r b <&4; do
	eq "idx ${b#* }" "$a" "$b"
done 3< "$WORK/ours" 4< "$WORK/theirs"
# The census is the guard: a run that read every offset through the 32-bit
# entry would agree with show-index on every line and still never touch the
# table.
eq "the census says which objects came through the 64-bit table" \
	"$(cat "$WORK/census")" \
	"$NBLOB objects, $((NBLOB - nbig)) direct, $nbig via the 64-bit table of $nbig"
assert "git verify-pack accepts the pack it wrote" \
	$GIT -C "$G" verify-pack "$IDX"

# What this cannot do, said rather than skipped: the pack reader loads a
# whole pack into memory, so reading the OBJECTS of a 2.5GB pack wants 2.5GB
# of address space and a copy on top of it. The index is what this target is
# for; `idxcrc` and `packls` over this pack are not attempted.
printf 'not attempted: idxcrc and packls over a %s-byte pack, which this reader would read into memory whole\n' "$SZ"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
