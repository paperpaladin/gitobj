# gitobj

## Contract

`gitobj` is a reader and writer for git's object database: one C11 file, no
libraries, no shelling out to git.

```
gitobj [--object-format=sha1|sha256] <command> ...
gitobj hash   <type> [FILE]            name an object without storing it
gitobj cat    <objdir> <sha>           like `git cat-file -p`
gitobj raw    <objdir> <sha>           the payload bytes, no pretty-printing
gitobj type   <objdir> <sha>
gitobj size   <objdir> <sha>
gitobj hdr    <objdir> <sha> <key>     a commit/tag header's value(s)
gitobj msg    <objdir> <sha>           a commit/tag message, byte-exact
gitobj name   <objdir> <sha>           the full name, like `git rev-parse`
gitobj ls     <objdir>                 every object: sha, type, size
gitobj verify <objdir>                 hash every object against its own name
gitobj write  <objdir> <type> [FILE]   store a loose object, print its name
gitobj mktree <objdir>                 git-mktree format on stdin, store a tree
gitobj idx    <pack.idx>               `git show-index` layout: offset, name, crc
gitobj idxcrc <pack.idx>               every CRC against the pack beside it
gitobj packls <pack.idx>               `git verify-pack -v` layout
gitobj packverify <pack.idx>           hash every packed object against its name
gitobj unpack <pack.idx> <objdir>      every object of a pack, written loose
gitobj pack   <objdir> <out> <window>  names on stdin, write out.pack+out.idx
```

Every `<sha>` above is a full name, 40 hex characters under SHA-1 and 64
under SHA-256, or four or more hex characters of one, which is resolved
against the store and refused if it matches two objects.

`--object-format` comes before the subcommand and defaults to sha1. git takes
it from `extensions.objectFormat` in a repository's config; gitobj is handed
an object directory, which need not be inside a repository, so it is told.
A loose store whose names are the other format's length is refused, naming
the flag it wanted, rather than reported as empty.

`packls` is not `idx` under another name. Its columns are the pack entry's
type, its inflated size and its size in the pack, and the first two come out
of the pack rather than the index. It reads the delta chains too, so over a
pack git chose the layout for it prints every object; that sentence used to
say it stopped at the first delta, which it did until the delta reader
landed. Nothing else is planned and absent from
this list, which it has been wrong about before: `write`, `mktree` and the
three pack commands were all listed here as though they existed before any
of them did.

In scope:

* both object formats. They differ in the hash and in nothing else, so the
  loose header, the tree entry, the pack entry header, the index layout and
  every checksum are one set of readers parameterised on a length. SHA-256
  itself is the SHA-256 half of `../sha2`, vendored the way `../inflate`'s
  DEFLATE is, without that file's SHA-224/384/512, HMAC, PBKDF2 or HKDF.
* loose objects: zlib-wrapped `<type> <len>\0<payload>`, read and write,
  with both DEFLATE halves vendored from `../inflate`. Written through a
  temporary name and renamed into place, and left alone if the name is
  already there.
* the whole object store behind one path: loose files, every pack beside
  them, and whatever `objects/info/alternates` points at, nested to the
  depth git allows. An object in two of those is listed once, and the loose
  copy is the one read, which is the order git looks in.
* abbreviated names, of four or more hex characters, resolved over the whole
  store and refused when two objects match.
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

* a commit or tag builder. A tree is the only object `gitobj` constructs
  out of anything but bytes handed to it. This bullet said "no packfile
  writing, no `unpack-objects`" until both landed, and said `gitobj` was
  read-only until `write` landed.

Exit status: 0 success, 1 refused or not found, 2 the command line was wrong.

## Hard invariant

Every object read hashes back to its own name. A git object's name is the
SHA-1 of `<type> <len>\0<payload>`, so the name is a checksum over the entire
decode path: the zlib stream, the loose header, the pack type/size varint, the
OFS_DELTA offset varint, every copy and insert instruction, and every link of
the delta chain beneath it. If a single byte of any of that is wrong the hash
does not match. It is the one assertion that cannot be satisfied by being
self-consistently wrong.

