# gitobj

## Contract

`gitobj` is a reader and writer for git's object database: one C11 file, no
libraries, no shelling out to git.

```
gitobj hash   <type> [FILE]            name an object without storing it
gitobj cat    <objdir> <sha>           like `git cat-file -p`
gitobj raw    <objdir> <sha>           the payload bytes, no pretty-printing
gitobj type   <objdir> <sha>
gitobj size   <objdir> <sha>
gitobj hdr    <objdir> <sha> <key>     a commit/tag header's value(s)
gitobj msg    <objdir> <sha>           a commit/tag message, byte-exact
gitobj ls     <objdir>                 every object: sha, type, size
gitobj verify <objdir>                 hash every object against its own name
gitobj write  <objdir> <type> [FILE]   store a loose object, print its name
gitobj mktree <objdir>                 git-mktree format on stdin, store a tree
gitobj idx    <pack.idx>               `git show-index` layout: offset, name, crc
gitobj idxcrc <pack.idx>               every CRC against the pack beside it
gitobj packls <pack.idx>               `git verify-pack -v` layout
gitobj packverify <pack.idx>           hash every packed object against its name
```

`packls` is not `idx` under another name. Its columns are the pack entry's
type, its inflated size and its size in the pack, and the first two come out
of the pack rather than the index. It reads entries stored whole and stops at
the first delta, so over a pack git chose the layout for it reports the first
few dozen objects and then refuses. Nothing else is planned and absent from
this list, which it has been wrong about before: `write`, `mktree` and the
three pack commands were all listed here as though they existed before any
of them did.

In scope:

* loose objects: zlib-wrapped `<type> <len>\0<payload>`, read and write.
  Written as stored blocks, renamed into place, and left alone if the name
  is already there.
* the four object types: blob, tree, commit, tag. Trees are parsed and
  pretty-printed the way `git cat-file -p` does. Commits and tags are parsed
  into headers (including multi-line folded ones, such as `gpgsig`) plus a
  byte-exact message.
* tree construction, with git's sort order: entries compare as if a
  directory name carried a trailing slash, so `a.c` sorts *before* `a`.
  `mktree` reads `git ls-tree` format on stdin, C-quoted names included,
  sorts it and stores the tree. It does not look its entries up in the
  object store, so unlike `git mktree` it will not notice an entry whose
  object is absent or of another type; `git fsck` is what catches that.
* tree entry modes: `100644`, `100755`, `120000`, `40000` (stored without
  the leading zero) and `160000` gitlinks.
* pack entries stored whole: the type/size varint, whose first byte is split
  into a continuation bit, three bits of type and four bits of size, with
  seven bits per byte after that, and the zlib stream behind it, checked
  against the size the varint declared. An entry's extent comes from the
  next offset in PACK order, which is `git verify-pack -v`'s fourth column.
* `REF_DELTA`, whose base is a 20-byte name rather than a distance, so the
  base can sit either side of the entry that uses it and finding it is a
  binary search over the index's names. A base the pack does not hold is a
  thin pack, which git only sends down a wire, and is refused.
* `OFS_DELTA`, whose base is a distance backwards in a varint of its own
  where each continuation byte adds one before shifting, and the delta it
  carries: a base size and a result size, then copy and insert instructions,
  where a copy's offset and length come from whichever of seven following
  bytes the instruction byte's bitmap claims are present. An absent byte is
  0, except that an absent length is 0x10000. Chains of any depth, bounded
  at 256 links because the reader recurses.
* the pack v2 index: the 256-entry cumulative fanout checked against the
  sorted name list it indexes, the CRC of every object's packed bytes checked
  against the pack, and both offset encodings, including the escape into the
  64-bit table for an offset at or above 2^31. A v1 index is refused by name.
  The pack header is read only to cross-check its object count and its
  trailing checksum against the index; nothing else in the pack is parsed.

In scope and NOT YET WRITTEN. Listed here without that qualification until
an audit pointed out there was no pack code in `gitobj.c` at all. The index
was the first part of it to exist and the walk over entries stored whole is
the second:

* writing anything but a loose object: no packfile writing, no
  `unpack-objects`. This said `gitobj` was read-only, which it was until
  `write` landed, and listed `mktree` among the missing until that landed
  too. A tree is still the only object `gitobj` constructs: there is no
  commit or tag builder.

Exit status: 0 success, 1 refused or not found, 2 the command line was wrong.

## Hard invariant

