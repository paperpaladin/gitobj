# gitobj

## Contract

`gitobj` is a reader and writer for git's object database: one C11 file, no
libraries, no shelling out to git.

```
gitobj hash   <type> [FILE]            name an object without storing it
gitobj write  <objdir> <type> [FILE]   store a loose object, print its name
gitobj mktree <objdir>                 git-mktree format on stdin
gitobj cat    <objdir> <sha>           like `git cat-file -p`
gitobj raw    <objdir> <sha>           the payload bytes, no pretty-printing
gitobj type   <objdir> <sha>
gitobj size   <objdir> <sha>
gitobj hdr    <objdir> <sha> <key>     a commit/tag header's value(s)
gitobj msg    <objdir> <sha>           a commit/tag message, byte-exact
gitobj ls     <objdir>                 every object: sha, type, size
gitobj verify <objdir>                 hash every object against its own name
gitobj packls <idx>                    `git verify-pack -v` layout
```

In scope:

* **loose objects**: zlib-wrapped `<type> <len>\0<payload>`, read and write.
* **the four object types**: blob, tree, commit, tag. Trees are parsed and
  pretty-printed the way `git cat-file -p` does; commits and tags are parsed
  into headers (including multi-line folded ones, such as `gpgsig`) plus a
  byte-exact message.
* **tree construction**, with git's sort order: entries compare as if a
  directory name carried a trailing slash, so `a.c` sorts *after* `a/`.
* **tree entry modes**: `100644`, `100755`, `120000`, `40000` (stored without
  the leading zero) and `160000` gitlinks.
* **packfiles**: the v2 index with its fanout table and 64-bit offset
  escape, the pack header and per-object type/size varint, and both delta
  encodings -- `OFS_DELTA` with its own distinct negative-offset varint, and
  `REF_DELTA` with a 20-byte base name.
* **delta application**: base/result size varints and the copy/insert
  instruction stream, including the copy instruction's optional-byte bitmap
  where an absent byte means 0 for the offset and 0x10000 for the size.
* **delta chains of any depth**, where a base is itself a delta.

Exit status: 0 success, 1 refused or not found, 2 the command line was wrong.

## Hard invariant

**Every object read hashes back to its own name.** A git object's name is the
SHA-1 of `<type> <len>\0<payload>`, so the name is a checksum over the entire
decode path: the zlib stream, the loose header, the pack type/size varint, the
OFS_DELTA offset varint, every copy and insert instruction, and every link of
the delta chain beneath it. If a single byte of any of that is wrong the hash
does not match. The suite asserts this for every object in every corpus
repository, loose and packed, and it is the one assertion that cannot be
satisfied by being self-consistently wrong.

**And git accepts what we write.** Objects written by `gitobj write` and
`gitobj mktree` are read back by `git cat-file -p` and vetted by `git fsck`
in a repository git itself created.

## Oracle

Ranked, strongest first -- by how little of it we control.

1. **The object name itself.** Not an oracle we wrote: git chose the filename
   and the index entry, we recompute the hash. Applies to every object in
   every corpus, with no fixtures to maintain.
2. **`git verify-pack -v`, object by object.** It prints name, type,
   uncompressed size, size-in-packfile, offset, delta depth and base name for
   every object in a pack. `gitobj packls` prints the same seven fields and
   the two outputs are diffed whole. Depth and base are the columns that
   catch an OFS_DELTA offset decoded one byte off.
3. **`git cat-file -p` / `-t` / `-s`, object by object.** Over every object in
   every corpus repository. The tree pretty-printer, the mode formatting and
   the raw commit/tag bytes are all pinned here.
4. **git reads what we write.** `gitobj write` into a repository git created,
   then `git cat-file -p`, then `git fsck`. `gitobj mktree` against `git
   mktree` on the same unsorted input, which is what settles the
   trailing-slash sort rule without us asserting our own reading of it.
5. **`git log --format=`** for the parsed commit fields (`%T`, `%P`, `%an`,
   `%ae`, `%ad --date=raw`, `%e`), and `git cat-file -p` for the message
   bytes, so CRLF and trailing whitespace are checked as bytes rather than as
   a description.