**It covers every object in every corpus:** 383 loose, and 3438 read out of
fifteen packs, 2019 of those through a delta chain and 2815 of them in eight
sibling histories, plus 126 under SHA-256, 59 of those through a delta chain. It said "loose and packed" for a good while before any
pack code existed, which was the strongest claim in the file and the one
that was not true; it covered 490 of 3184 five commits ago. The one thing
still out of reach is a pack over two gigabytes, which this suite cannot
build.

The index has its own invariants, and they are cross-checks rather than
hashes: the fanout must agree with the name list it indexes, the CRC must
agree with the pack bytes between one offset and the next, and the declared
object count must agree with the file's own size. The first and the third
are what a reader can check with no other file open.

The other half of the invariant is that git accepts what we write, and it
runs four ways now. `gitobj write` re-serialises a loose object, `gitobj
mktree` builds a tree out of entry lines, `gitobj unpack` reads a whole pack
out into loose objects, and `gitobj pack` writes a packfile and its index;
`git fsck --strict` and `git cat-file -p` read all four back, for the third
against `git unpack-objects`' own store over the same pack, and for the
fourth out of a repository holding nothing but the pack we wrote.

Pack writing has an invariant of its own that is not a hash: `git index-pack
-o` builds an index from our pack and it must be byte-identical to the index
we wrote beside it. git re-indexing one of its own packs reproduces that
pack's `.idx` exactly, so the comparison is about our index rather than
about how reproducible git's indexer is.

## Oracle

Ranked, strongest first, by how little of it we control.

1. The object name itself. Not an oracle we wrote: git chose the filename
   and the index entry, we recompute the hash. Applies to every object in
   every corpus, with no fixtures to maintain.
2. `git cat-file -p` / `-t` / `-s`, object by object, over every object of
   the small corpus, loose and packed: 1498 objects, 1129 of them out of a
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
   pack in reach: 3438 objects, 2019 of them deltas. The type and the size
   come out of the entry header, the size in the pack out of the index's
   sorted offsets, and the chain length and base name out of the walk down
   the chain. The suite also builds a `--window=0` pack and has git assert
   that it holds no delta, which is the only way the whole-entry path is
   distinguished from the delta path in the comparison.
7. `git rev-parse --verify` over an abbreviated name, which is the same
   lookup on the other side and nothing else: 1498 prefixes of 7
   characters, plus 4-character ones over a store built so that two of them
   are ambiguous.
8. `git unpack-objects` over the same pack `gitobj unpack` was given, so
   two loose stores can be compared whole, with `git fsck --strict` over
   ours re-hashing every object we wrote.
9. `git index-pack -o` over a pack `gitobj pack` wrote, which is the
   sharpest of the write oracles: git builds an index from our pack with no
   sight of ours, and the two files must be the same bytes, so the fanout,
   the name order, every CRC, every offset and both checksums are git's
   answer rather than a comparison we are on both sides of. With `git
   verify-pack` over the pair, `git fsck --strict` over a repository holding
   nothing but that pack, and `cat-file -p` per object against the store the
   objects came out of.
10. ASan + UBSan over the whole suite (`make test-asan`), with both the index
   and the pack trimmed to exactly the bytes read, since `readall()` doubles
   and a buffer bigger than its data turns the sanitizer off. The hostile
   input it most wants is in section 10: eleven hand-built packs that lie
   about a length, and 300 fuzzed ones.

11. The same oracles again over a corpus built with
   `--object-format=sha256`, which is a separate entry because they are
   reached differently: `git hash-object`, `index-pack`, `verify-pack` and
   `fsck` have no `--object-format` flag and take the format from the
   repository they run in, so each needs `--git-dir` pointed at a SHA-256
   one. `show-index` is the exception and takes the flag, having no
   repository to ask. 64 names, 126 objects swept loose and packed, both
   delta encodings, 16 blobs written, a tree against `git mktree`, and a
   pack of ours whose index `git index-pack -o` reproduces byte for byte.