Every object read hashes back to its own name. A git object's name is the
SHA-1 of `<type> <len>\0<payload>`, so the name is a checksum over the entire
decode path: the zlib stream, the loose header, the pack type/size varint, the
OFS_DELTA offset varint, every copy and insert instruction, and every link of
the delta chain beneath it. If a single byte of any of that is wrong the hash
does not match. It is the one assertion that cannot be satisfied by being
self-consistently wrong.

**It covers every object in every corpus:** 369 loose, and 3186 read out of
thirteen packs, 2016 of those through a delta chain and 2815 of them in
eight sibling histories. It said "loose and packed" for a good while before any
pack code existed, which was the strongest claim in the file and the one
that was not true; it covered 490 of 3184 two commits ago. What is still out
of reach is a pack this suite cannot build, one over two gigabytes, and a
pack built to be wrong rather than by git, which is the refusals item.

The index has its own invariants, and they are cross-checks rather than
hashes: the fanout must agree with the name list it indexes, the CRC must
agree with the pack bytes between one offset and the next, and the declared
object count must agree with the file's own size. The first and the third
are what a reader can check with no other file open.

The other half of the invariant is that git accepts what we write, and that
half now runs for loose objects and for trees we construct ourselves:
`gitobj write` re-serialises an object and `gitobj mktree` builds one out of
entry lines, and `git fsck --strict` and `git cat-file -p` read both back.
It does not run for pack writing, which is still absent.

## Oracle

Ranked, strongest first, by how little of it we control.

1. The object name itself. Not an oracle we wrote: git chose the filename
   and the index entry, we recompute the hash. Applies to every object in
   every corpus, with no fixtures to maintain.
2. `git cat-file -p` / `-t` / `-s`, object by object, over every object of
   the small corpus, loose and packed: 1375 objects, 1006 of them out of a
   pack. git chooses the set, through `cat-file --batch-all-objects`, so
   the sweep covers what is in the store rather than what it went looking
   for. The tree pretty-printer, the mode formatting and the raw commit and
   tag bytes are all pinned here.
   `git cat-file --batch-all-objects --batch-check` against `gitobj ls`
   over a whole store is the same oracle at a coarser grain and a wider
   reach: 3307 objects over 12 repositories, compared line by line.
3. `git fsck --strict` and `git cat-file -p` over a bare repository whose
   every object `gitobj write` and `gitobj mktree` put there. git inflates
   our zlib stream, re-hashes it and parses the trees and commits, so this
   is the read oracles run backwards, with git on the far side of the
   serialiser. For a tree it is also the only oracle for the entry ORDER
   that does not come from comparing names: fsck calls a misordered tree
   treeNotSorted.
   `git mktree` itself is the name oracle: it sorts its own input, so it and
   `gitobj mktree` can be handed the same unsorted lines and must produce
   the same object name.
4. `git log --format=` for the parsed commit fields (`%T`, `%P`, `%an`,
   `%ae`, `%ad --date=raw`, `%e`), and `git cat-file -p` for the message
   bytes, so CRLF and trailing whitespace are checked as bytes, not as
   a description.
5. `git show-index`, `git verify-pack` and `git index-pack -o` over a pack
   index. The first prints an offset, a name and a CRC per object and reads
   nothing but the index, which is the only reason a hand-built 64-bit
   offset table can be checked at all. The second reads the index and the
   pack together and is the authority on whether an index we accept is one
   git accepts, including for every corrupt fixture. The third builds an
   index from the pack alone, so a corpus index is compared against one git
   wrote today from the same bytes.
6. `git verify-pack -v`, column for column and object by object, over every
   pack in reach: 3433 objects, 2016 of them deltas. The type and the size
   come out of the entry header, the size in the pack out of the index's
   sorted offsets, and the chain length and base name out of the walk down
   the chain. The suite also builds a `--window=0` pack and has git assert
   that it holds no delta, which is the only way the whole-entry path is
   distinguished from the delta path in the comparison.
7. ASan + UBSan over the whole suite (`make test-asan`), with both the index
   and the pack trimmed to exactly the bytes read, since `readall()` doubles
   and a buffer bigger than its data turns the sanitizer off. The hostile
   input it most wants is in section 10: eleven hand-built packs that lie
   about a length, and 300 fuzzed ones.

Item 3 was one of four oracles struck off this list for not existing, and
items 5 and 6 are a second one arriving in pieces. What is missing from item
6 is a pack over two gigabytes, which the suite cannot build. Repacking for
an encoding the corpus lacks was one of the other two struck-off oracles and
now exists, as the `--no-delta-base-offset` and `--window=0` fixtures. The
last one still missing is a mutation sweep driven from the suite rather than
by hand.

