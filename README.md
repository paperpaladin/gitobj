# gitobj

Reads git's object database, writes loose objects into it, builds trees, reads
a packfile's v2 index, and reads the pack entries that index points at as long
as they are stored whole: one C11 file, no libgit2, no shelling out to git.
The DEFLATE decoder is vendored from the sibling `../inflate` rather than
rewritten; the writer emits zlib stored blocks, which git reads and which
compress nothing.

```
$ gitobj idx ../cc/.git/objects/pack/pack-1b962a98....idx | head -2
51370 00b08fcfd7569c4407399d58abdb585cb5b0643d (d10ec21f)
64393 00e813579e96a58252d7324af1f0e21b11249363 (0a14a8ba)
538 objects, 538 direct, 0 via the 64-bit table of 0

$ gitobj packls ../cc/.git/objects/pack/pack-1b962a98....idx
c160c3f543be8fc45799263920baf036f4e4edc7 commit 2227 1138 12
fb2f17948db733ec0a52bbe6ba0c31663ad2d24a commit 2112 1092 1150
e350bdae2c1cfe3dda02834985845838eadafed4 commit 2026 1058 2242
gitobj: pack entry is a delta, which gitobj cannot resolve yet at 50723

$ make test
sibling corpus (small): 3 of 3 present
sibling corpus (big): 5 of 5 present
per-object cat-file sweep: 369 loose objects over self_a(123) self_b(123) self_c(123)
verified 369 loose objects across self_a self_b self_c cc tarx inflate psh unrepro cmark httpd wasmi
read 9 pack indexes, 2938 objects
3050 objects read through a 32-bit offset, 134 through the 64-bit table
the delta corpus: 121 objects, 74 delta entries, deepest chain 9
5358 passed, 0 failed
```

`gitobj packls` prints the columns `git verify-pack -v` prints, padding
included, and stops at the first delta entry. git puts the whole entries
first, so over the eight sibling packs it gets 24 to 49 objects in before it
stops, out of 218 to 547. The suite does not compare it against a corpus
pack for that reason: it builds a 121-object pack with `--window=0` and
compares all of that, and has git assert that the pack really holds no delta.

`gitobj idx` prints the same three fields as `git show-index`, in the same
format, so the two can be compared object by object. The
census on the last line is on stderr, which keeps stdout byte-comparable, and
it is there because a test for the 64-bit offset table passes while reading
nothing if no object in the corpus needs one. None does: every pack here is
far under two gigabytes.

## Two numbers, and which one to quote

Cloned on its own this suite reports **2471 passed**, against four bare
repositories it builds itself. Three hold 120 blobs each through one
`hash-object --stdin-paths`, plus a tree, a commit and an annotated tag from
plumbing, at fixed dates so the object names do not move between runs. One of
those three is then packed with `git pack-objects`, so the index reader has a
pack of its own and a standalone clone exercises it.

The fourth is for the pack reader and is described under the pack walk below,
because the first three cannot do that job: their blobs are a few dozen bytes
each and git does not attempt a delta below 50 bytes, so no window setting
makes it produce one.

Inside the collection it reports more: 5358 above, because the sibling
repositories are an additional corpus, and more of them is strictly better
evidence. But that number moves every time anything is committed anywhere in
the tree, since a commit creates loose objects. It is a real count of real
comparisons and a useless figure to quote, so the collection's table quotes
2471: the one a reader gets by cloning this repository and running `make
test`.

The 134 objects that reach the 64-bit offset table are the same number in
both runs, because they come from indexes the suite builds rather than from
any corpus.

## The oracle is the object's own name

A git object's name is the SHA-1 of `<type> <len>\0<payload>`, so the name
is a checksum over the entire decode path: the zlib stream, the loose
header, the payload. Git chose the filename; we recompute the hash. If a
single byte of the decode is wrong, the hash does not match.

That is an oracle with no fixtures to maintain and nothing we control, and
it cannot be satisfied by being self-consistently wrong. It is the reason
this repo has no expected-output files.

Everything else is `git cat-file -p` / `-t` / `-s` and `git log --format=`,
object by object, over every loose object of the `CORPUS_SMALL` set: the
three repositories the suite builds, and cc, tarx and inflate if they are
there. Those last three contribute NOTHING to it at the moment, and did when
this was written: all eight siblings have since been repacked and hold no
loose object at all, so the 369 objects the sweep covers are the self
corpus's own. The suite prints which repositories it got them from for that
reason, rather than only how many it found, since the floor of 20 was being
cleared by a corpus the suite builds itself whatever the neighbours did.