Item 3 was one of four oracles struck off this list for not existing, and
items 5 and 6 are a second one arriving in pieces. What is missing from item
6 is a pack over two gigabytes, which the suite cannot build. Repacking for
an encoding the corpus lacks was one of the other two struck-off oracles and
now exists, as the `--no-delta-base-offset` and `--window=0` fixtures. The
last one still missing is a mutation sweep driven from the suite rather than
by hand.

## Non-goals

* Thin packs, `--stdout`, and packing a repository larger than memory.
  `gitobj pack` writes a pack and its index, with a delta search of its own,
  and holds every object it is given inflated at once while it does it.
  Writing REF_DELTA is a non-goal as well: it is read, and there is no
  reason to emit it when OFS_DELTA is shorter and git's own `gc` writes
  that.
* Reading `extensions.objectFormat` out of a repository config. SHA-256
  repositories are read and written; which format a store is in has to be
  given on the command line, because what gitobj is handed is an object
  directory and not a repository. This bullet used to say SHA-256 was a
  non-goal and that `extensions.objectFormat = sha256` was refused, which
  was two claims and the second was never true: nothing read any config, so
  a SHA-256 store was not refused, it was read as SHA-1 and reported as
  holding no objects.
* Reachability. No ref parsing, none of `rev-parse`'s revision syntax, no
  `--batch` protocol, no index/worktree. An object is addressed by its name
  or by four or more hex characters of it, which is the one part of
  `rev-parse` that is here: abbreviated names WERE on this list.
* The pack `.rev`, `.mtimes`, bitmap and multi-pack index files, cruft
  packs and promisor/partial clones. Alternates WERE on this list and are
  read now, nested and relative ones included; a C-quoted path in the file
  is not, and is taken literally.
* Writing a DEFLATE encoder. There is one, and it was not written here:
  `../inflate`'s travels, which is the same arrangement as its decoder. This
  non-goal used to say loose objects were stored blocks and that Milestone 1
  was where it changed, which is what happened.
* Being fast. Every object is inflated from scratch, and a delta is
  re-applied for every object on its chain whose base has dropped out of the
  64-entry base cache: 4260 inflations over the whole suite where no cache
  needs 8791 and git needs one per object. A command that wants one object
  opens every pack in the store to find it. This used to say there was no
  pack reader and then describe one in the present tense.

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
- [x] README and PLAN
      why: a README that lists only successes is not finished.
      files: README.md and PLAN.md, and nothing else.
      proves: nothing, which is the point of doing it last. What it does is
      make both documents agree with a run of the suite. Every figure in
      the README was re-derived from one: the test counts both ways, the
      3061 CRCs, the 1498 objects of the per-object sweep, the fifteen
      packs, the six self-built corpora, and the 43 seconds `make test`
      now takes.
      found: five figures had drifted as the suite grew, every one of them
      in a direction that made the project look like it covered less than
      it did, which is the harmless direction and still wrong. The
      per-object sweep was quoted at 1375 objects when it covered 1498, the
      CRC count at 2938 when it was 3061, the corpus count at five when it
      was six, and two figures in the delta sections were a commit behind.
      found: the house rule about a README listing only successes is the
      easy half. The hard half is a README whose failures are stale. Five
      surviving mutants are recorded there with the reason each one is
      unobservable (the buffer trim, the pack trailer bound, both halves of
      the base cache's byte budget, and the alternates walk's early return
      on a directory it has already searched) and three more that were
      written as defects and are not (the zlib window field, searching the
      whole name list rather than one fanout bucket, and filing an unpacked
      object under the name the index gave). Two stopped being survivors
      during this stretch of work and had to be moved rather than left
      reading as current.
      Three sections of the README now describe things that work and did
      not when this item was written: the base cache, alternates and
      abbreviated names. Each of them says what it still cannot do.

### Milestone 1: the gaps that bite real users