## Non-goals

* Writing packfiles. No delta compression, no `.idx` generation, no
  `pack-objects`. Reading them is the interesting half.
* SHA-256 repositories. `extensions.objectFormat = sha256` is refused.
  Everything here assumes 20-byte names.
* Reachability. No ref parsing, no `rev-parse`, no abbreviated names, no
  `--batch` protocol, no index/worktree. Objects are addressed by full
  40-character name only.
* The pack `.rev`, `.mtimes`, bitmap and multi-pack index files, cruft
  packs, promisor/partial clones, and alternates (`objects/info/alternates`).
* Writing with any real compression. Loose objects are emitted as zlib
  stored blocks, which git reads perfectly and which grow the file by ~0.03%:
  five bytes of block header per 65535 of payload, plus six of framing. That
  is the whole of the compression side, and Milestone 1 is where it changes.
* Being fast. When there is a pack reader, every object will be inflated
  from scratch with no delta base cache, so walking a pack will be
  O(objects * chain depth) inflations. There is no pack reader either; this
  file says so at the top and then described both in the present tense.

## Commit sequence

- [x] SHA-1, the loose-object header, `gitobj hash`
      why: the object *name* is the project's hard invariant, so the thing
      that computes it comes first and is checked against `git hash-object`
      before anything else exists to be wrong.
- [x] vendor the DEFLATE decoder from `../inflate`, add RFC 1950 framing,
      read a loose object: `cat`/`raw`/`type`/`size` for blobs
      why: every object in the database is behind a zlib stream, so nothing
      can be read until this works. The decoder travels instead of being
      rewritten because `../inflate` already owns its oracle.
- [x] `gitobj verify`: hash every loose object against its filename
      why: this is the hard invariant, and it is cheaper to wire up now than
      to retrofit once the pack reader is also producing objects.
- [x] the tree parser and `git cat-file -p` pretty-printing
      why: the only object type whose `-p` output is not its raw bytes, and
      the first place the mode encoding can be wrong.
- [x] the commit/tag header parser: `hdr`, `msg`
      why: multi-line folded headers (`gpgsig`) and a byte-exact message are
      where "parses my own commits" and "parses git's" diverge.
- [x] loose object write: zlib stored blocks, `gitobj write`
      why: the second half of the oracle. Until git can read what we write,
      only one direction is tested.
      files: gitobj.c (zdeflate_stored, objhdr, loose_write, the `write`
      command), t/run.sh section 6, README.md
      proves: `git fsck --strict` and `git cat-file -p` read a bare
      repository whose every object we wrote, and the name we print for each
      is the name git gave it. Payload sizes 0, 1, 2 and six values around
      the 65535-byte stored-block edge (plaintext exactly on it at 65524,
      and twice over at 131058) go in and come out of `git cat-file blob`
      byte for byte. 1937 assertions before, 2049 after.
      found: ten planted defects, eight of them red. Flipping BTYPE to 01,
      clearing BFINAL, copying LEN into NLEN instead of complementing it,
      adding 1 to the Adler-32, dropping the header NUL and breaking the
      zlib FCHECK each fail 43 assertions; a 65536-byte block fails 10, all
      of them at or past the boundary; making the write a no-op fails 63.
      The two survivors are the same mutation twice: a zlib header declaring
      a 4KiB or a 256-byte window ({0x58,0x85}, {0x08,0x1d}) is accepted by
      git and by us, correctly, because a stored block never references the
      sliding window, so the field is unobservable. The first of those was
      written as a defect and is not one.
