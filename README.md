# gitobj

Reads git's object database, writes loose objects into it, builds trees, reads
a packfile's v2 index, reads the objects out of the pack through delta chains
of either encoding and any depth, and writes a packfile and its index with a
delta search of its own, in either of git's two object formats: one C11
file, no libgit2, no shelling out to git. Both DEFLATE halves are vendored
from the sibling `../inflate` rather than rewritten, and the SHA-256 core
from `../sha2`, which is where their oracles live.

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
per-object cat-file sweep: self_a(123, 123 loose) self_b(123, 123 loose) self_c(123, 123 loose) self_p(123, 0 loose) cc(552, 14 loose) tarx(218, 0 loose) inflate(250, 0 loose)
sibling corpus (big): 5 of 5 present
verified 3321 objects across self_a self_b self_c self_p cc tarx inflate psh unrepro cmark httpd wasmi
ls against git batch-check: 3321 objects over 12 repositories, 383 loose and 2938 packed
loose object sizes: 100000 zero bytes to 133, 336000 of repeated text to 1059, 100000 random to 100028
the same repeated text: 1059 bytes here, 2041 from git at its own default
read 10 pack indexes, 3061 objects
3173 objects read through a 32-bit offset, 134 through the 64-bit table
the delta corpus: 124 objects, 79 delta entries, deepest chain 15
pack fuzz: 300 mutants, 299 refused for 13 distinct reasons, 1 still readable, all agreeing with git
packls: 3438 objects against verify-pack -v, 2019 of them deltas, deepest chain 29
base cache: 4260 inflations and 1615 hits, against 8791 inflations with no cache
abbreviated names: 1512 of 7 characters resolved, 0 refused
four-character prefixes: 32 resolved, 4 ambiguous
our delta encoder on the delta corpus: 56049 bytes against 201746 stored whole, 59854 bytes for git -- 1366 copy and 1793 insert instructions, 33 of them with the length left implicit, widest offset 3 bytes
our packs: 372 objects against verify-pack -v, 117 of them deltas, deepest chain 10
sha256: 64 names, 126 objects swept (63 packed), 59 through a delta chain, 68 ref-delta links, 16 written
21139 passed, 0 failed
```

`gitobj packls` prints what `git verify-pack -v` prints, padding included,
and the two are byte-identical over all fifteen packs in reach. The columns
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

Cloned on its own this suite reports **7388 passed**, against nine bare
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
makes it produce one. The sixth is 600 blobs whose only purpose is to hold
two objects whose names share their first four characters, which is what the
abbreviated-name lookup needs and what 123 objects do not provide.

The last three are SHA-256, built with `--object-format=sha256`: the same 63
objects loose, packed, and packed again as REF_DELTA, which is a 32-byte base
name in the entry rather than a 20-byte one. Their blobs share an 8893-byte
prefix so that `pack-objects` has deltas to find, since a SHA-256 corpus with
no delta in it would pass every comparison in that section while the delta
reader never ran.

Inside the collection it reports more: 21139 above, because the sibling
repositories are an additional corpus, and more of them is strictly better
evidence. But that number moves every time anything is committed anywhere in
the tree, since a commit creates loose objects. It is a real count of real
comparisons and a useless figure to quote, so the collection's table quotes
7388: the one a reader gets by cloning this repository and running `make
test`. Both figures moved by 650 with the SHA-256 section, and the clone
figure was 6737 in this file against 6738 measured, which is the sort of
drift a count in prose collects.

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
they are there. 1498 objects, 1129 of them out of a pack.

git chooses the set. `cat-file --batch-all-objects` lists what is in the
store, so the sweep covers whatever is there rather than whatever it went
looking for. It used to walk the fan-out directories instead, which found
nothing at all in cc, tarx or inflate: every sibling in the collection has
been repacked since those were added, so the sweep the previous version of
this paragraph described as running over three real histories was running
over the suite's own corpus and clearing its floor of 20 objects with that.
Hence the per-repository line in the output, and an assertion that both
halves of the store were read: 9 of the 12 corpus repositories hold nothing
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
extents only exist once the offsets have been sorted. 3061 of them are
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

So there is a fifth repository now: 40 revisions of a 400-line file with one
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

The comparison runs over every pack in reach: the fixture packs and the ten
indexes the corpus has, 3438 objects, 2019 of them deltas, chains up to 29
deep. Per object rather than as a file diff, since a diff over three
thousand objects says only that something somewhere disagreed. The census is
checked against git's own count of delta entries and git's own deepest chain,
read out of `verify-pack -v`'s field count and sixth column, so a run where
the delta code never fired could not report agreement. And all 3438 hash back
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

Three of those mutations survived everything git can be made to pack, and
the section below is what kills them. The fourth survivor was written as a
defect and is not one: having the index lookup search the whole name list
instead of the one fanout bucket gives the same answer every time, because
the names are globally sorted and a bucket is a contiguous range of them.
The fanout saves eight comparisons there and changes no result.

## A pack built by hand, because git never gets a length wrong

Every length in a pack is a number chosen by whoever wrote the file, and git
writes them all correctly, so the checks on them cannot be reached by any
fixture git produces. Three mutations of the delta code survived the whole of
the section above for that reason: the declared base size, the declared
result size, and the bound that keeps a varint or a zlib stream off the pack
trailer.

So the suite builds packs itself, which puts the fixture builder in the
position of being the thing that has to be trusted. git settles that three
ways over the well-formed one: `git verify-pack` accepts it and resolves its
chain, `git index-pack -o` rebuilds its index from the pack alone byte for
byte, and `git cat-file blob` hands back the same bytes we do out of a
repository whose only object source is that pack. The control is three
entries: a 70000-byte blob, an `OFS_DELTA` of it, and a `REF_DELTA` of THAT,
so one pack holds both encodings and a base that is itself a delta, and the
first copy instruction asks for exactly 0x10000 bytes with its length bytes
absent.

Eleven fixtures then lie about one thing each, and git has to call each one a
lie too: a delta whose declared base size is not the base's, a copy and an
insert each overrunning the declared result, a delta that produces less than
its declared result, a result size and an entry size above OBJ_MAX, an
instruction byte of 0, a copy reaching past the end of the base, an
`OFS_DELTA` at a distance of zero and one pointing before the pack header, a
`REF_DELTA` naming itself, and a pack cut off in the middle of its last
entry. The message is asserted for all but the last: a truncated zlib stream
fails wherever the decoder runs out, and which error that is depends on the
bytes.

Then 300 mutants of the control, one flipped bit each, anywhere in the entry
area, with both checksums and every CRC recomputed so the flip is the only
lie. Without that recomputation every mutant is refused by the pack checksum
and the fuzzer never reaches a single length field. Two things are asserted
per mutant: that gitobj either succeeds or refuses cleanly, never anything
else, and that gitobj and git agree about whether the pack is still
readable, which is a comparison rather than an opinion since `packverify`
hashes every object back to its name and so answers the same question
`git verify-pack` does. 299 are refused, for 13 distinct reasons, and 1 is
still readable. How many reasons is asserted as well as how many refusals:
most of a pack is zlib stream, so most flips land there and are caught by
the Adler-32, and a fuzzer that only ever reached that check would have
tested that check.

The fuzzer earned itself immediately. Dropping the check that an entry
inflated to the size it declares is caught by its own fixture and
independently by two of the 300 mutants.

What still survives is the bound that keeps a varint or a zlib stream off the
pack trailer, and it is unobservable rather than untested. Every offset is
checked against the start of the trailer when the index is opened, so the
bound only matters to the LAST entry's stream, and no well-formed pack has
one that runs over. The truncation fixture does reach it and the difference
is visible, but only as which inflate error comes out: the bound in place
gives "bad literal/length code at 658", and extended over the trailer it
gives "distance reaches before output start at 658". Both refuse, at the same
offset. Pinning the suite to that text would be pinning it to where a cut
happened to land, so the measurement is here instead.

`make test-asan` runs all 19545 assertions under ASan and UBSan, this
section's hand-built and fuzzed packs included, and is clean. The encoder
vendored later went through it too. That is worth
no more than the trimming described two sections up makes it worth: the
index and the pack are both shrunk to exactly the bytes read, and without
that a read past the end of either lands inside a rounded-up allocation and
the sanitizer says nothing.

## The three sabotages

A suite whose failure has never been observed is not evidence, so three rules
that the whole project rests on get broken on purpose and the damage written
down. All three numbers are against the suite as it stands, 17099
assertions, and all three were re-measured for this section rather than
copied from when each was first planted.

The object header. `objhdr` returns the length of `"<type> <len>"` plus one
for the NUL that follows it; returning the length without the NUL takes one
byte off everything that is hashed. 291 assertions fail, and they are the
write oracle: every object `gitobj write` and `gitobj mktree` put in a bare
repository comes out under a name git does not agree with. It failed 43 when
it was first planted, against a suite of 2303.

The tree sort. Entries compare as though a directory's name ended in a
slash, so `a.c` sorts before `a` when `a` is a directory. Deleting that rule
fails 52, and two of those are `git fsck --strict` calling the result
treeNotSorted, which is what makes the ORDER checked by something other than
a name comparison. The number has not moved since it was planted, because
nothing added since reads a tree we built.

The delta copy instruction. A copy's operand bytes are selected by a bitmap
in the instruction byte, four bits for the offset and three for the length;
reading it as three and four fails 3155. The first failures are `gitobj
verify` over the sibling repositories, which is the hard invariant itself:
objects come out of the pack and do not hash back to the names git filed
them under. This one is also the clearest measure of what the suite has
grown into rather than of the defect, because the same sabotage failed 45
assertions three commits ago, before `ls` and `verify` read packs at all.

## The base cache, and why four entries were not enough

A chain of depth N costs N inflations for every object on it, so walking a
whole pack is O(objects times chain depth): 1856 entry reads for cc's 538
objects, where git does 538. `PLAN.md` asked for a four-entry cache keyed on
pack offset, on the reasoning that git's delta window keeps a base within a
few entries of the deltas on it.

Four entries does almost nothing. Measured over cc: 1771 inflations against
1856 with no cache at all, a saving of 5%. The reasoning was about the pack
LAYOUT and the cost is in the chain DEPTH, which reaches 29 there, so every
object resolved flushes a four-entry cache on its way down. 16 entries gives
1033, 64 gives 729, and 256 gives 719, so 64 is where it stops paying. With
64 and a 16MB budget, a whole-pack walk over cc goes from 0.41s to 0.26s.

The cache holds BASES only, never the object actually asked for. That is not
an optimisation detail: a cache consulted for the asked-for object would let
a walk over a pack answer out of itself, and `packverify` would then be
hashing the cache rather than the pack.

Nothing in a pack-order walk can see that rule, though, because an
`OFS_DELTA` base is always earlier in the pack and so is never the object
asked for next. Only a `REF_DELTA` can name a base that comes AFTER it, and
nothing git packs here does. So there is a hand-built pack of two entries, a
`REF_DELTA` followed by its own base, which git accepts; with the rule
removed, reading it inflates one entry and takes a cache hit where it should
inflate both, and that is the one assertion in the suite that notices.

Three things are asserted about the cache for every pack read. That every
entry reached was either inflated or found in the cache, which is arithmetic
and catches an accounting slip. That the inflations never fall below the
object count, which is the rule above. And that the inflations come to fewer
than git's own sum of chain lengths plus the object count, which is what the
walk would cost with no cache, so the saving is measured against git rather
than asserted to exist.

Four mutations, two red. A cache keyed on nothing, so that any entry
matches, fails 118 assertions, beginning with `gitobj verify` over the
siblings. Removing the cache entirely fails 12, all of them the
saving-against-git check. The two survivors are both the byte budget:
never evicting, and caching an object too big for the budget, are both
invisible because no corpus here has 16MB of live bases. They are a
resource bound on sizes chosen by whoever wrote the pack, which is a reason
to have them and not a reason a test can see them.

The first version of this cache was wrong in a way worth keeping. A cached
entry has no entry header left to read, so caching the bytes alone left
every cached base with type 0 and every chain length at 1: 85 of cc's 538
objects hashed to nothing, and the depth column disagreed with git on every
delta. The cache stores the entry facts beside the bytes now.

## A store that borrows another one

`objects/info/alternates` lists other object directories to look in, one per
line. `git clone -s` writes it and most CI caches look like it, and an object
in an alternate is in the repository as far as every git command is
concerned, `cat-file --batch-all-objects` included. A reader that ignores the
file reports "object not found" for a repository git reads perfectly, which
is what this one did until now.

The fixture is git's own doing rather than a line this suite composed: `git
clone -s --bare` of a self corpus repository, done twice, once where the
source is loose and once where it is packed. The borrowing clone is checked
for having no object and no pack of its own, because without that the
comparison could be passing on a copy. Then `git cat-file
--batch-all-objects --batch-check` against `gitobj ls` line for line, and
`gitobj verify` over all 123.

Five more shapes, all of them hand-written because git only ever writes the
first. A relative path, which resolves against the objects directory holding
the file and not against the current directory. A chain of three, since an
alternate may have alternates of its own. A cycle. The same cycle spelled
with relative paths. And a file holding a comment, a blank line and a
directory that is not there, where git complains about the one it cannot use
and carries on: that complaint is an assertion here rather than noise in the
output, because carrying on is the behaviour being matched.

The two cycle guards catch different things, and finding that out took
planting them. A directory already in the list is not searched again, which
ends a cycle spelled the same way round both times. A de-duplicated LIST is
not the same thing as a terminating WALK, and the first version here only
had the former: it skipped the duplicate entry and then read that
directory's alternates file again anyway, so a two-repository cycle
recursed until the stack ran out. The depth limit of five, which is git's
own, is what ends a cycle spelled two ways, and relative paths make that
easy since each hop appends to the path and no two strings are ever equal.

Five mutations, four red. Ignoring the file fails 15 assertions, resolving a
relative path against the current directory fails 4, reading only the first
line fails 4, and dropping the depth limit fails 3, one of which is a
segfault rather than a wrong answer. The survivor is the early return on a
duplicate directory, which the depth limit now covers as well: it bounds the
work rather than the result.

## Abbreviated names, and the store built to make one ambiguous

Every human-facing git command takes a 7-character prefix, and the rule that
goes with it is that a prefix matching two objects is an error rather than a
choice. `gitobj name` does that lookup and nothing else, which makes `git
rev-parse --verify` the oracle: the same lookup, on the other side.

1498 objects of the small corpus are looked up by their first 7 characters,
and compared against whatever git says rather than against success, because
a prefix that short can collide and then both of us have to refuse. None of
them does, here. Four characters is where collisions turn up: 3061 objects
over 65536 buckets produce them readily.

Which is a problem for a clone with no siblings, where the corpus is 123
objects per repository and has no 4-character collision at all. The
ambiguity path went untested there and said so, which is the whole reason
for the floor on it. There is a store of its own for that now: 600 blobs of
fixed content, which collide at `bc98` and `bfae` and will collide at the
same two prefixes on every run, since the content decides the names. Which
prefixes are ambiguous is read out of git's listing rather than ours, both
of us then have to refuse them, and a prefix one character longer has to
resolve.

Three mutations, three red. Returning the first match instead of refusing
fails 4 assertions, all of them the ambiguous prefixes. Dropping the
four-character minimum fails 3, and one of those uses a 3-character prefix
that matches exactly one object, so the length is the only reason to refuse
it. Comparing the prefix over 40 characters rather than its own length fails
1537.

The lookup is a linear scan over every name in the store, which is the list
`ls` builds anyway. The fanout would make it a binary search per pack, and
it is not where the time goes: a command that wants one object already opens
every index and every pack in the store to find it.

## Unpacking, where the two halves meet

`gitobj unpack` reads every object out of a pack and files it as a loose
one, which is what `git unpack-objects` does, so the two stores can be
compared whole. Four packs go through it: the two delta fixtures, the self
corpus's own, and the one built by hand.

The name is recomputed from what came out of the pack rather than copied
from the index. A writer handed the name it is meant to produce cannot be
caught producing another, and that is exactly the shape of a round trip
through two halves of the same program. An object whose name does not check
out is reported and NOT written: the one thing worse than refusing to unpack
a pack is filing an object under a name that is not its hash. The fixture
for it is a pack whose base blob has one byte changed after its names were
computed, so nothing in it hashes to what the index says; git refuses that
pack too.

`git fsck --strict` over the result is the half that matters. It inflates
every loose object we wrote, re-hashes it against the name we filed it
under, and parses the trees and commits, so the three hops are pack to
loose to git with git on the far side. Then the listings are compared line
by line against `git unpack-objects`' own store, and `cat-file -p` object by
object between the two.

Both targets are created empty and checked for it, because a write test can
pass by finding its object already there.

Three mutations, two red. Writing every object as a blob fails 249
assertions, starting with fsck. Writing the object despite a name that does
not check out fails 1, and that one assertion is the whole point of it.
Filing the object under the name the INDEX gave rather than the one we
computed was written as a defect and is not one: the two are equal wherever
anything is written at all, since the mismatch branch writes nothing.

## Writing, after the encoder arrived

`gitobj write` emitted zlib stored blocks until now: legal DEFLATE, read
perfectly by git, and about 1.0003x the payload where git's own loose object
is nearer a third of it. Nobody would have written a real repository with
one.

The encoder is vendored from `../inflate`, the same way its decoder was and
for the same reason: that project measures this encoder against `gzip -6`
over seven corpora and owns the oracle for it. What travels is the
tokeniser, the Huffman tree builder and the cost-chosen block boundaries;
what does not is gzip framing, which two header bytes and a big-endian
Adler-32 replace.

What is checked here is the vendoring, and that the choice between the three
block types is being made at all, since a cost model that always picked one
of them would pass every other assertion in the write section. Three
payloads, one per answer:

```
100000 zero bytes              ->    133      a coded block, or nothing could
336000 of one repeated line    ->   1059      0.3% of the payload
100000 from /dev/urandom       -> 100028      stored, and it has to be
```

The last of those is the sharpest. urandom cannot be compressed, so the cost
model has to fall back to stored blocks, which are five bytes of header per
65535 of payload plus six of framing. Anything much over 100028 is a coded
block being chosen when it should not have been, and anything under it is
impossible.

git's own loose object for that repeated line is 2041 bytes against our
1059, which is not a comparison either of us is trying to win: git's default
for a LOOSE object is compression level 1, where this encoder does the work
`gzip -6` does. Reported rather than asserted, for that reason.

Four mutations of the framing and the bit writer, four red, each of them
caught by git refusing to inflate what we wrote and by our own `verify`
refusing it too. Not reversing a Huffman code into the stream fails 822
assertions, a zlib header whose check bits do not divide by 31 fails 832,
the Adler-32 written little-endian fails 558, and never setting BFINAL fails
548.

## Writing a pack, and the index git builds from it

`gitobj pack <objdir> <outbase> <window>` takes object names on stdin, writes
`<outbase>.pack` and `<outbase>.idx`, and prints the pack's trailing
checksum, which is the name git would file it under. Everything the reader
decodes is written here: the entry header varint, the OFS_DELTA distance with
its minus-one continuation, the delta header's two sizes, the copy and insert
instructions, the v2 index with its cumulative fanout and per-object CRC, and
both checksums.

The sharp oracle is `git index-pack -o`. It builds an index from our pack
alone, and that file has to be byte-identical to the index we wrote beside
it: the fanout, the name order, every CRC, every offset, the copy of the pack
checksum and the index's own are then git's answer to the same question
rather than a comparison we are on both sides of. git re-indexing one of its
OWN packs reproduces that pack's `.idx` exactly, which is what makes this a
test of our index rather than a statement about how reproducible git's
indexer is.

Around that: `git verify-pack` over the pair, `packls` against `git
verify-pack -v` line for line over our own output, and the pack dropped into
a bare repository holding nothing else, where `git fsck --strict` walks every
chain and re-hashes every result against the name the index files it under
and each object is compared with the store it came out of. Four packs go
through all of it, the delta corpus at window 0 and at window 10, the self
corpus, and one holding a single tag, where an off-by-one in the fanout has
no neighbour to hide behind.

The window is an argument rather than a default because 0 and 10 are two
different claims. At 0 every object is stored whole and the entry header, the
index and the trailer are on their own; above 0 the delta encoder is in it.
A fixture built with the wrong one quietly tests the other, which is how the
OFS_DELTA corpus here came to be REF_DELTA for a while.

### The search has to be deterministic before anything can be said about it

git's own is threaded and is not reproducible: two runs over the same objects
gave 76 delta entries and then 75, which is why every fixture here passes
`--threads=1`. Ours sorts the objects by type, then size descending, then
name, compares each against up to `window` already-placed entries of the same
type, and keeps the smallest delta if it is smaller than the object by more
than the entry that would carry it. Chains are capped at 10. A base is only a
candidate once it is placed, so its offset is known and smaller, and a chain
in what we write cannot loop.

Two runs give the same pack bytes. So does the same list of names in the
opposite order, and that is a separate assertion rather than a repetition: a
writer that echoed its input order would pass the first and fail the second.

Matches come from an index of the base taken every 16 bytes and keyed on
eight of them, extended backwards into the literal run so a copy need not
start on a block boundary. The bucket walk stops after 64 candidates, so a
base full of identical blocks gets a worse delta rather than a slower search;
every candidate is verified by comparison, so the cap costs size and not
correctness.

On the delta corpus, 124 objects including three revisions of a 20,000-line
file:

```
stored whole        201746 bytes
window 10            56049
git, window 10       59854
```

and on `../cc`'s 538 objects, 2857651 against git's 3298397. Neither is the
delta search being cleverer than git's. It is the DEFLATE encoder vendored
from `../inflate` doing the work `gzip -6` does where git packs at zlib level
6, the same difference that makes a loose object 1059 bytes here against
git's 2041.

### The census, and the mutant it could not see

The writer prints on stderr what it emitted: objects, how many went out as
deltas, the deepest chain, the two file sizes, how many offsets took the
64-bit escape, and the count of copy and insert instructions with how many
copies left their length implicit and how wide the widest offset was. A delta
search that found nothing writes a perfectly valid pack, and every assertion
about our deltas would pass over it.

The first version of that line was decoration. It counted copies of length
0x10000 rather than copies emitted with no length byte at all, and those are
the same thing only in a build that has not been mutated: the mutant that
writes the three length bytes out in full survived an entire sweep with the
census still reporting 33 of them. It is counted off the instruction byte
now, and that mutant dies.

Ten planted defects, nine red:

```
fanout counting names strictly below its bucket     412 assertions
the index written in pack order, not name order     337
the OFS_DELTA varint without its minus one          129   git cannot index it
a delta header carrying the target size             129   git cannot index it
the pack trailer over all but the last byte          33
the CRC over the compressed bytes alone              12
no delta depth limit                                  1   a chain of 39
the implicit copy length written out in full          1
packing in the order the names arrived                1
```

The last of those only after the assertion was tightened. "The delta pack is
smaller than the whole pack" is satisfied by packing in name order, which
still finds 79 deltas and still comes to 97k against 202k stored whole. Under
a third is what the ordering has to earn, and 52k clears it.

The survivor is extending a match backwards into the literal run. It is worth
175 bytes of 51734 on the suite's own corpus, which nothing but a golden byte
count could see, and 5.2 per cent on `../cc`'s 538 objects, which a
standalone clone does not have. The fixture is what cannot see it.

No offset here reaches the 64-bit escape. The census says 0 of N through the
table on every run, because a pack that needs one is over two gigabytes and
this writer holds every object inflated at once while it searches. That
branch of the writer is unexercised and is the next item in `PLAN.md`.

## An index git itself wrote with a 64-bit offset

Everything else about the 64-bit offset table is tested against indexes this
suite rewrites or builds by hand. What no fixture can be is an index git
PRODUCED with a large offset in it, because that needs a pack git had a
reason to put one in, which means a pack over two gigabytes.

`make bigpack` builds one: eleven blobs of 230MB of urandom, under gitobj's
own OBJ_MAX of 256MB so each is an object it would agree to read, packed
with `--window=0`. Run on 5 November 2026 it produced a pack of
2,653,704,008 bytes in which git wrote 2 offsets at or above 2^31, and
`gitobj idx` agreed with `git show-index` line for line, with the census
confirming that 2 of the 11 objects came through the table. 18 assertions,
all passing.

It is not in `make test`: it writes about 5GB and takes minutes. That makes
it a target nobody runs, so re-run it rather than quoting the paragraph
above; the figures here are one run, not a standing claim.

`--window=0` is not a detail either. With a delta window those eleven 230MB
blobs are read into memory together to be compared, which on this machine is
an out-of-memory kill, and the first run reported an empty pack name and
seven confusing failures because the status of a command substitution was
never looked at. They are urandom and would not delta anyway.

What that run cannot do, and did not pretend to: read the OBJECTS of a 2.5GB
pack. `readall()` loads a whole file, so `idxcrc` and `packls` over that pack
would want 2.5GB of address space and a copy on top of it. The index is what
the target is for.

## SHA-256, and the half of sha2 that travelled

git has two object formats and they differ in the hash and in nothing else.
The loose header, the tree entry, the pack entry header, the index layout and
every checksum in both files are the same shapes with 32 bytes of name in
them instead of 20. So this is not a second reader: `hsz` is a global, 20 or
32, `hexsz` is twice it, and everything that used to say 20 says `hsz`.

The plan item for this said 20 was hard-coded in nine places, then said 29
after the pack reader landed, and told the next reader to re-grep rather than
quote it. Re-grepped at the commit before this one, the grep it names --
`[20]`, `20 *`, `* 20` -- finds 33 lines, not 29.

That grep is also the narrow one, because 20 is not the only spelling of the
length. `40` appears on 19 lines and `41` on 30, as the hex form of a name
and as the buffer that holds one, and the union of all three greps is 81
lines. Two of the 81 are not name lengths at all: `i < 40` is a SHA-1 round
boundary and `v >> 40` is a shift in the delta search's hash. So 79, against
a figure of nine that nobody had re-measured in eleven commits.

SHA-256 itself came out of `../sha2`, which already implements it against the
NIST CAVP vectors, so writing a second one here would have been a second
thing to check. What travelled is the SHA-256 compression function, its round
constants and its initial hash value, in the same shape as the SHA-1 beside
it; what did not travel is everything else in that file (SHA-224, SHA-384,
SHA-512 and the two truncated variants, HMAC, PBKDF2, HKDF), none of which an
object name uses. Calling out to sha2 as a library was the other option and
is what the collection's rules rule out: one C11 file, no dependency beyond
zlib, and a clone with no siblings has to build.

One thing sha2 has that did not come with the code: it derives all 192 of its
constants from the cube and square roots they are defined as, with
`tools/genk.py`, and diffs them against the source on every test run. Here
they are typed in. What catches a wrong digit instead is git, and it catches
it loudly, because one wrong bit anywhere in the compression function moves
every object name: a single altered digit in `k256[0]` fails 366 assertions.

### The oracle

`git hash-object` has no `--object-format` of its own, which is worth knowing
before going looking for one: the format comes from the repository it runs
in, so the name oracle is `git --git-dir=<a sha256 repo> hash-object`. The
same is true of `index-pack`, `verify-pack` and `fsck`. `show-index` is the
exception and takes the flag, because it reads an index and nothing else and
so has no repository to ask.

Everything in the sections above then runs a second time over the SHA-256
corpus: 64 names against `hash-object`, 126 objects swept loose and packed
against `cat-file -t`/`-s`/the raw bytes/`-p`, `ls` against `cat-file
--batch-all-objects --batch-check`, `verify` over both halves of the store,
abbreviated names against `rev-parse --verify`, the index against
`show-index`, `packls` against `verify-pack -v` for both delta encodings, 16
blobs written and read back through `cat-file blob` with `fsck --strict` over
the result, a tree rebuilt and compared against `git mktree`'s name for the
same lines, the pack read out loose and fsck'd, and a pack of our own whose
index `git index-pack -o` reproduces byte for byte.

That last one is the sharpest. A SHA-256 pack written by our own delta
search, 63 objects with 58 OFS_DELTA entries and a chain ten deep in 10128
bytes, produces an index `git index-pack -o` rebuilds byte-identically from
the pack alone, with nothing changed in the writer except the length of a
name.

### A store of one format read as the other

`gitobj` is handed an object directory, not a repository, so it cannot read
`extensions.objectFormat` the way git does: it is told, with
`--object-format=sha256` ahead of the subcommand. That makes "you forgot the
flag" a case rather than an impossibility, and it was a quiet wrong answer
until it was looked at. A 62-character filename is not 38 characters, so the
loose scanner skipped every object in a SHA-256 store as a stray file and
reported `0 objects`, exit 0.

It refuses now, and says which flag was wanted. A hex filename of exactly the
other format's length is not a stray file, it is an object whose format
gitobj has been told wrong. The index needs no such guard and never did: its
own checksum is over everything above it, and both the length of that
checksum and its position move with the format, so a SHA-256 index read as
SHA-1 fails the checksum and a SHA-1 index read as SHA-256 fails the size
arithmetic before that.

### Where the sanitizer loses a little

The small fixed buffers a name passes through are `HASH_MAX` and `HEX_MAX`
sized, 32 and 65 bytes, so under SHA-1 they are 12 and 24 bytes longer than
what sits in them. That is the shape this collection has found twenty-four
times and recorded against this repository once already, and it is a real
loss: a read one byte past a SHA-1 name inside `uint8_t id[32]` lands in the
same object and ASan sees nothing.

The two that are sized from a file are not like that, deliberately. The
index's name table is `hsz * n` bytes of a file trimmed to its own length,
and the list of every name in a store is one block with a runtime stride of
`hexsz + 1` rather than `char (*)[65]`, which would have left 24 unused bytes
per name in one allocation over 3321 names. Fixing the stride to 41 fails 525
assertions, so that choice is pinned rather than commented.

`make test-asan` runs the whole suite including the SHA-256 section, where
those same small buffers are exactly the size of what they hold, so the
format that has the blind spot is the one with the longer history behind it.

### What was measured

Fifteen mutations, fifteen caught, no survivors, each watched rather than
reasoned about:

    the --object-format flag made a no-op       638 failed
    one wrong digit in k256[0]                  366
    one wrong word of the initial hash value    366
    padding to 55 bytes rather than 56          370
    a left rotate where SHA-256 rotates right   366
    w[i-6] for w[i-7] in the message schedule   366
    the name list stride fixed at 41            525
    hexify stopping after 20 bytes              120
    the index name stride back to 20            276
    IDX_ENT back to 28                          276
    the pack trailer back to 20 bytes             3
    the REF_DELTA base name back to 20 bytes      4
    the tree entry stride back to 20 bytes        3
    mktree writing 20 bytes of name               2
    the other-format guard removed                2

The tree entry one survived on the first sweep, and finding out why cost the
harness two defects rather than one.

The fixture was a tree of a single entry. A walker whose entry stride is 20
bytes in a SHA-256 tree prints the first entry correctly and then dies on
what follows, so stdout was byte-identical to git's and only stderr and the
exit status differed. And the sweep compared stdout alone: `2>/dev/null` threw
the message away and nothing looked at the status, in the SHA-256 section and
in the SHA-1 per-object sweep above it, which has been that way since it was
written. Both now require the exit status as well as the bytes, which makes
the 1498-object sweep a stronger instrument than it was, and the SHA-256
corpus carries a tree of five entries with three different modes.

## What does not work

The hard invariant, that every object read hashes back to its own name,
covers every object in every corpus: 383 loose, and 3438 read out of fifteen
packs, 2019 of those through a delta chain, plus 372 out of four packs we
wrote ourselves, and 126 under SHA-256, 59 of those through a delta chain. It
said 490 of 3184 nine commits ago. The one thing `make test` does not cover is a pack over two gigabytes,
and `make bigpack` reads the INDEX of one; the objects of a pack that size
are out of reach of a reader that loads whole files.

`gitobj ls` and `gitobj verify` read a whole object store now, loose files
and packs together, and an object that is in both is listed once. `gitobj
cat`, `raw`, `type`, `size`, `hdr` and `msg` find a packed object too. What
none of them does is open a pack more than once per run, so the one-object
commands read every index and every pack in the store to answer about one
object: 3ms for a packed object in cc, where git is nearer a tenth of that.

Two recorded survivors are both the bound that keeps a varint or a zlib
stream off the pack trailer, and SHA-256 did not make either observable. The
trailer is 32 bytes there rather than 20, so the window the bound guards is
half again as wide, which was reason enough to re-run it rather than reason
about it: with the bound deleted the suite still reports 21139 passed, 0
failed. Every offset is checked against the start of the trailer when the
index is opened, so the bound only ever reaches the last entry's stream, and
no well-formed pack has one that runs over.

The CRC is the strongest thing available to an index reader, and it is not
the same claim. It says the packed bytes between two offsets are the bytes
git had when it wrote the index, which pins the offsets and the extents, and
says nothing about whether those bytes inflate to anything.

`PLAN.md` claimed all of the above as finished until an audit went looking.
Its hard invariant said the suite hashes "every object in every corpus
repository, loose and packed", its in-scope list described the v2 index, both
delta encodings and delta chains of any depth, and its oracle list included
`git verify-pack -v` diffed against a `gitobj packls`. Every one of those
exists now, seven commits after the audit, and the hard invariant is finally
the claim it had been making all along.

A pack over two gigabytes is out of `make test`'s reach, so what the suite
itself runs is an index it rewrites so that git resolves a real pack through
the table, and an index carrying offsets by hand. `make bigpack` is the one
that builds a real one, and it is a separate target because it writes 5GB;
its section above says what it produced and when.

`.rev` files are ignored in both directions. `git pack-objects` writes one
beside every pack it makes and nothing here looks at it, so the reverse
mapping from offset to object is recomputed by sorting instead of read, and
`gitobj pack` does not write one.

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

A tree is the only object gitobj constructs out of anything but bytes handed
to it: there is no commit or tag builder. Packs are written now and have
their own section above, with three things they cannot do. Every object goes
into memory inflated before the search starts, so packing a repository larger
than memory is out, and with it the 64-bit offset, which needs a pack over
two gigabytes. REF_DELTA is read and never written, since OFS_DELTA is
shorter and `git gc` writes that. There is no `--stdout`, no thin pack and no
`.rev` file beside what we write.

Those paragraphs used to be one line saying the whole thing was read-only,
which it was until the writer landed. `PLAN.md` had listed `write` and
`mktree` as though both existed for a good while before either did.

SHA-256 repositories are read and written, with the format given on the
command line. What is not here is git's way of knowing which one it is:
`extensions.objectFormat` is in a repository's config and `gitobj` is given
an object directory, so nothing reads the config and the flag is not
optional. Pass the wrong one at a loose store and it refuses, naming the flag
it wanted; pass the wrong one at an index and the index's own checksum
refuses it. No ref parsing, no `--batch` protocol, no index or worktree. An object is addressed by its name or by four or more hex
characters of it, and nothing else: no `HEAD`, no `main~3`, no `:path`, none
of the rest of git's revision syntax.

No `.mtimes`, bitmap or multi-pack index files, no cruft packs, no promisor
or partial clones. Alternates are read, including nested and relative ones,
but a C-quoted path in the file is not: git accepts a line beginning with a
double quote as a quoted path, nothing writes one in practice, and such a
line is taken literally here and the directory is then simply not found. No
v1 pack index: it is refused by name rather than read, since it has no CRCs
and git has not written one since 2007.

Not fast. Every object is inflated from scratch, a delta is re-applied for
every object on its chain whose base has fallen out of the cache, and a
command that wants one object opens every pack in the store. `make test`
takes 53 seconds, where it took 10 before it read any packs, and `make
test-asan` 3m5s; most of that is processes rather than work, at six of them
per object over the 1498 the per-object sweep covers and six more over the
126 the SHA-256 one does. Writing is not the slow part: 538 objects of
`../cc` pack in 4.1 seconds with a window of 10, in 42MB.

## Why this file exists

The house convention here is that every repo has a `README.md` stating what
does *not* work, and this repo did not have one. `gitobj.c`'s header comment
pointed at it (`See README.md`), and so did a comment in `t/run.sh` pointing
at a "section 9" that did not exist either: the file stopped at section 5.
It stops at 15 now, and section 9 is the pack walk that comment was pointing
at, written eight commits after the pointer to it. Those two pointers and
the `PLAN.md` prose were the only places the pack gap was acknowledged, and
all three described it as finished.

## License

GPL-3.0-or-later.