- [x] a real `zinflate` for writing, or vendor `../inflate`'s encoder
      why: stored blocks mean `gitobj write` produces a loose object ~1.0003x
      the payload size where git produces ~0.3x. git reads it, so nothing is
      broken, but no one would use this to write a real repository.
      files: gitobj.c (the encoder vendored from `../inflate`: the bit
      writer, the Huffman builder, the hash-chain matcher, the cost-chosen
      block boundaries, and zdeflate() in place of deflate_gz(), plus bput,
      WIN and clextra which the decoder never needed; zdeflate_stored is
      gone), t/run.sh section 6, README.md
      proves: three payloads, one for each block type the cost model can
      choose, because a model that always picked one of them would pass
      every other assertion in the write section. 100000 zero bytes come to
      133, which only a coded block can do; 336000 of one repeated line
      come to 1059; and 100000 from /dev/urandom come to 100028, which is
      stored blocks and has to be, since five bytes of header per 65535 of
      payload plus six of framing is the only way that number is reachable.
      git inflates all three and `verify` reads them back through our own
      decoder.
      19535 assertions before, 19545 after; 5874 to 5884 cloned alone.
      found: git's default for a LOOSE object is compression level 1, not
      the level 6 it uses for packs. The same repeated line comes to 1059
      bytes here and 2041 from git, so this writer is smaller than git's
      default rather than the 3x larger it used to be. Reported and not
      asserted: it is not a comparison either side is trying to win.
      found: four planted defects, four red, every one of them caught both
      by git refusing to inflate what we wrote and by our own `verify`.
      Not reversing a Huffman code into the stream fails 822 assertions, a
      zlib header whose check bits do not divide by 31 fails 832, the
      Adler-32 written little-endian fails 558, and never setting BFINAL
      fails 548.
      found: in the harness. The first version of the compression check
      wrote a payload that was a copy of one already in the store, so the
      count of objects written disagreed with what git found there by one.
      That is the second time this exact mistake has been made in this
      section, and the comment warning about it was already there.
- [x] a delta base cache, so a chain of depth N costs N inflations once,
  not N inflations per object in it
      why: `packls` over a whole pack would be the slowest thing in the
      suite, and the fix is a four-entry LRU keyed on pack offset. (This
      said `packls` did not exist. It does now, which is what made the
      slowness measurable rather than predicted.)
      files: gitobj.c (DBASE_N, DBASE_MAX, Dbase, dbase_get, dbase_evict,
      dbase_put, and pack_at split into a census wrapper around
      pack_resolve), t/run.sh sections 9 and 10, README.md
      proves: three things per pack read, every one of them a number rather
      than a claim. That every entry reached was either inflated or found in
      the cache, which is arithmetic over the census. That the inflations
      never fall BELOW the object count, since a cache answering for the
      object asked for would let a walk over a pack answer out of itself and
      `packverify` would be hashing the cache. And that the inflations come
      to fewer than git's own sum of chain lengths plus the object count,
      which is what the walk costs with no cache, so the saving is measured
      against git. Over the whole suite: 4260 inflations and 1615 hits where
      no cache needs 8791.
      17099 assertions before, 17153 after; 4486 to 4516 cloned alone.
      found: four entries does almost nothing. 1771 inflations against 1856
      without any cache, over cc. The why: this item's reasoning was about
      the pack LAYOUT, where git keeps a base near its deltas, and the cost
      is in the chain DEPTH, which reaches 29 there, so every object
      resolved flushes a four-entry cache on the way down. 16 entries gives
      1033, 64 gives 729, 256 gives 719. It is 64 with a 16MB budget, and a
      whole-pack walk over cc goes from 0.41s to 0.26s.
      found: a cached base has no entry header left to read, so caching the
      bytes alone left every cached base with type 0 and every chain length
      at 1. 85 of cc's 538 objects hashed to nothing and the depth column
      disagreed with git on every delta. The cache stores the entry facts
      beside the bytes.
      found: no pack-order walk can see the rule that the cache holds bases
      only, because an OFS_DELTA base is always earlier in the pack and so
      is never the object asked for next. Only a REF_DELTA can name a base
      that comes AFTER it, and nothing git packs here does, so there is a
      hand-built pack of two entries for it: a REF_DELTA followed by its own
      base, which git accepts. One assertion in the suite notices that
      mutation and it is that fixture's census.
      found: four planted defects, two red. A cache keyed on nothing, so
      any entry matches, fails 118 assertions beginning with `gitobj
      verify` over the siblings; removing the cache fails 12, all of them
      the saving-against-git check.
      survivor: both halves of the byte budget, never evicting and refusing
      to cache an object bigger than the whole budget. No corpus here has
      16MB of live bases, so neither is observable. They bound memory
      against sizes chosen by whoever wrote the pack, which is a reason to
      have them rather than a reason a test can see them.