- [x] tree sorting and `gitobj mktree`
      why: the trailing-slash rule is the single most commonly wrong thing in
      a git reimplementation, and `git mktree` sorts its own input, so the
      two can be fed the same unsorted lines and compared.
      files: gitobj.c (mentcmp, unquote_name, parse_mkline, tree_build and
      the `mktree` command), t/run.sh section 7 plus three payload shapes in
      section 6, README.md
      proves: every tree in the mode/commit/tag fixture is rebuilt from its
      own `git ls-tree` listing in three input orders -- as printed,
      reversed, and sorted by name as plain bytes -- and gitobj, `git
      mktree` and the name git originally gave the tree all agree on all
      three. `git cat-file -p`, `-t` and `-s` read the results, and `git
      fsck --strict` is clean over a bare repository every tree in which we
      built: the fixture's own trees are deliberately withheld when its
      objects are copied in, so no tree there can have been found already
      present. The slash fixture (a-b, a.c, a, a0, aa, with a directory
      named "a") is also checked against a python SHA-1 of the
      plain-byte-order tree, which must NOT be what we produced, so the
      section cannot pass against a sorter that ignores the rule. 2049
      assertions before, 2303 after; 1751 to 1862 cloned alone.
      found: eleven planted defects, eleven red, no survivors. Deleting the
      trailing-slash rule fails 52 assertions and TWO of them are `git fsck
      --strict`, which calls the result treeNotSorted -- so the entry order
      has an oracle that is not a name comparison. Reversing the order fails
      52, sorting nothing 26, plain memcmp with no tie-break 26, printing
      the mode as %06o 50, dropping the entry NUL 70, ignoring C-quoting 49,
      reading an octal escape as decimal 47, never storing the object 27,
      accepting any octal mode 2, dropping the slash check 1.
      found: UBSan caught `qsort(NULL, 0, ...)` on the empty tree, which the
      optimised build happened to get right. `bwrite(dst, NULL, 0)` was the
      same undefined call one layer down and is now guarded once for every
      caller rather than at the two sites that reach it today.
      found: in the harness, not the code. The new empty-blob payload is the
      same object as the existing 0-byte case, so counting it again made the
      written-object counter disagree with git's object count by one. The
      count is cross-checked against `cat-file --batch-all-objects`, which
      is the only reason it showed up.
- [x] the pack v2 index: fanout, names, CRCs, 32- and 64-bit offsets
      why: the pack is unreadable without it, and the fanout table is a
      self-checking structure (it must end at the object count).
      files: gitobj.c (be64, dieat, dieval, bexact, idx_open, idx_offset,
      crc32z, pofscmp and the `idx` and `idxcrc` commands), t/run.sh
      section 8, README.md
      proves: 1486 index entries over 9 packs, offset, name and CRC each,
      compared per object against `git show-index` rather than per pack: a
      whole-file diff over a thousand objects says only that something
      somewhere disagreed. Every CRC is recomputed from the pack bytes
      between one offset and the next, which means the extents are checked
      too, since the index is sorted by name and the extents only exist
      once the offsets are sorted. `git verify-pack` accepts all 9 indexes
      and `git index-pack -o` rebuilds each one byte for byte from its pack.
      2591 assertions before, 4472 after; 1862 to 2324 cloned alone, which
      is the number to quote.
      proves, for the 64-bit offset table: 134 objects reach it, and the
      same 134 in a standalone clone, because no pack in any corpus is over
      two gigabytes and none ever will be. 122 of them are a real pack whose
      index the suite rewrites to route every offset but the first through
      the table: `git verify-pack` reads the pack through it, `git cat-file`
      gets blob content out of a repository whose only index is that one,
      and `git fsck` is clean. The other 12 are offsets no pack here could
      have, 2^31-1 through 2^64-1, where `git show-index` is the oracle
      because it reads the index and nothing else. The first of those is
      BELOW 2^31 and still goes through the table, so the indirection is
      tested apart from the magnitude.
      proves, for refusals: 11 corrupt indexes and 4 bad index/pack pairs,
      each refused with a position and the message asserted, not just the
      exit status. `git verify-pack` refuses all 15; `git show-index` sees 4
      of the 11 and the suite says which 4 and why. A fanout entry that
      disagrees with its names is the one corruption with a consequence
      rather than a parse error: `git cat-file -e` can no longer find the
      object it misplaces, and that is an assertion.
      found: `idxcrc` segfaulted on the first fixture that pointed an offset
      past the end of the pack. It validated each offset in the loop that
      used it, and an object's length comes from the NEXT offset, so one
      bogus entry made its PREDECESSOR's extent run off the end of the pack
      while the predecessor's own offset was fine. Offsets are all checked
      before any extent is derived from one now.
      found: git allows at most n-1 large offsets, because the first object
      in a pack is at offset 12 and can never need one. An index routing all
      n through the table is one `git verify-pack` calls "wrong index v2
      file size". That was the first fixture built here and the limit was
      news; gitobj enforces it, and the over-full index is a refusal case.
      found: the sanitizer could not see this parser. `readall()` doubles, so
      a 4MB pack sat in an 8MB block. Both files are trimmed to exactly what
      was read, and with the two index size checks deleted the trimmed build
      reports a heap-buffer-overflow on a 20-byte name comparison where the
      untrimmed build reports nothing, reads 140 names out of the rounded-up
      allocation, and refuses the file for an unrelated reason.
      found: 31 mutations, 30 red, 1 survivor. Seven survived the first
      sweep and five of those were the FIXTURES, not the code. Deleting the
      fanout monotonic check changed nothing because the fixture put the
      backwards step next to a non-empty bucket, where the walk over the
      names catches it; the fixture uses an empty bucket now, which is the
      blind spot the check is for. Three fixtures were two lies rather than
      one (a raw-byte edit left the index checksum broken, so the checksum
      check fired and the check under test was never reached) and every
      fixture carries a correct checksum now. There was no duplicate-name
      fixture at all, so relaxing the name comparison from `<=` to `<` was
      invisible. The last two, deleting the index size arithmetic and
      deleting the duplicate-offset check, leave the file still refused for
      a different reason with the same exit status, and die only on the
      message text, which is why every refusal asserts its message.
      survivor: trimming the file buffers. No assertion fails without it,
      by construction, and the measurement above is what it is for.
