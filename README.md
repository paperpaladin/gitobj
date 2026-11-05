# gitobj

Reads git's object database, writes loose objects into it, builds trees, reads
a packfile's v2 index, and reads the objects out of the pack through delta
chains of either encoding and any depth: one C11 file, no libgit2, no
shelling out to git.
The DEFLATE decoder is vendored from the sibling `../inflate` rather than
rewritten; the writer emits zlib stored blocks, which git reads and which
compress nothing.

```
$ gitobj idx ../cc/.git/objects/pack/pack-1b962a98....idx | head -2
51370 00b08fcfd7569c4407399d58abdb585cb5b0643d (d10ec21f)
64393 00e813579e96a58252d7324af1f0e21b11249363 (0a14a8ba)
538 objects, 538 direct, 0 via the 64-bit table of 0

$ gitobj packls ../cc/.git/objects/pack/pack-1b962a98....idx | sed -n 49,51p
f55cee9ad6bf4ba21828ed2409ce2bb378a697be commit 1199 651 50072
54ce2cb5891339e828859673bca6014932d23852 commit 74 81 50723 1 c160c3f543be8fc45799263920baf036f4e4edc7
0eda167000fac0757223e1bb1d45bb38402455d3 commit 72 80 50804 1 fb2f17948db733ec0a52bbe6ba0c31663ad2d24a
538 objects, 121 read whole, 417 through a delta chain, deepest chain 29

$ gitobj ls ../cc/.git/objects | head -2
00b08fcfd7569c4407399d58abdb585cb5b0643d commit 2474
00e813579e96a58252d7324af1f0e21b11249363 commit 1186
538 objects, 0 loose, 538 from 1 pack

$ make test
sibling corpus (small): 3 of 3 present
per-object cat-file sweep: self_a(123, 123 loose) self_b(123, 123 loose) self_c(123, 123 loose) self_p(123, 0 loose) cc(538, 0 loose) tarx(218, 0 loose) inflate(250, 0 loose)
sibling corpus (big): 5 of 5 present
verified 3307 objects across self_a self_b self_c self_p cc tarx inflate psh unrepro cmark httpd wasmi
ls against git batch-check: 3307 objects over 12 repositories, 369 loose and 2938 packed
read 10 pack indexes, 3061 objects
3173 objects read through a 32-bit offset, 134 through the 64-bit table
the delta corpus: 124 objects, 79 delta entries, deepest chain 15
packls: 3433 objects against verify-pack -v, 2016 of them deltas, deepest chain 29
16746 passed, 0 failed
```

`gitobj packls` prints what `git verify-pack -v` prints, padding included,
and the two are byte-identical over all thirteen packs in reach. The columns
are not all of one kind and the mixture is not arbitrary: the type is the one
at the END of a delta chain, since a delta entry carries none of its own,
while the size is the one THAT entry declares, which for a delta is the
length of the delta data and not of the object it produces. Printing the
resolved size there disagrees with git on every delta in the pack, which is
how that was found.

`gitobj idx` prints the same three fields as `git show-index`, in the same
format, so the two can be compared object by object. The
census on the last line is on stderr, which keeps stdout byte-comparable, and
it is there because a test for the 64-bit offset table passes while reading
nothing if no object in the corpus needs one. None does: every pack here is
far under two gigabytes.

## Two numbers, and which one to quote

Cloned on its own this suite reports **4133 passed**, against five bare
repositories it builds itself. Four hold 120 blobs each through one
`hash-object --stdin-paths`, plus a tree, a commit and an annotated tag from
plumbing, at fixed dates so the object names do not move between runs. One of
those four is then moved wholesale into a pack, because a clone with no
siblings would otherwise have nothing but loose objects in its corpus, and
every comparison would run over one half of the store while reporting a count
that looks like the whole of it. (`git repack` is no use for that: nothing in
these repositories is reachable from a ref, so it would leave 119 of the 120
blobs loose.) Another is packed with `git pack-objects` into a directory
beside it, which is what the index reader reads.

The fifth is for the deltas and is described under the pack walk below,
because the first four cannot do that job: their blobs are a few dozen bytes
each and git does not attempt a delta below 50 bytes, so no window setting
makes it produce one.