- [x] an index git itself wrote with a 64-bit offset in it
      why: the escape is exercised now, by an index the suite rewrites so
      that git resolves a real pack through the table and by offsets written
      in by hand, both with git as the oracle. What no fixture can be is a
      pack over two gigabytes, so the one thing still untested is an index
      git PRODUCED with a large offset: `git index-pack` choosing the escape
      itself. That needs 2GB of pack and a suite willing to spend it.
      files: t/bigpack.sh, a `bigpack` target in the Makefile, an entry in
      .gitignore for its scratch directory, README.md
      proves: eleven blobs of 230MB of urandom, each under OBJ_MAX so it is
      an object gitobj would read, packed with `--window=0`. Run on 5
      November 2026: a pack of 2653704008 bytes in which git wrote 2
      offsets at or above 2^31, with `gitobj idx` agreeing with `git
      show-index` line for line and the census confirming 2 of the 11
      objects came through the table. 18 assertions, all passing.
      found: with a delta window those eleven 230MB blobs are compared in
      memory and the machine kills pack-objects. The first run reported an
      empty pack name and seven confusing failures, because the status of a
      command substitution was never looked at: it is checked now, and the
      pack is built with no delta window, which those blobs would not use
      anyway.
      not in `make test`: it writes about 5GB and takes minutes, which
      makes it a target nobody runs. The README says what it produced and
      when, and says to re-run it rather than quote that.
      not attempted: reading the OBJECTS of a 2.5GB pack. `readall()` loads
      a whole file, so `idxcrc` and `packls` over it would want 2.5GB of
      address space and a copy on top. The index is what the target is for.
- [x] `gitobj write` for packed input, i.e. unpack-objects
      why: the natural completion of having both halves, and it makes the
      three-hop `pack -> loose -> git fsck` round trip possible.
      files: gitobj.c (the `unpack` command), t/run.sh section 13 plus a
      `wrongname` fixture in the pack generator, README.md
      proves: four packs read out into fresh bare repositories, compared
      against `git unpack-objects`' own store line by line and then object
      by object with `cat-file -p`, with `git fsck --strict` clean over
      ours. fsck is the half that matters: it inflates every loose object
      we wrote, re-hashes it against the name we filed it under, and parses
      the trees and commits, so the three hops are pack to loose to git.
      Both targets are created empty and checked for it, since a write test
      can pass by finding its object already present.
      proves, for a pack that is wrong: one whose base blob has a byte
      changed after its names were computed, so nothing in it hashes to
      what the index says. Nothing is written, the object is named, and git
      refuses that pack as well.
      18762 assertions before, 19535 after; 5101 to 5874 cloned alone.
      found: three planted defects, two red. Writing every object as a blob
      fails 249 assertions beginning with fsck; writing an object whose
      name does not check out fails 1, which is the assertion that exists
      for it.
      survivor: filing the object under the name the INDEX gave rather than
      the one we computed. Written as a defect and is not one: the two are
      equal wherever anything is written, because the mismatch branch
      writes nothing.