- [x] the pack walk: type/size varint, non-delta objects, `packls`
      why: gets `verify-pack`'s first five columns under oracle before the
      delta machinery, so a later failure is unambiguously a delta bug.
      files: gitobj.c (PACK_HDR, the Pack struct, pack_open, pack_close,
      pack_extent, pack_entry_hdr, pack_at and the `packls` and `packverify`
      commands; `idxcrc` now opens its pack through pack_open instead of
      inline), t/run.sh section 9 plus a report line in section 2,
      README.md
      proves: all 121 objects of a `--window=0` pack compared against
      `git verify-pack -v` line by line, per object rather than as a file
      diff, and all 121 hashed back to their own names. A pack git chose
      the layout for is refused at its first delta entry while
      `git verify-pack` reads that same pack, which is the pair a missing
      feature needs. The census on stderr says how many entries were read
      whole, so the whole section cannot pass having read nothing.
      5211 assertions before, 5358 after; 2324 to 2471 cloned alone, which
      is the number to quote.
      found: the self corpus cannot produce a delta. Its blobs are a few
      dozen bytes and git does not attempt a delta below 50, so a
      `pack-objects` of it has none whatever window it gets, and the first
      version of this section built a `--window=0` pack and then found the
      ordinary pack had nothing to refuse either. A corpus of its own was
      the answer: 40 revisions of a 400-line file, a tree per revision that
      grows by one entry, and a commit per revision, which git packs into
      121 objects of which 74 are deltas, deepest chain 9. The trees are
      what make it worth having, since a delta entry inherits its type from
      the end of its chain and a corpus whose deltas are all blobs cannot
      see where the type came from.
      found: the per-object `cat-file` sweep no longer reaches a single
      sibling. All eight have been repacked and hold no loose object at
      all, so the sweep the README described as running over cc, tarx and
      inflate runs over the self corpus alone. Its floor of 20 objects was
      being cleared entirely by the corpus the suite builds itself, and the
      sweep now prints which repositories it got its objects from rather
      than only how many it found.
      found: seven planted defects, six red. The type nibble read from bits
      0 to 2 fails 9 assertions, the size nibble taken as three bits rather
      than four fails 5, the varint resuming at bit 7 instead of bit 4
      fails 6, and an extent derived from the next INDEX entry rather than
      the next offset in pack order fails 8, all of them CRC comparisons in
      section 8. Accepting type 5 and dropping the check that an entry
      inflated to its declared size each fail 2, and both needed a pack
      edited by hand: nothing git writes is wrong in either way, so the
      fixture re-stamps the four checksums an edit invalidates and
      `gitobj idxcrc` accepting the pair is the guard that it is a single
      lie.
      survivor: treating the 20-byte pack trailer as entry data. Every
      offset is checked against the start of the trailer when the index is
      opened, so the bound only matters to a varint or a zlib stream that
      runs off the end of the LAST entry, and no fixture does that. It
      belongs to the refusals item below.
- [x] OFS_DELTA: the negative-offset varint
      why: a *different* varint from the size encoding, and the one most
      readers get wrong: `(ofs + 1) << 7`, not a plain shift.
