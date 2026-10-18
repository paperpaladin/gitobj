# gitobj

Reads git's object database, writes loose objects into it, and builds trees:
one C11 file, no libgit2, no shelling out to git. The DEFLATE decoder is vendored from the
sibling `../inflate` rather than rewritten; the writer emits zlib stored
blocks, which git reads and which compress nothing.

```
$ gitobj verify ../cc/.git/objects
36 objects, 0 mismatched

$ make test
sibling corpus (small): 3 of 3 present
sibling corpus (big): 5 of 5 present
verified 539 loose objects across self_a self_b self_c cc tarx inflate psh unrepro cmark httpd wasmi
2303 passed, 0 failed
```

## Two numbers, and which one to quote

Cloned on its own this suite reports **1862 passed**, against three bare
repositories it builds itself: 120 blobs each through one
`hash-object --stdin-paths`, plus a tree, a commit and an annotated tag from
plumbing, at fixed dates so the object names do not move between runs.

Inside the collection it reports more: 2303 above, because the sibling
repositories are an additional corpus, and more of them is strictly better
evidence. But that number moves every time anything is committed anywhere in
the tree, since a commit creates loose objects. It is a real count of real
comparisons and a useless figure to quote, so the collection's table quotes
1862: the one a reader gets by cloning this repository and running `make
test`.

## The oracle is the object's own name

A git object's name is the SHA-1 of `<type> <len>\0<payload>`, so the name
is a checksum over the entire decode path: the zlib stream, the loose
header, the payload. Git chose the filename; we recompute the hash. If a
single byte of the decode is wrong, the hash does not match.

That is an oracle with no fixtures to maintain and nothing we control, and
it cannot be satisfied by being self-consistently wrong. It is the reason
this repo has no expected-output files.

Everything else is `git cat-file -p` / `-t` / `-s` and `git log --format=`,
object by object, over the loose objects of three sibling repositories,
cc, tarx and inflate, the `CORPUS_SMALL` set. The other six get `gitobj
verify` over their whole object store, plus a whole-repository `gitobj ls`
comparison for the two with no packfile. This said "nine", the size
of the corpus, not the reach of the per-object sweep.

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

## What does not work

There is no pack reader. This is the big one. All eight sibling
repositories in the corpus have a packfile, and **539 of the 1902 objects
in the corpus are loose: 28%**. The other 72% are never read. Those counts
move whenever a sibling repository is committed to or repacked; they were
497 of 1860 one commit ago and 656 of 2534 when this paragraph was
written. The three repositories the suite builds for itself are wholly
loose and are the only reason the share is not far smaller.

`PLAN.md` claimed otherwise until an audit went looking. Its hard invariant
said the suite hashes "every object in every corpus repository, loose and
packed", its in-scope list described the v2 index, both delta encodings and
delta chains of any depth, and its oracle list included `git verify-pack -v`
diffed against a `gitobj packls`. None of that exists. The only trace of
pack support in `gitobj.c` is `T_OFS_DELTA = 6, T_REF_DELTA = 7` in an enum,
and neither constant is ever read. Its commit sequence had the pack work
correctly unchecked the whole time. Prose above it did not.

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

No `.rev`, `.mtimes`, bitmap or multi-pack index files, no cruft packs,
no promisor or partial clones, no alternates.

Not fast. Every object is inflated from scratch.

## Why this file exists

The house convention here is that every repo has a `README.md` stating what
does *not* work, and this repo did not have one. `gitobj.c`'s header comment
pointed at it (`See README.md`), and so did a comment in `t/run.sh` pointing
at a "section 9" that does not exist either: the file stopped at section 5,
and stops at 7 now that there is a writer and a tree builder to test.
Those two pointers and the `PLAN.md` prose were the only places the pack gap
was acknowledged, and all three described it as finished.

## License

GPL-3.0-or-later.