- [x] abbreviated object names, by binary search over the index fanout
      why: every human-facing git command takes a 7-character prefix, and
      the fanout is read now, so this is a ten-line function over `idx_open`
      plus the ambiguity check. It also needs the loose objects, where the
      fan-out directory does the same job.
      files: gitobj.c (odb_resolve, name_check, name_resolve, obj_full and
      the `name` command), t/run.sh section 12 and one assertion in section
      2 that had the old behaviour, README.md
      proves: `gitobj name` against `git rev-parse --verify`, the same
      lookup on the other side, over 1498 objects of the small corpus by
      their first 7 characters. Compared against whatever git says rather
      than against success, since a prefix that short can collide and then
      both of us have to refuse. 32 four-character prefixes resolved and 4
      refused as ambiguous, with which ones are which read out of git's
      listing rather than ours, and a prefix one character longer than an
      ambiguous one has to resolve.
      17195 assertions before, 18762 after; 4558 to 5101 cloned alone.
      found: a clone with no siblings had no ambiguous prefix anywhere. 123
      objects per repository over 65536 buckets collide about never, where
      3061 collide readily, so the ambiguity path went untested standalone
      and the floor on it is what said so. A store of its own for it now:
      600 blobs of fixed content, colliding at bc98 and bfae, the same two
      on every run because the content decides the names.
      found: the four-character minimum was in two places, so a mutation of
      one of them failed a single assertion while the other command went on
      enforcing it. One `name_check` now, called by both.
      found: three planted defects, three red. Returning the first match
      instead of refusing fails 4 assertions, all of them the ambiguous
      prefixes; dropping the minimum fails 3, one of which uses a
      3-character prefix matching exactly ONE object so that the length is
      the only possible reason to refuse it; comparing the prefix over 40
      characters rather than its own length fails 1537.
      shortcut: the lookup is a linear scan over every name in the store
      rather than the binary search this item asked for. The names are
      already collected for `ls`, and a command that wants one object
      already opens every index and every pack in the store, so the search
      is not where the time goes.
- [x] `objects/info/alternates`, so a repository whose objects live in a
      borrowed object store can be read at all
      why: every `git clone -s` and most CI caches look like this, and we
      currently report "object not found" with no hint why.
      files: gitobj.c (ALT_MAX, Dirs, dirs_add, alt_scan, Odb, odb_open,
      odb_close, odb_names, and obj_get over a list of directories rather
      than one), t/run.sh section 11 plus a ref in the corpus builder so
      `git clone -s` has something to clone, README.md
      proves: `git clone -s --bare` of a self corpus repository, twice,
      once where the source is loose and once where it is packed. The
      borrowing clone is checked for having no object and no pack of its
      own, since otherwise the comparison could pass on a copy. Then `git
      cat-file --batch-all-objects --batch-check` against `gitobj ls` line
      for line, `gitobj verify` over all 123, and one object read through
      the alternate byte for byte. Five hand-written shapes as well, since
      git only ever writes the first: a relative path, a chain of three, a
      cycle, the same cycle spelled relatively, and a file holding a
      comment, a blank line and a directory that is not there.
      17153 assertions before, 17195 after; 4516 to 4558 cloned alone.
      found: a de-duplicated LIST is not a terminating WALK. The first
      version skipped a duplicate directory when adding it and then read
      that directory's alternates file anyway, so a two-repository cycle
      recursed until the stack ran out: a segfault, reached by `gitobj ls`
      on a store git reads fine. The early return is in the walk now.
      found: the two cycle guards catch different things. Skipping a
      directory already in the list ends a cycle spelled the same way round
      both times; the depth limit of five, which is git's own, is what ends
      one spelled two ways, and relative paths make that easy because each
      hop appends to the path and no two strings are ever equal. There is a
      fixture for each.
      found: five planted defects, four red. Ignoring the file fails 15
      assertions, resolving a relative path against the current directory
      fails 4, reading only the first line fails 4, and dropping the depth
      limit fails 3.
      survivor: the early return on a duplicate directory, now that the
      depth limit covers the same-spelling cycle as well. It bounds the
      work rather than the result.
      found: git complains about an alternate it cannot use and carries on,
      which is an assertion here rather than a line of noise in the output.