- [x] delta application: the copy/insert instruction stream
      why: the optional-byte bitmap with its 0 and 0x10000 defaults is the
      other classic bug, and refusing an oversized result size belongs in
      the same commit as the allocation it guards.
      files: gitobj.c (DELTA_MAX_DEPTH, the Ent struct, pack_ord,
      pack_census, pack_ofs_delta, delta_size, delta_apply, and pack_at
      grown into a recursion), t/run.sh section 9, README.md
      proves: `gitobj packls` is byte-identical to `git verify-pack -v`
      over all eleven packs in reach, compared per object: 3186 objects,
      1934 of them deltas, chains up to 29 deep, 2815 of the objects in
      eight sibling histories nothing here arranged. All 3186 hash back to
      their own names, which is the hard invariant reaching packed objects
      for the first time. The census of how many entries took the delta
      path, and of the deepest chain walked, is compared against git's own
      figures out of `verify-pack -v`'s field count and sixth column, so a
      run in which the delta code never fired could not agree.
      5358 assertions before, 8477 after; 2471 to 2735 cloned alone, which
      is the number to quote.
      found: `verify-pack -v`'s size column for a delta entry is the length
      of the DELTA DATA, not of the object the delta produces. Its type
      column is the resolved type. So the line mixes what the entry says
      with what it decodes to, and printing the resolved size there
      disagrees with git on every delta in every pack.
      found: plumbing `pack-objects` writes REF_DELTA. It leaves
      `pack.useDeltaBaseOffset` off where `git gc` and `git repack` pass
      `--delta-base-offset`, so every pack in the collection is OFS_DELTA
      and the fixture built to exercise OFS_DELTA was the other encoding
      entirely. The section went red because REF_DELTA is still refused,
      which is the only reason it did not pass as an OFS_DELTA test that
      never read an OFS_DELTA. That refusal is also what pins the encoding
      of each fixture, since `verify-pack -v` prints a chain length and a
      base name whichever encoding carried them.
      found: the corpus could not reach the copy instruction's implicit
      length of 0x10000. git's encoder omits a copy's length bytes for
      exactly that value and splits any longer run into pieces of it, so it
      needs a base of at least 64KB, and the fixture's blobs were 400 lines
      each. Taking the absent length as 0 died in the collection, where cc
      has big blobs, and SURVIVED in a standalone clone. Three revisions of
      a 20000-line file are in the fixture now and it dies in both.
      found: fourteen planted defects, eleven red, counting the pack walk's
      seven again against the bigger suite. The OFS_DELTA varint without
      its `+ 1` fails 45 assertions, the copy bitmap read as three offset
      bytes and four length bytes fails 45, a delta header varint shifted
      by 8 instead of 7 fails 45, an absent copy length taken as 0 fails
      10, and a chain length reported as 1 for every delta fails 680, one
      per delta entry in the corpus.
      survivor: the delta's declared base size, checked against the base,
      and its declared result size, checked against what was produced.
      Neither can fire on a delta git wrote, so both want a pack built by
      hand, which is the refusals item below. Recorded in the README rather
      than counted as covered.
- [x] REF_DELTA, and chains whose base is itself a delta
      why: the corpus has no REF_DELTA in it, so the suite has to make git
      produce one; depth is only meaningfully tested past 2.
      files: gitobj.c (idx_find, the REF_DELTA arm of pack_at, nofs and
      nref in the census), t/run.sh section 9 and the dropname edit in
      packedit.py, README.md
      proves: the same 124 objects packed a third time with
      `--no-delta-base-offset`, compared against `git verify-pack -v` per
      object and column for column, deepest chain 15. Both encodings give
      every object the same name and type, and all 124 hash back out of
      both packs. The discriminator for which encoding a pack holds is a
      census of the two kinds of LINK, counted at every level of every
      chain: nothing in `verify-pack -v` says, since it prints a chain
      length and a base name whichever encoding carried them. The
      OFS_DELTA fixture must resolve no ref-delta link, the REF_DELTA
      fixture no ofs-delta link, and every corpus pack no ref-delta link
      at all, which is the assertion that says why the fixture has to
      exist.
      proves, for a base the pack does not hold: a fixture that stops the
      index naming one object and tells the pack header it holds one
      fewer, leaving the base's bytes where they were. Refused by name,
      and by `git verify-pack` too. That is the whole handling of a thin
      pack, which git sends down a wire and never stores.
      8477 assertions before, 8622 after; 2735 to 2872 cloned alone.
      found: four planted defects, three red. Leaving the 20-byte base
      name in front of the zlib stream fails 10, and so does a bucket
      lower bound off by one in the index lookup. Not refusing a missing
      base fails exactly ONE assertion and that one is the message: it
      reads the wrong base instead, and the delta's base-size check then
      refuses the file anyway with the same exit status. Third mutant here
      to survive everything but a message assertion.
      survivor: searching the whole name list instead of the one fanout
      bucket. Written as a defect and is not one. The names are globally
      sorted and a bucket is a contiguous range of them, so the fanout
      saves eight comparisons and changes no answer.
      found: the delta search in `pack-objects` is threaded and not
      reproducible. Two runs over the same objects gave 76 delta entries
      and then 75, which is a fixture whose shape moves between runs.
      `--threads=1` pins it, at 79 deltas and a deepest chain of 15.
