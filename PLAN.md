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

Planned and NOT PRESENT. These were listed above as though they existed, and
`write` was one of them until it was written:

gitobj mktree <objdir>                 git-mktree format on stdin
gitobj packls <idx>                    `git verify-pack -v` layout
```

In scope:

* loose objects: zlib-wrapped `<type> <len>\0<payload>`, read and write.
  Written as stored blocks, renamed into place, and left alone if the name
  is already there.
* the four object types: blob, tree, commit, tag. Trees are parsed and
  pretty-printed the way `git cat-file -p` does. Commits and tags are parsed
  into headers (including multi-line folded ones, such as `gpgsig`) plus a
  byte-exact message.
* tree construction, with git's sort order: entries compare as if a
  directory name carried a trailing slash, so `a.c` sorts *after* `a/`.
* tree entry modes: `100644`, `100755`, `120000`, `40000` (stored without
  the leading zero) and `160000` gitlinks.
In scope and NOT YET WRITTEN. Listed here without that qualification until
an audit pointed out there is no pack code in `gitobj.c` at all. The only
trace is `T_OFS_DELTA = 6, T_REF_DELTA = 7` in an enum, and neither constant
is ever read:

* packfiles: the v2 index with its fanout table and 64-bit offset
  escape, the pack header and per-object type/size varint, and both delta
  encodings: `OFS_DELTA` with its own distinct negative-offset varint, and
  `REF_DELTA` with a 20-byte base name.
* delta application: base/result size varints and the copy/insert
  instruction stream, including the copy instruction's optional-byte bitmap
  where an absent byte means 0 for the offset and 0x10000 for the size.
* delta chains of any depth, where a base is itself a delta.
* writing anything but a loose object: no `mktree`, no packfile writing, no
  `unpack-objects`. This said `gitobj` was read-only, which it was until
  `write` landed.

Exit status: 0 success, 1 refused or not found, 2 the command line was wrong.

## Hard invariant

Every object read hashes back to its own name. A git object's name is the
SHA-1 of `<type> <len>\0<payload>`, so the name is a checksum over the entire
decode path: the zlib stream, the loose header, the pack type/size varint, the
OFS_DELTA offset varint, every copy and insert instruction, and every link of
the delta chain beneath it. If a single byte of any of that is wrong the hash
does not match. It is the one assertion that cannot be satisfied by being
self-consistently wrong.

**It currently covers the LOOSE objects only, which is 497 of the 1860 in
the corpus: 27%.** Seven of the nine corpus repositories have a packfile
whose contents are never read, because there is no pack reader. This
section said "loose and packed" and that was the strongest claim in the
file and the one that was not true. The counts move with every commit or
repack in a sibling; they were 585 of 2468 a few days ago.

The other half of the invariant is that git accepts what we write, and that
half now runs for loose objects: `gitobj write` re-serialises an object and
`git fsck --strict` and `git cat-file -p` read it back. It does not run for
anything else, because `mktree` and pack writing are still absent.

## Oracle

Ranked, strongest first, by how little of it we control.

1. The object name itself. Not an oracle we wrote: git chose the filename
   and the index entry, we recompute the hash. Applies to every object in
   every corpus, with no fixtures to maintain.
2. `git cat-file -p` / `-t` / `-s`, object by object. Over every loose
   object in every corpus repository. The tree pretty-printer, the mode
   formatting and the raw commit/tag bytes are all pinned here.
3. `git fsck --strict` and `git cat-file -p` over a bare repository whose
   every object `gitobj write` put there. git inflates our zlib stream,
   re-hashes it and parses the trees and commits, so this is the read
   oracles run backwards, with git on the far side of the serialiser.
4. `git log --format=` for the parsed commit fields (`%T`, `%P`, `%an`,
   `%ae`, `%ad --date=raw`, `%e`), and `git cat-file -p` for the message
   bytes, so CRLF and trailing whitespace are checked as bytes, not as
   a description.
5. ASan + UBSan over the whole suite (`make test-asan`).

Item 3 was one of four oracles struck off this list for not existing, and is
the first of them to come back. The other three still do not exist:
`git verify-pack -v` against a `packls` that is not written, repacking for
encodings the corpus lacks, and a mutation sweep over packs and indexes. They are oracles for work in the commit sequence
below, and listing them here made the suite sound four oracles stronger
than it is. `grep -n 'mutat\|verify-pack\|mktree\|packls' t/run.sh` returns nothing.

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
- [ ] tree sorting and `gitobj mktree`
      why: the trailing-slash rule is the single most commonly wrong thing in
      a git reimplementation, and `git mktree` sorts its own input, so the
      two can be fed the same unsorted lines and compared.
- [ ] the pack v2 index: fanout, names, CRCs, 32- and 64-bit offsets
      why: the pack is unreadable without it, and the fanout table is a
      self-checking structure (it must end at the object count).
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
      why: `packls` on a 1163-object pack would be the slowest thing in the
      suite, and the fix is a four-entry LRU keyed on pack offset. (`packls`
      does not exist; see the note at the head of this file.)
- [ ] 64-bit pack offsets exercised for real
      why: the offset64 escape in the v2 index *cannot* be tested without a
      pack above 4GiB, so it will need a hand-built index as its only
      coverage. There is no v2 index code at all today, this said it was
      implemented and dead, which would at least have been something.
- [ ] `gitobj write` for packed input, i.e. unpack-objects
      why: the natural completion of having both halves, and it makes the
      three-hop `pack -> loose -> git fsck` round trip possible.
- [ ] abbreviated object names, by binary search over the index fanout
      why: every human-facing git command takes a 7-character prefix, and
      once there is a fanout table this becomes a ten-line function. There is
      no fanout table yet.
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