The other five siblings get `gitobj verify` over their whole object store,
which now finds nothing in them either, plus a whole-repository `gitobj ls`
comparison for the ones with no packfile. This said "nine", the size of the
corpus, not the reach of the per-object sweep.

For `gitobj write` the oracle runs the other way: every loose object of the
tree/commit/tag fixture is re-serialised into a bare repository git created
and nothing else has touched, and git is then made to read it back with
`cat-file -p` and `fsck --strict`. The name gitobj prints has to be the name
git gave the object in the first place. A write test can pass by finding its
object already there, which is why the target repository starts empty and
why the fan-out path is checked for a file: with the write turned into a
no-op, 63 assertions fail.

For `gitobj mktree` there are two oracles rather than one, because gitobj
chooses the byte order of what it writes. `git mktree` sorts its own input
too, so both are handed the same deliberately unsorted lines and must name
the same object; and `git fsck --strict` reads the result, which is what
makes the ORDER checked rather than merely the framing, since fsck calls a
misordered tree treeNotSorted. The fixture is built so that plain byte order
over the names is a different object (`a-b`, `a.c`, `a`, `a0`, `aa`: a
directory sorts as though its name ended in a slash, and `/` falls between
`.` and `0`), and the suite computes that other name in python and asserts
it is NOT what we produced, so the section cannot pass against a sorter that
ignores the rule.

Every tree in the mktree target repository got there through `mktree`: the
fixture's own trees are deliberately withheld when its objects are copied
in, so no comparison can be satisfied by an object that was already
present.

## The pack index has three oracles, and they disagree about what is broken

Nothing in a `.idx` is self-describing. The object count is the last of the
256 fanout entries, and the length of the 64-bit offset table is whatever is
left over once everything else has been accounted for, so a lie about any
length moves every field after it. Three git commands read one:

`git show-index` prints the offset, name and CRC of every object and reads
nothing but the index, which is what makes a hand-built index checkable at
all. Pass `--object-format=sha1`: outside a repository it has no config to
read the hash algorithm from and segfaults, which in a harness looks exactly
like a corrupt fixture.

`git verify-pack` reads the index and the pack together, so it is the
authority on whether an index gitobj accepts is one git accepts. It refuses
every corrupt fixture in the suite: eleven indexes and four index-and-pack
pairs. `git show-index` refuses four of the eleven, and the suite says which
four and why, because the parts it never has to resolve it never checks.

`git index-pack -o` builds an index from a pack's own bytes. Every corpus
index is compared against one git wrote today from the same pack, and they
are byte-identical, which is also what makes the suite's fixture builder
trustworthy: it rebuilds each of those indexes byte for byte before it
mutates one, so a fixture differs from git's only where it was asked to.

The CRC is the one field with an oracle outside the index entirely. It is a
CRC-32 over the object's bytes as packed, which means from its own offset to
the next offset in PACK order, and the index is sorted by name, so the
extents only exist once the offsets have been sorted. 2938 of them are
recomputed from the pack bytes and compared with what git stored.

The 64-bit offset table has no corpus coverage and never will: an offset
reaches it at 2^31, so a pack needs to be over two gigabytes. It is built
instead, two ways. An index over a real pack with every offset but the first
routed through the table, which git accepts and reads the pack through:
`git verify-pack` is happy with it, `git cat-file` gets blob content out of a
repository whose only index is that one, and `git fsck` is clean. And an
index carrying offsets no pack here could have, both sides of 2^31 and 2^32,
2^63 and 2^64-1, where `git show-index` is the oracle because there is no
pack to go with them.

The first of those was built in the wrong shape. git's index size check
allows at most n-1 large offsets, since the first object in a pack sits at offset 12
and can never need one, so an index routing ALL of them through the table is
one git calls "wrong index v2 file size". gitobj enforces the same limit now
and the suite keeps the over-full index as a refusal case.

## Two bugs, and a sanitizer that could not see the parser

The first fixture that pointed an index offset past the end of the pack
segfaulted. `idxcrc` validated each offset in the same loop that used it, and
an object's length comes from the NEXT offset, so one bogus entry made its
predecessor's extent run off the end of the pack while the predecessor's own
offset was perfectly valid. The check was on one end of the range and the
read was on the other. Offsets are all validated before any extent is
derived from one now, and the fixture that found it is an ordinary case in
the suite.

The second was a missing rule rather than a crash, and git found it: the n-1
limit on large offsets, above. The first all-indirect fixture was rejected by
`git verify-pack` with "wrong index v2 file size", and the limit was news.