- [x] the full `verify-pack -v` diff, and `verify` over packed objects
      why: the strongest oracle in the project, and it cannot be written
      until every column it prints can be computed.
      files: gitobj.c (loose_exists, Packs, packs_open, packs_close,
      obj_get, store_names, obj_read moved below the pack section, and
      `ls`/`verify` over a whole store), t/run.sh sections 2, 3 and 9,
      README.md
      proves: `gitobj ls` is compared against `git cat-file
      --batch-all-objects --batch-check` over every corpus repository
      whole, line by line: 3307 objects over 12 repositories, 369 loose
      and 2938 packed. `gitobj verify` hashes all 3307 back to their own
      names. The per-object `cat-file` sweep now covers every object of
      the small corpus rather than its loose ones, 1375 objects of which
      1006 come out of a pack, with `type`, `size`, `raw` and `cat -p`
      each compared per object.
      proves, for de-duplication: a bare repository holding every object
      BOTH loose and packed, which nothing else here is, since the self
      corpus has no pack and every sibling has no loose object. git lists
      such an object once and so must we, and the census says the loose
      copy is the one that was read, which is the order git looks in.
      8622 assertions before, 16746 after; 2872 to 4133 cloned alone.
      found: a standalone clone had no packed object in its corpus at all,
      so both new floors failed there and every comparison in sections 2
      and 3 was over loose objects only. One of the four self-built
      repositories is moved wholesale into a pack now. `git repack` could
      not do it: nothing in those repositories is reachable from a ref, so
      it leaves 119 of the 120 blobs loose.
      found: three planted defects, three red. Listing loose objects only
      fails 378 assertions, dropping the de-duplication fails 3 and only
      against the both-copies fixture, and reading packs before loose files
      fails 1546.
      found: the suite went from 10 seconds to 34. The per-object sweep is
      most of it, at six processes per object over 1375 objects, and the
      rest is that a one-object command opens every pack in the store.
- [x] refusals: OBJ_MAX, truncation, bad varints, mutation fuzz, `test-asan`
      why: every length in a pack is attacker-chosen, and a 4GB delta
      result must be refused, not allocated.
      files: t/run.sh section 10, which is a pack GENERATOR rather than a
      mutator, and no change to gitobj.c at all: every check this reaches
      was already written and none of them had a fixture.
      proves: eleven fixtures lying about one thing each, every one refused
      by name and by `git verify-pack` as well. A delta whose declared base
      size is not the base's, a copy and an insert each overrunning the
      declared result, a delta producing less than its declared result, a
      result size and an entry size above OBJ_MAX, an instruction byte of
      0, a copy reaching past the end of the base, an OFS_DELTA at a
      distance of zero and one pointing before the pack header, a REF_DELTA
      naming itself, and a pack cut off mid-entry.
      proves, for the generator itself: git accepts the well-formed control
      and resolves its chain, `git index-pack -o` rebuilds its index from
      the pack alone byte for byte, and `git cat-file blob` hands back the
      bytes we do out of a repository whose only object source is that
      pack. The control is a 70000-byte blob, an OFS_DELTA of it and a
      REF_DELTA of THAT, so one pack carries both encodings, a base that is
      itself a delta, and a copy of exactly 0x10000 with its length bytes
      absent.
      proves, for the fuzz: 300 mutants of the control, one flipped bit
      each anywhere in the entry area, with both checksums and every CRC
      recomputed so the flip is the only lie. Per mutant, that gitobj
      either succeeds or refuses cleanly and nothing else, and that gitobj
      and git agree on whether the pack is still readable, which is a
      comparison and not an opinion because `packverify` hashes every
      object back to its name. 299 refused for 13 distinct reasons, 1 still
      readable, and the NUMBER OF REASONS is asserted too: most of a pack
      is zlib stream, so most flips are caught by the Adler-32, and a
      fuzzer reaching only that check has tested one check.
      16746 assertions before, 17099 after; 4133 to 4486 cloned alone.
      found: without recomputing the checksums, every fuzz mutant is
      refused by the pack checksum and the fuzzer reaches no length field
      at all. That is the same shape as the index fixtures that were two
      lies rather than one.
      found: the fuzz earns itself. Dropping the check that an entry
      inflated to the size it declares is caught by its own fixture and
      independently by two of the 300 mutants.
      found: ten planted defects, nine red. The two result-size bounds
      needed a fixture each and not one shared one: a declared result
      SMALLER than what the instructions produce is caught by whichever
      instruction overruns it first, so the final equality check needs a
      declared result LARGER than what came out, and the insert bound needs
      a delta whose first instruction is the one that overruns.
      survivor: the bound that keeps a varint or a zlib stream off the
      20-byte pack trailer, and it is unobservable rather than untested.
      Every offset is checked against the start of the trailer when the
      index is opened, so the bound only reaches the LAST entry's stream,
      and no well-formed pack has one that runs over. The truncation
      fixture does reach it and the only difference is which inflate error
      comes out: in place it gives "bad literal/length code at 658",
      extended over the trailer "distance reaches before output start at
      658". Both refuse at the same offset. Pinning the suite to that text
      would pin it to where a cut happened to land, so the measurement is
      in the README instead.
