# M1 — Build a unified-diff parser in Odin

A guided, build-it-yourself track. By the end you'll have written `cli/diff.odin`: a parser that
turns the raw text of `git diff` into structured data, plus a test suite that proves it's correct.

This is the first real piece of **saft's** "split a big agent diff into clean commits" feature. Every
later milestone (grouping hunks, staging them, committing) consumes the data structure you build here.
But M1 is also completely self-contained: it parses bytes and mutates *nothing* — no git, no commits,
no risk. That makes it the perfect place to learn Odin.

> These files are git-ignored. They're your scaffolding, not part of the shipped project. The code
> *you* write by following them (`cli/diff.odin`, `cli/diff_test.odin`, `cli/testdata/`) **is** real
> project code and gets committed normally.

## The one big idea: views, not copies

A diff is just text. The naive parser copies pieces of that text into new strings — one allocation
per path, per line, per hunk. We do the opposite: **every field in our data structures is a *view*
(a slice) that points back into the original buffer.** Nothing is copied.

Why this matters, and why it's the whole point of the exercise:

- **Reconstruction becomes free and obviously-correct.** If every piece is a window onto the
  original bytes, then gluing the pieces back together reproduces the original *exactly*. Our headline
  test is `serialize(parse(src)) == src` — byte for byte. When you split a real patch later and feed
  it to `git apply`, that byte-exactness is what stops you from corrupting someone's code.
- **It teaches the systems-programming core of Odin:** a slice is just a `{pointer, length}` pair, a
  borrowed view into memory someone else owns. That forces you to think about *lifetimes*: our whole
  `Diff` is only valid for as long as the original buffer it points into stays alive. No garbage
  collector hides this from you. Getting comfortable with "who owns this memory, and how long does it
  live?" is the skill systems programming is really about.

You'll feel this idea in every increment.

## The five increments

Work them in order. Each one compiles and is testable before you move on.

| #  | File | You build | New Odin you'll meet |
|----|------|-----------|----------------------|
| 00 | [`00-anatomy-of-a-git-diff.md`](00-anatomy-of-a-git-diff.md) | *(reference — keep it open)* | — |
| 01 | [`01-skeleton-and-types.md`](01-skeleton-and-types.md) | the data types + a stub | structs, enums, slices, multi-return, `{}` |
| 02 | [`02-line-splitter.md`](02-line-splitter.md) | an offset-keeping line reader | slicing `s[a:b]`, pointers, `strings.index_byte` |
| 03 | [`03-file-sections.md`](03-file-sections.md) | split into per-file sections + classify | `strings.has_prefix`, `switch`, `[dynamic]T`, `append` |
| 04 | [`04-hunk-parsing.md`](04-hunk-parsing.md) | parse `@@` hunks | integer parsing, nested loops |
| 05 | [`05-serializer-and-tests.md`](05-serializer-and-tests.md) | `serialize` + the test suite | `core:testing`, `@(test)`, fixtures |

## How to use these tutorials

Each increment follows the same shape:

1. **Goal / Why it matters** — what you're building and where it fits.
2. **New Odin concepts** — the language features you'll need, with tiny standalone examples.
3. **The git-diff bits you'll touch** — which part of the format this step handles.
4. **Your task** — a procedure signature, numbered hints, and the edge cases to handle. *You write
   the body.*
5. **Verify** — the exact command to run.
6. **`<details>` Reference solution** — collapsed. **Try the task first.** Open it to compare after
   you have something working (or when you're genuinely stuck on syntax — but read it, then retype it
   in your own words rather than pasting).

## Running your code

From the `cli/` directory:

```sh
odin check .            # type-check everything without producing a binary (fast feedback)
odin build . -out:saft  # full build of the saft CLI (what `make build` runs)
odin test .             # build & run every @(test) procedure
```

`odin check .` is your friend in increments 01–04 — it catches mistakes in seconds. The real tests
arrive in increment 05.

## Scope

You're building the **parser only**: `git diff` text → structured `Diff` → identical text back out. No
hunk grouping, no LLM, no `git apply`, no commits, and no changes to saft's existing command. Those
are later milestones; this is the foundation they all stand on.

When you finish, `cli/diff.odin` will be an importable, fully-tested parsing library sitting alongside
the existing `git.odin` / `helper.odin`, ready for M2 to build the commit-splitter on top.