`readall()` doubles its buffer, so a 4MB pack sits in an 8MB allocation and a
read a few bytes past the end of the file lands megabytes inside a live
block, where ASan says nothing. Both the index and the pack are trimmed to
exactly what was read before anything parses them, and the effect is
measured rather than assumed. With the index's two size checks deleted and a
truncated fixture whose checksum was repaired so it got that far, the trimmed
build gives:

```
ERROR: AddressSanitizer: heap-buffer-overflow ... READ of size 20
```

and the untrimmed build reports nothing at all, reads 140 names out of the
rounded-up allocation, and refuses the file for an unrelated reason. Deleting
the trim on its own changes no test result, which is the honest way to put
it: it is the thing that makes a sanitizer run over this parser mean
something, and no assertion here fails without it.

31 mutations of the index reader, 30 red, and that trim is the one survivor.
Seven survived the first sweep and five of those were the fixtures rather
than the code: a backwards fanout entry planted where the walk over the
names catches it anyway, three fixtures that broke the index checksum as
well as the field under test, and no duplicate-name fixture at all, so
relaxing the name comparison from `<=` to `<` was invisible. The remaining
two leave the file refused for a different reason with the same exit status,
which is why every refusal here asserts its message and not only its status.
The details are in `PLAN.md`.

## The pack walk, and the corpus that had to be built for it

A pack entry begins with a varint that is split three ways: the top bit
continues it, the next three bits are the type, and the low four are the
bottom four bits of the size, with seven bits per byte after that. The type
and the inflated size are `git verify-pack -v`'s second and third columns and
nothing in the index holds either of them, so this is the first thing here
that reads pack content at all.

Deltas are not resolved yet, so the comparison needs a pack with none in it,
and the corpus the rest of the suite uses cannot provide one. Its blobs are a
few dozen bytes each and git does not attempt a delta below 50 bytes, so
`pack-objects` leaves all 123 objects whole whatever window it is given. That
was found by asserting the opposite: the first version of this section built
a `--window=0` pack and checked that the ordinary pack had deltas to refuse,
and the ordinary pack had none either.

So there is a fourth repository now, 40 revisions of a 400-line file with one
line rewritten each time, plus a tree per revision that grows by one entry
and a commit per revision. git packs that into 121 objects of which 74 are
deltas, the deepest chain 9, and those numbers are printed by the suite
rather than assumed, because a delta test over a pack with no deltas in it
passes while reading nothing. The trees matter on their own: a delta entry
carries no type, it inherits the type of whatever is at the end of its chain,
so a corpus whose deltas are all blobs cannot tell a type read from the base
apart from one read anywhere else.

The same objects are packed twice, once with `--window=0` and once the way
git chooses. `git verify-pack -v` prints five fields for an entry stored
whole and seven for a delta, so which pack is which is asserted from git's
own output rather than from the flag that was meant to produce it. All 121
objects of the delta-free pack are compared against `verify-pack -v` line by
line, per object rather than as a file diff, and all 121 hash back to their
own names. The delta pack is refused, with git reading the very same pack
perfectly, which is the pair a missing feature needs: its failure mode is not
an absent error message, it is a confident wrong answer about something that
looked close enough.

Seven mutations of the pack walk, six red. Reading the type from the low
three bits instead of bits 4 to 6 fails 9 assertions, taking the size nibble
from three bits rather than four fails 5, and resuming the varint at bit 7
instead of bit 4 fails 6. Deriving an entry's extent from the next INDEX
entry rather than the next offset in pack order fails 8, every one of them a
CRC comparison in section 8, which is the same defect that section already
exists to catch. Accepting type 5, which git has never assigned, and
dropping the check that an entry inflated to the size it declares each fail
2: both needed a pack edited by hand, since nothing git writes is wrong in
either way.

Those two fixtures are each a single lie. Editing one byte of a pack
invalidates four things that have nothing to do with the defect under test
(the pack's trailing checksum, the copy of it the index carries, that
object's CRC, and the index's own checksum) and all four are re-stamped, with
`gitobj idxcrc` accepting the edited pair as the guard that they were.

The survivor is treating the 20-byte pack trailer as entry data. Nothing
points an entry at it: every offset is checked against the start of the
trailer when the index is opened, so the bound only matters to a varint or a
zlib stream that runs off the end of the last entry, and no fixture here does
that. It is the truncation work of `PLAN.md`'s refusals item, and until that
exists this is a bound with no test behind it, which is said here rather than
counted as covered.