- [x] the three sabotages, recorded in the README
      why: a suite whose failure has never been observed is not evidence.
      The delta copy instruction, the tree sort and the object header each
      get broken on purpose and the damage written down.
      files: README.md only. The three defects were planted, measured and
      reverted; nothing in the repository carries one.
      proves: the object header returning its length without the NUL fails
      291 assertions, all of them the write oracle, where git reads back an
      object under a name it does not agree with. Deleting the tree sort's
      trailing-slash rule fails 52, two of them `git fsck --strict` calling
      the result treeNotSorted. Reading the delta copy bitmap as three
      offset bytes and four length bytes fails 3155, beginning with `gitobj
      verify` over the siblings, which is the hard invariant itself.
      found: the same sabotage measures the suite and not the defect. The
      copy-bitmap one failed 45 assertions three commits ago and fails 3155
      now, because `ls` and `verify` read packs in between. The header one
      went from 43 against a suite of 2303 to 291 against one of 17099.
      That is the argument for re-measuring rather than quoting: two of the
      three numbers already in this file were stale.
- [ ] README and PLAN
      why: a README that lists only successes is not finished.

### Milestone 1: the gaps that bite real users

- [ ] a real `zinflate` for writing, or vendor `../inflate`'s encoder
      why: stored blocks mean `gitobj write` produces a loose object ~1.0003x
      the payload size where git produces ~0.3x. git reads it, so nothing is
      broken, but no one would use this to write a real repository.
- [ ] a delta base cache, so a chain of depth N costs N inflations once,
  not N inflations per object in it
      why: `packls` over a whole pack would be the slowest thing in the
      suite, and the fix is a four-entry LRU keyed on pack offset. (`packls`
      does not exist; see the note at the head of this file.)
- [ ] an index git itself wrote with a 64-bit offset in it
      why: the escape is exercised now, by an index the suite rewrites so
      that git resolves a real pack through the table and by offsets written
      in by hand, both with git as the oracle. What no fixture can be is a
      pack over two gigabytes, so the one thing still untested is an index
      git PRODUCED with a large offset: `git index-pack` choosing the escape
      itself. That needs 2GB of pack and a suite willing to spend it.
- [ ] `gitobj write` for packed input, i.e. unpack-objects
      why: the natural completion of having both halves, and it makes the
      three-hop `pack -> loose -> git fsck` round trip possible.
- [ ] abbreviated object names, by binary search over the index fanout
      why: every human-facing git command takes a 7-character prefix, and
      the fanout is read now, so this is a ten-line function over `idx_open`
      plus the ambiguity check. It also needs the loose objects, where the
      fan-out directory does the same job.
- [ ] `objects/info/alternates`, so a repository whose objects live in a
      borrowed object store can be read at all
      why: every `git clone -s` and most CI caches look like this, and we
      currently report "object not found" with no hint why.
- [ ] write packfiles: delta search, `.idx` generation, `verify-pack` on our
      own output
      why: the one direction of the format that is entirely unimplemented,
      and the only way to close the loop on the delta encoders.
- [ ] SHA-256 repositories
      why: 20 is hard-coded in nine places. The format is otherwise
      identical and the work is mostly mechanical, but it needs a corpus
      built with `--object-format=sha256` to be worth anything.