Inside the collection it reports more: 16746 above, because the sibling
repositories are an additional corpus, and more of them is strictly better
evidence. But that number moves every time anything is committed anywhere in
the tree, since a commit creates loose objects. It is a real count of real
comparisons and a useless figure to quote, so the collection's table quotes
4133: the one a reader gets by cloning this repository and running `make
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
object by object, over every object of the `CORPUS_SMALL` set, loose and
packed: the four repositories the suite builds, and cc, tarx and inflate if
they are there. 1375 objects, 1006 of them out of a pack.

git chooses the set. `cat-file --batch-all-objects` lists what is in the
store, so the sweep covers whatever is there rather than whatever it went
looking for. It used to walk the fan-out directories instead, which found
nothing at all in cc, tarx or inflate: every sibling in the collection has
been repacked since those were added, so the sweep the previous version of
this paragraph described as running over three real histories was running
over the suite's own corpus and clearing its floor of 20 objects with that.
Hence the per-repository line in the output, and an assertion that both
halves of the store were read: 8 of the 12 corpus repositories hold nothing
but packed objects and 3 nothing but loose ones.

The other five siblings get `gitobj verify` over their whole object store,
3307 objects across all twelve, plus a `gitobj ls` comparison against `git
cat-file --batch-all-objects --batch-check` over each one whole, compared
line by line. That comparison also used to be restricted to a repository
with no packfile, so it was skipping 8 of the 11 and saying so in a line
nobody counted. This said "nine", the size of the corpus, not the reach of
the per-object sweep.

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

## The pack walk, the deltas, and the corpus that had to be built for them

A pack entry begins with a varint that is split three ways: the top bit
continues it, the next three bits are the type, and the low four are the
bottom four bits of the size, with seven bits per byte after that. The type
and the inflated size are `git verify-pack -v`'s second and third columns and
nothing in the index holds either of them, so this is the first thing here
that reads pack content at all.

An `OFS_DELTA` gives its base as a distance backwards from its own offset, in
a third varint that is neither of the other two: each continuation byte adds
one before shifting, so `(v + 1) << 7` rather than a plain shift, and getting
that wrong is silent until the distance passes 127. The delta itself is two
sizes and then copy and insert instructions, where a copy's offset and length
are assembled out of whichever of seven following bytes a bitmap in the
instruction byte says are present. An absent byte is zero, except that an
absent length means 0x10000, which is the one default that is not the
identity.

The corpus the rest of the suite uses cannot reach any of that. Its blobs are
a few dozen bytes each and git does not attempt a delta below 50 bytes, so
`pack-objects` leaves all 123 objects whole whatever window it is given. That
was found by asserting the opposite: the first version of this section built
a `--window=0` pack and checked that the ordinary pack had deltas in it, and
the ordinary pack had none either.

So there is a fourth repository now: 40 revisions of a 400-line file with one
line rewritten each time, a tree per revision that grows by one entry, and a
commit per revision, plus three revisions of a 20000-line file. git packs
that into 124 objects of which 79 are deltas, the deepest chain 15, and those
numbers are printed by the suite rather than assumed, because a delta test
over a pack with no deltas in it passes while reading nothing. The fixture is
built with `--threads=1`: the delta search is threaded and otherwise two runs
of the same command over the same objects give 76 delta entries and then 75.

Two parts of that fixture are there for a specific mutation. The trees are,
because a delta entry inherits the type of whatever is at the end of its
chain, so a corpus whose deltas are all blobs cannot tell a type read from
the base apart from one read anywhere else. And the large file is, because
git's encoder omits a copy's length bytes for exactly 0x10000 and splits any
longer run into pieces of that size, so the implicit length is only reached
over a base of at least 64KB. With the 400-line blobs alone, taking the
absent length as 0 was a mutation that died in the collection, where cc has
big blobs, and SURVIVED in a standalone clone. It dies in both now.

`--delta-base-offset` is not optional when building the fixture. Plumbing
`pack-objects` leaves `pack.useDeltaBaseOffset` off and writes `REF_DELTA`,
where `git gc` and `git repack` pass the flag, so every pack in the
collection is `OFS_DELTA` and a fixture built without it is the other
encoding entirely. That was caught by the section going red, `REF_DELTA`
being the one thing refused at the time.

The same objects are therefore packed a third time, with
`--no-delta-base-offset`, for `REF_DELTA`. A `REF_DELTA` names its base by
hash rather than by distance, so the base can sit either side of the entry
that uses it and finding it is a binary search in the index. The two packs
must agree about every object's name and type, and all 124 must hash back to
their own names out of both. Nothing in `verify-pack -v` can say which
encoding a pack holds, since it prints a chain length and a base name
whichever one carried them, so the discriminator is a census of the two kinds
of link: the `OFS_DELTA` fixture must resolve none of the one kind and the
`REF_DELTA` fixture none of the other, and every pack in the corpus must hold
no `REF_DELTA` at all, which is the assertion that says why the fixture has
to exist.

A `REF_DELTA` whose base is not in the pack is a thin pack, which git sends
down a wire and never stores, so it is refused. The fixture for it stops the
index naming one object and tells the pack header it holds one fewer, leaving
the base's bytes where they were: what goes is the entry that would have
found them.

The comparison runs over every pack in reach: the three fixture packs and
the nine indexes the corpus has, 3310 objects, 2016 of them deltas, chains up
to 29 deep. Per object rather than as a file diff, since a diff over three
thousand objects says only that something somewhere disagreed. The census is
checked against git's own count of delta entries and git's own deepest chain,
read out of `verify-pack -v`'s field count and sixth column, so a run where
the delta code never fired could not report agreement. And all 3310 hash back
to their own names.

Eighteen mutations, fourteen red. Reading the type from the low three bits
instead of bits 4 to 6 fails 9 assertions, taking the size nibble from three
bits rather than four fails 5, and resuming the entry varint at bit 7 instead
of bit 4 fails 6. Deriving an entry's extent from the next INDEX entry rather
than the next offset in pack order fails 8, every one of them a CRC
comparison in section 8, which is the same defect that section already exists
to catch. On the delta side, the `OFS_DELTA` varint without its `+ 1` fails
45, the copy bitmap read as three offset bytes and four length bytes fails
45, a delta header varint shifted by 8 instead of 7 fails 45, taking an
absent copy length as 0 fails 10, and a chain length reported as 1 for every
delta fails 680, which is one per delta entry in the corpus. Accepting type
5, which git has never assigned, and dropping the check that an entry
inflated to the size it declares each fail 2: both needed a pack edited by
hand, since nothing git writes is wrong in either way. On the `REF_DELTA`
side, leaving the 20-byte base name in front of the zlib stream fails 10, and
so does a bucket lower bound off by one in the index lookup.

Not refusing a `REF_DELTA` whose base is missing fails exactly one
assertion, and that one is the message. Reading the WRONG base instead
leaves the file refused anyway, by the delta's base-size check, with the same
exit status; the only witness is the text. That is the third mutant here to
survive everything except a message assertion, after the two in the index
reader.

Each of those hand-built fixtures is a single lie. Editing one byte of a pack
invalidates four things that have nothing to do with the defect under test
(the pack's trailing checksum, the copy of it the index carries, that
object's CRC, and the index's own checksum) and all four are re-stamped, with
`gitobj idxcrc` accepting the edited pair as the guard that they were. The
thin-pack fixture is the one exception and deliberately so: dropping an index
entry leaves its neighbour's extent spanning the gap, so that pair's CRCs do
not and cannot agree, and `git verify-pack` refuses it for both reasons.

Three of the four survivors are bounds that only a malformed pack can cross,
and there is no malformed pack here yet. Treating the 20-byte trailer as
entry data survives because every offset is checked against the start of the
trailer when the index is opened, so the bound only matters to a varint or a
zlib stream running off the end of the LAST entry. Dropping the check that a
delta's declared base size matches the base, and dropping the check that the
result is the size the delta declares, survive for the same reason: git's own
deltas are correct, so nothing in any corpus exercises either. All three are
the refusals item of `PLAN.md`, which wants a pack built by hand rather than
by git, and until that exists they are bounds with no test behind them. Said
here rather than counted as covered.

The fourth was written as a defect and is not one. Having the index lookup
search the whole name list instead of the one fanout bucket gives the same
answer every time, because the names are globally sorted and the bucket is a
contiguous range of them. The fanout there saves eight comparisons and
changes no result, so there is nothing for a test to see.

## What does not work

There is no delta base cache, so a chain of depth N costs N inflations for
every object on it. `packls` over cc's 538 objects does 1923 inflations where
git would do 538, which is why it is still fast enough not to matter at this
size and will matter at a bigger one. It is a four-entry LRU keyed on pack
offset, in Milestone 1.

The hard invariant, that every object read hashes back to its own name, now
covers every object in every corpus: 369 loose, and 3433 read out of thirteen
packs, 2016 of those through a delta chain. It said 490 of 3184 three commits
ago. What it does not cover is a pack this suite cannot build, which is one
over two gigabytes, and a pack built to be wrong rather than by git, which is
the refusals item.

`gitobj ls` and `gitobj verify` read a whole object store now, loose files
and packs together, and an object that is in both is listed once. `gitobj
cat`, `raw`, `type`, `size`, `hdr` and `msg` find a packed object too. What
none of them does is open a pack more than once per run, so the one-object
commands read every index and every pack in the store to answer about one
object: 3ms for a packed object in cc, where git is nearer a tenth of that.

The CRC is the strongest thing available to an index reader, and it is not
the same claim. It says the packed bytes between two offsets are the bytes
git had when it wrote the index, which pins the offsets and the extents, and
says nothing about whether those bytes inflate to anything.

`PLAN.md` claimed all of the above as finished until an audit went looking.
Its hard invariant said the suite hashes "every object in every corpus
repository, loose and packed", its in-scope list described the v2 index, both
delta encodings and delta chains of any depth, and its oracle list included
`git verify-pack -v` diffed against a `gitobj packls`. Every one of those
exists now, four commits after the audit, and the hard invariant is finally
the claim it had been making all along.

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

Not fast. Every object is inflated from scratch, every delta in a chain is
re-applied for every object on that chain, and a command that wants one
object opens every pack in the store. `make test` takes 34 seconds, where it
took 10 before it read any packs.

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
