# gitobj

Reads git's object database: one C11 file, no libgit2, no shelling out to
git. The DEFLATE decoder is vendored from the sibling `../inflate` rather
than rewritten.

```
$ gitobj verify ../cc/.git/objects
35 objects, 0 mismatched

$ make test
sibling corpus (small): 3 of 3 present
sibling corpus (big): 5 of 5 present
verified 599 loose objects across self_a self_b self_c cc tarx inflate psh unrepro cmark httpd wasmi
2223 passed, 0 failed
```

## Two numbers, and which one to quote

Cloned on its own this suite reports **1639 passed**, against three bare
repositories it builds itself: 120 blobs each through one
`hash-object --stdin-paths`, plus a tree, a commit and an annotated tag from
plumbing, at fixed dates so the object names do not move between runs.

Inside the collection it reports more: 2223 above, because the sibling
repositories are an additional corpus, and more of them is strictly better
evidence. But that number moves every time anything is committed anywhere in
the tree, since a commit creates loose objects. It is a real count of real
comparisons and a useless figure to quote, so the collection's table quotes
1639: the one a reader gets by cloning this repository and running `make
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
comparison for the two with no packfile. This said "nine", which is the size
of the corpus, not the reach of the per-object sweep.

## What does not work

There is no pack reader. This is the big one. Seven of the nine corpus
repositories have a packfile, and **656 of the 2534 objects in the corpus
are loose: 26%**. The other 74% are never read.

`PLAN.md` claimed otherwise until an audit went looking: its hard invariant
said the suite hashes "every object in every corpus repository, loose and
packed", its in-scope list described the v2 index, both delta encodings and
delta chains of any depth, and its oracle list included `git verify-pack -v`
diffed against a `gitobj packls`. None of that exists. The only trace of
pack support in `gitobj.c` is `T_OFS_DELTA = 6, T_REF_DELTA = 7` in an enum,
and neither constant is ever read. The commit sequence had the pack work
correctly unchecked the whole time. The prose above it did not.

It is read-only. No `gitobj write`, no `gitobj mktree`. So only one
direction of the oracle runs: we read what git wrote, and nothing reads what
we write, because we write nothing. `PLAN.md` listed both commands and an
oracle built on `git fsck` accepting our output.

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
at a "section 9" that does not exist either: the file stops at section 5.
Those two pointers and the `PLAN.md` prose were the only places the pack gap
was acknowledged, and all three described it as finished.

## License

GPL-3.0-or-later.