- [x] write packfiles: delta search, `.idx` generation, `verify-pack` on our
      own output
      why: the one direction of the format that is entirely unimplemented,
      and the only way to close the loop on the delta encoders.
      files: gitobj.c (pwr_hdr, pwr_ofs, pwr_dsize, pwr_ins, pwr_copy,
      delta_make, Pent, pentcmp, pidcmp, filewrite, pack_write, and the
      `pack` command), t/run.sh section 14, README.md
      proves: `git index-pack -o` builds an index from our pack and it is
      byte-identical to the one we wrote beside it, which is the fanout, the
      name order, every CRC, every offset, the copy of the pack checksum and
      the index's own, all of them git's answer with no sight of ours. git
      re-indexing one of its OWN packs reproduces that pack's `.idx` exactly,
      which is what makes the comparison a test of our index rather than a
      statement about git's indexer. Then `git verify-pack` over the pair,
      the reader's whole `verify-pack -v` comparison turned on our own
      output, `git fsck --strict` over a bare repository holding nothing but
      our pack, and `cat-file -p` per object against the store the objects
      came out of. Four packs: the delta corpus at window 0 and at window
      10, the self corpus, and one holding a single tag.
      19545 assertions before, 20443 after; 5884 to 6737 cloned alone.
      found: the delta search had to be made deterministic before anything
      could be asserted about it, which is the same reason every fixture
      here passes `--threads=1` to `pack-objects`. Objects are ordered by
      type, then size descending, then name; each is compared against up to
      `window` already-placed entries of the same type and the smallest
      delta kept. Two runs give the same pack bytes, and so does the same
      list of names reversed, which is a separate assertion: a writer that
      echoed its input order would pass the first and fail the second.
      found: our pack of the delta corpus is 56049 bytes against git's
      59854 and 201746 stored whole, and on `../cc`'s 538 objects 2857651
      against git's 3298397. That is not the delta search being better. It
      is the DEFLATE encoder vendored from `../inflate` doing the work
      `gzip -6` does where git packs at zlib level 6, the same difference
      that makes a loose object 1059 bytes here and 2041 from git.
      found: the writer census is the vacuity guard and the first version of
      it was decoration. It counted a copy instruction of length 0x10000
      rather than one emitted with its length left IMPLICIT, so the mutant
      that writes the three length bytes out in full survived a whole sweep
      with the census still reporting 33 of them. Counted off the
      instruction byte now, and that mutant dies.
      found: ten planted defects, nine red. The fanout counting names
      strictly below its bucket fails 412, the OFS_DELTA varint without its
      minus one fails 129 (git cannot even index the file), a delta entry
      header carrying the target size rather than the delta size fails 129,
      the index written in pack order fails 337, the pack trailer taken over
      all but the last byte fails 33, the CRC over the compressed bytes
      alone fails 12, no depth limit fails 1 on a chain of 39, the implicit
      copy length written out in full fails 1, and packing in the order the
      names arrived fails 1.
      found: that last one only after the assertion was tightened. "The
      delta pack is smaller than the whole pack" is satisfied by packing in
      name order, which still finds 79 deltas and still comes to 97k against
      202k stored whole. Under a THIRD is what the ordering has to earn, and
      52k against 202k clears it with room.
      survivor: extending a match backwards into the literal run not yet
      emitted. It is worth 175 bytes of 51734 on the suite's corpus, which
      no bound that is not a golden number can see, and 5.2 per cent on
      `../cc`'s 538 objects, which a standalone clone does not have. The
      fixture is the thing that cannot see it rather than the suite.
      found: no 64-bit offset is reachable. The escape at 2^31 is written
      and the census reports 0 of N through it every run, because a pack
      that needs one is over two gigabytes and this writer holds every
      object inflated at once. `make bigpack` builds such a pack with git
      and reads its index; it cannot be rebuilt with `gitobj pack`.