6. **Packs repacked by git on demand**, so the suite covers encodings the
   corpus does not happen to contain: `-c pack.useDeltaBaseOffset=false` for
   REF_DELTA, and `--depth=50 --window=250` for chains deeper than history
   produced naturally.
7. **ASan + UBSan over the whole suite** (`make test-asan`), plus randomly
   mutated packs, indexes and loose objects asserting that nothing ever dies
   on a signal and that a delta claiming a 4GB result is refused rather than
   allocated.

## Non-goals

* **Writing packfiles.** No delta compression, no `.idx` generation, no
  `pack-objects`. Reading them is the interesting half.
* **SHA-256 repositories.** `extensions.objectFormat = sha256` is refused.
  Everything here assumes 20-byte names.
* **Reachability.** No ref parsing, no `rev-parse`, no abbreviated names, no
  `--batch` protocol, no index/worktree. Objects are addressed by full
  40-character name only.
* **The pack `.rev`, `.mtimes`, bitmap and multi-pack index files**, cruft
  packs, promisor/partial clones, and alternates (`objects/info/alternates`).
* **Writing with any real compression.** Loose objects are emitted as zlib
  stored blocks, which git reads perfectly and which grow the file by ~0.03%.
* **Being fast.** Every object is inflated from scratch with no delta base
  cache, so walking a pack is O(objects * chain depth) inflations.

## Commit sequence

- [x] SHA-1, the loose-object header, `gitobj hash`
      why: the object *name* is the project's hard invariant, so the thing
      that computes it comes first and is checked against `git hash-object`
      before anything else exists to be wrong.
- [ ] vendor the DEFLATE decoder from `../inflate`, add RFC 1950 framing,
      read a loose object: `cat`/`raw`/`type`/`size` for blobs
      why: every object in the database is behind a zlib stream, so nothing
      can be read until this works. The decoder travels rather than being
      rewritten because `../inflate` already owns its oracle.
- [ ] `gitobj verify`: hash every loose object against its filename
      why: this is the hard invariant, and it is cheaper to wire up now than
      to retrofit once the pack reader is also producing objects.
- [ ] the tree parser and `git cat-file -p` pretty-printing
      why: the only object type whose `-p` output is not its raw bytes, and
      the first place the mode encoding can be wrong.
- [ ] the commit/tag header parser: `hdr`, `msg`
      why: multi-line folded headers (`gpgsig`) and a byte-exact message are
      where "parses my own commits" and "parses git's" diverge.
- [ ] loose object write: zlib stored blocks, `gitobj write`
      why: the second half of the oracle. Until git can read what we write,
      only one direction is tested.
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
      readers get wrong -- `(ofs + 1) << 7` rather than a plain shift.
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
      result must be refused rather than allocated.
- [ ] the three sabotages, recorded in the README
      why: a suite whose failure has never been observed is not evidence.
      The delta copy instruction, the tree sort and the object header each
      get broken on purpose and the damage written down.
- [ ] README and PLAN
      why: a README that lists only successes is not finished.

### Milestone 1 -- the gaps that bite real users

- [ ] a real `zinflate` for writing, or vendor `../inflate`'s encoder
      why: stored blocks mean `gitobj write` produces a loose object ~1.0003x
      the payload size where git produces ~0.3x. git reads it, so nothing is
      broken, but no one would use this to write a real repository.
- [ ] a delta base cache, so a chain of depth N costs N inflations once
      rather than N inflations per object in it
      why: `packls` on a 1163-object pack is the slowest thing in the suite,
      and the fix is a four-entry LRU keyed on pack offset.
- [ ] 64-bit pack offsets exercised for real
      why: the offset64 escape in the v2 index is implemented and *cannot
      be tested*, because it needs a pack above 4GiB. Currently dead code
      with a hand-built index as its only coverage.
- [ ] `gitobj write` for packed input, i.e. unpack-objects
      why: the natural completion of having both halves, and it makes the
      three-hop `pack -> loose -> git fsck` round trip possible.
- [ ] abbreviated object names, by binary search over the index fanout
      why: every human-facing git command takes a 7-character prefix, and
      the fanout table already makes it a ten-line function.
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