## What does not work

There is no delta support, so most of a pack is still unreadable. A pack
entry's type and inflated size are read now, for entries stored whole;
`OFS_DELTA`, `REF_DELTA`, the copy/insert instruction stream and chains whose
base is itself a delta are all still absent, which is the next four items of
`PLAN.md`. `packls` stops at the first delta entry, and git puts the whole
entries first, so it gets 24 to 49 objects into each of the eight sibling
packs and no further.

So the hard invariant, that every object read hashes back to its own name,
covers **490 of the 3184 objects the suite reads, 15%**: the 369 loose ones
and the 121 in the delta-free pack. Not one of the 2815 objects in the eight
sibling packs is covered, because every one of those packs has a delta in it
and `packverify` stops there. The share was 699 of 2062 two commits ago and
the denominator has grown rather than the numerator shrinking: the siblings
have all been repacked since, so what were loose objects there are now packed
ones, and 8 of the 11 corpus repositories hold no loose object whatsoever.

The CRC is the strongest thing available to an index reader, and it is not
the same claim. It says the packed bytes between two offsets are the bytes
git had when it wrote the index, which pins the offsets and the extents, and
says nothing about whether those bytes inflate to anything.

`PLAN.md` claimed all of the above as finished until an audit went looking.
Its hard invariant said the suite hashes "every object in every corpus
repository, loose and packed", its in-scope list described the v2 index, both
delta encodings and delta chains of any depth, and its oracle list included
`git verify-pack -v` diffed against a `gitobj packls`. The index was the
first of those to exist and `packls` is the second; the diff against it is
real but partial, since it can only be run over a pack that holds no delta.

A pack over two gigabytes is the one thing in the index the suite cannot
obtain, so no index git itself wrote with a 64-bit offset in it has ever been
read here. What runs instead is described above: an index the suite rewrites
so that git resolves a real pack through the table, and an index carrying
offsets by hand. Both have git on the other side of the comparison; neither
is a 2GB pack.

`.rev` files are ignored. `git pack-objects` writes one beside every pack it
makes and nothing here looks at it, so the reverse mapping from offset to
object is recomputed by sorting instead of read.

Writing compresses nothing. `gitobj write` emits a zlib stream of stored
blocks, so a loose object it writes is about 1.0003x its payload where git's
is nearer 0.3x. git reads it perfectly and `fsck --strict` is happy, but no
one should write a real repository with this. A real encoder is the first
item of `PLAN.md`'s Milestone 1.

`gitobj mktree` is narrower than `git mktree` in three ways, all of them
things git does by looking in the object store, which it does not do. It
does not check that an entry's object exists, nor that the object's real
type matches the declared one, so `040000 tree <a blob's name>` is accepted
here and refused by git. It has no `-z` and no `--missing`. And, like git,
it does not reject two entries with the same name, which produces a tree
`fsck` rejects.

It is stricter than `git mktree` in three other ways, and in each of them
git writes an object that `git fsck --strict` then complains about: a file
mode git does not use (`100645`), a zero-padded mode (`000000`), and an
empty entry name. The suite asserts both halves of that -- we refuse, and
git's own fsck objects to what git produced -- because a refusal with no
outside authority behind it is just an opinion.

A tree is the only object gitobj constructs. There is no commit or tag
builder, no packfile writing, and no `unpack-objects`.

Those paragraphs used to be one line saying the whole thing was read-only,
which it was until the writer landed. `PLAN.md` had listed `write` and
`mktree` as though both existed for a good while before either did.

No SHA-256 repositories, no ref parsing, no abbreviated names, no
`--batch` protocol, no index or worktree. Objects are addressed by full
40-character name only.

No `.mtimes`, bitmap or multi-pack index files, no cruft packs, no promisor
or partial clones, no alternates. No v1 pack index: it is refused by name
rather than read, since it has no CRCs and git has not written one since
2007.

Not fast. Every object is inflated from scratch.

## Why this file exists

The house convention here is that every repo has a `README.md` stating what
does *not* work, and this repo did not have one. `gitobj.c`'s header comment
pointed at it (`See README.md`), and so did a comment in `t/run.sh` pointing
at a "section 9" that did not exist either: the file stopped at section 5,
and stops at 9 now that there is a writer, a tree builder, a pack index
reader and a pack walk to test. Section 9 is the one that comment pointed
at, three commits before it was written. Those two pointers and the `PLAN.md` prose were the only
places the pack gap was acknowledged, and all three described it as
finished.

## License

GPL-3.0-or-later.