- [x] SHA-256 repositories
      why: the format is otherwise identical and the work is mostly
      mechanical, but it needs a corpus built with
      `--object-format=sha256` to be worth anything, and it needs SHA-256
      itself, which was not here.
      This said 20 was hard-coded in nine places, then 29, and told the
      reader to re-grep rather than quote it. Re-grepped at the commit
      before this one: the narrow forms (`[20]`, `20 *`, `* 20`) are on 33
      lines, `40` on 19 and `41` on 30, union 81, of which two are not name
      lengths (a SHA-1 round boundary and a shift in the delta search's
      hash). 79, against a figure of nine.
      files: gitobj.c (Sha256, k256, sha256_block/init/update/final, the
      Hash wrapper over both, hsz/hexsz, HASH_MAX/HEX_MAX, Names with a
      runtime stride, the --object-format flag, the other-format guard in
      loose_names), t/run.sh section 15 plus the exit-status fix in section
      2, README.md
      route: the SHA-256 compression function, round constants and initial
      hash value came from `../sha2`, which implements them against the NIST
      CAVP vectors; its SHA-224/384/512, HMAC, PBKDF2 and HKDF did not,
      since an object name uses none of them. Not linked against: one C11
      file and no dependency beyond zlib is the house rule, and a clone with
      no siblings has to build. Not rewritten: sha2 owns the vectors. What
      did not travel is sha2's derivation of its constants from their
      definitions, which it diffs on every run; here they are typed in and
      git is what catches a wrong digit.
      proves: three more bare repositories built with
      `--object-format=sha256`, the same 63 objects loose, packed, and
      packed again as REF_DELTA. 64 names against `hash-object` in a
      SHA-256 repository, 126 objects swept against `cat-file -t`/`-s`/raw
      bytes/`-p`, `ls` against `cat-file --batch-all-objects
      --batch-check`, `verify` over both halves, abbreviated names against
      `rev-parse --verify`, the index against `show-index
      --object-format=sha256`, `packls` against `verify-pack -v` for both
      encodings with 59 objects through a delta chain, 16 blobs written and
      read back with `fsck --strict` clean, a five-entry tree against `git
      mktree`, the pack unpacked loose and fsck'd, and a pack of ours whose
      index `git index-pack -o` rebuilds byte-identically: 63 objects, 58
      OFS_DELTA entries, chain ten deep. 20489 assertions before, 21139
      after; 6738 to 7388 cloned alone.
      found: fifteen planted defects, fifteen red, no survivors. The flag
      made a no-op fails 638, one wrong digit in `k256[0]` 366, one wrong
      word of the IV 366, padding to 55 bytes 370, a left rotate 366,
      `w[i-6]` for `w[i-7]` 366, the name list stride fixed at 41 525,
      `hexify` stopping at 20 bytes 120, the index name stride back to 20
      276, `IDX_ENT` back to 28 276, the pack trailer back to 20 3, the
      REF_DELTA base name back to 20 4, the tree entry stride back to 20 3,
      mktree writing 20 bytes 2, the other-format guard removed 2.
      found: in the harness, twice, from the one mutant that survived. The
      tree entry stride was unobservable because the SHA-256 corpus had a
      tree of ONE entry, where a wrong stride prints that entry correctly
      and then dies on the end of the object. And the per-object sweep
      compared stdout alone, with `2>/dev/null` and no look at the exit
      status, so dying after correct output scored as agreement. Both are
      fixed, in section 15 and in section 2's 1498-object sweep, which has
      been that way since it was written.
      found: a SHA-256 store read as SHA-1 reported `0 objects` and exited
      0, because a 62-character filename is not 38 characters and was
      skipped as a stray file. It refuses now and names the flag. The index
      needed no such guard: its own checksum and the size arithmetic above
      it refuse the wrong format either way round.
- [ ] a 64-bit offset in an index we wrote
      why: the only part of `gitobj pack` nothing exercises. The escape is
      written, and the writer's census says 0 of N through the table on
      every run, which is the shape of a branch that is never taken. The
      pack that would take it is over two gigabytes and `gitobj pack` holds
      every object inflated at once, so this needs the writer to stream
      before it needs a fixture. The reader's side of the same gap is
      covered by indexes the suite rewrites and by `make bigpack`, and
      neither of those helps here.
