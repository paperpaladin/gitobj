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

Planned and NOT PRESENT. These were listed above as though they existed, and
`write`, `mktree` and the two index commands were four of them until they
were written:

gitobj packls <idx>                    `git verify-pack -v` layout
```

`packls` is not `idx` under another name. Its columns are the pack entry's
type, its inflated size and its size in the pack, none of which can be
computed without walking the pack.

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
* the pack v2 index: the 256-entry cumulative fanout checked against the
  sorted name list it indexes, the CRC of every object's packed bytes checked
  against the pack, and both offset encodings, including the escape into the
  64-bit table for an offset at or above 2^31. A v1 index is refused by name.
  The pack header is read only to cross-check its object count and its
  trailing checksum against the index; nothing else in the pack is parsed.

In scope and NOT YET WRITTEN. Listed here without that qualification until
an audit pointed out there was no pack code in `gitobj.c` at all. The index
is the first part of it to exist; `T_OFS_DELTA = 6, T_REF_DELTA = 7` are
still in an enum and neither constant is ever read:

* the pack header and per-object type/size varint, and both delta
  encodings: `OFS_DELTA` with its own distinct negative-offset varint, and
  `REF_DELTA` with a 20-byte base name.
* delta application: base/result size varints and the copy/insert
  instruction stream, including the copy instruction's optional-byte bitmap
  where an absent byte means 0 for the offset and 0x10000 for the size.
* delta chains of any depth, where a base is itself a delta.
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

**It currently covers the LOOSE objects only, which is 699 of the 2062 in
the corpus: 34%.** The eight sibling repositories have a packfile whose
contents are still never read: the index names all 1363 packed objects and
gives an offset and a CRC for each, and there is nothing in an index to
hash. This section said "loose and packed" and that was the strongest claim
in the file and the one that was not true. The counts move with every commit
or repack in a sibling; they were 539 of 1902 at the last commit.

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
2. `git cat-file -p` / `-t` / `-s`, object by object. Over every loose
   object in every corpus repository. The tree pretty-printer, the mode
   formatting and the raw commit/tag bytes are all pinned here.
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
6. ASan + UBSan over the whole suite (`make test-asan`), with both the index
   and the pack trimmed to exactly the bytes read, since `readall()` doubles
   and a buffer bigger than its data turns the sanitizer off.

Item 3 was one of four oracles struck off this list for not existing, and
item 5 is most of a second. What is still missing from item 5 is the
`verify-pack -v` COLUMNS: type, size and size-in-pack, which need the pack
walk. The other two struck-off oracles also still do not exist: repacking
for encodings the corpus lacks, and a mutation sweep driven from the suite
rather than by hand.

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
- [ ] the pack walk: type/size varint, non-delta objects, `ls`
      why: gets `verify-pack`'s first five columns under oracle before the
      delta machinery, so a later failure is unambiguously a delta bug.
- [ ] OFS_DELTA: the negative-offset varint
      why: a *different* varint from the size encoding, and the one most
      readers get wrong: `(ofs + 1) << 7`, not a plain shift.
- [ ] delta application: the copy/insert instruction stream
      why: the optional-byte bitmap with its 0 and 0x10000 defaults is the
      other classic bug, and refusing an oversized result size belongs in
      the same commit as the allocation it guards.
- [ ] REF_DELTA, and chains whose base is itself a delta
      why: the corpus has no REF_DELTA in it, so the suite has to make git
      produce one; depth is only meaningfully tested past 2.
- [ ] the full `verify-pack -v` diff, and `verify` over packed objects
      why: the strongest oracle in the project, and it cannot be written
      until every column it prints can be computed.
- [ ] refusals: OBJ_MAX, truncation, bad varints, mutation fuzz, `test-asan`
      why: every length in a pack is attacker-chosen, and a 4GB delta
      result must be refused, not allocated.
- [ ] the three sabotages, recorded in the README
      why: a suite whose failure has never been observed is not evidence.
      The delta copy instruction, the tree sort and the object header each
      get broken on purpose and the damage written down.
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
