# 05 — Serializer & tests

## Goal

Write `serialize` (turn a `Diff` back into text), build a corpus of real diff fixtures under
`cli/testdata/`, and write `cli/diff_test.odin` proving the headline property:

```
serialize(parse(src)) == src      // byte for byte, for every fixture
```

Then add a `make test` target. When this is green, M1 is done.

## Why it matters

Everything in this track was aimed at one guarantee: that you can take a diff apart and put it back
together without changing a single byte. That's not a nice-to-have — when the later milestone feeds a
reconstructed sub-diff to `git apply`, one stray byte means a corrupted patch. The round-trip test is
how you *know* the foundation is solid before building on it.

And because every field is a view that tiles the buffer, `serialize` is almost insultingly simple —
which is the whole reward for the zero-copy discipline.

## New Odin concepts

**`strings.Builder`** — accumulate text efficiently, then get the result:

```odin
sb := strings.builder_make(context.temp_allocator)
strings.write_string(&sb, "hello ")
strings.write_string(&sb, "world")
result := strings.to_string(sb)   // "hello world"
```

(You've seen this already in `get_staged_diff_tier_2` in `git.odin`.)

**The testing package.** A test is a procedure marked `@(test)` taking `t: ^testing.T`:

```odin
import "core:testing"

@(test)
my_test :: proc(t: ^testing.T) {
	testing.expect(t, 1 + 1 == 2, "math is broken")
	testing.expectf(t, len("ab") == 2, "got %d", len("ab"))   // formatted message
}
```

`odin test .` builds and runs every `@(test)` in the package. `expect` takes a bool; `expectf` adds
`printf`-style formatting for the failure message.

**Reading a file** — `os.read_entire_file_from_path(name, allocator) -> ([]byte, os.Error)`. The
error compares to `nil`; convert bytes to a string with `string(bytes)`:

```odin
data, err := os.read_entire_file_from_path("testdata/simple.diff", context.allocator)
src := string(data)
```

> Heads-up on the API name: older Odin had `os.read_entire_file`; on current Odin (2026-05) it's
> `os.read_entire_file_from_path`. If you see an "ambiguous call" error, that's why.

## Step 1 — `serialize`

```odin
serialize :: proc(d: Diff, allocator := context.allocator) -> string
```

Build a string by writing each `File_Diff.raw` in order. Because the file sections tile `src` exactly,
the concatenation *is* `src`. Hint: `strings.builder_make(allocator)`, loop `for f in d.files`,
`strings.write_string(&sb, f.raw)`, return `strings.to_string(sb)`.

That's it. You never touch `header`, `hunks`, or the parsed integers to reconstruct — `raw` already
holds the exact bytes. (The parsed fields exist for the *next* milestone, which will rebuild patches
from selected hunks rather than from `raw`.)

## Step 2 — build the test corpus

You need fixtures that exercise every branch. Generate them from **real git** so they're byte-exact
(hand-typing diffs is a recipe for subtle format bugs). Run this from anywhere; it writes into
`cli/testdata/`. Adjust `SAFT` to your repo path.

```sh
SAFT=/path/to/odin/saft
mkdir -p "$SAFT/cli/testdata"

# A throwaway repo for the straightforward cases
REPO=$(mktemp -d); cd "$REPO"
git init -q; git config user.email t@t.t; git config user.name t; git config core.autocrlf false

printf 'line1\nline2\nline3\n' > a.txt
git add a.txt; git commit -qm init
printf 'line1\nline2 changed\nline3\n' > a.txt
git diff a.txt > "$SAFT/cli/testdata/simple.diff"          # modify, 1 hunk

printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n' > b.txt
git add b.txt; git commit -qm b
printf 'l1 X\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10 Y\n' > b.txt
git diff b.txt > "$SAFT/cli/testdata/multihunk.diff"        # 1 file, 2 hunks
git checkout -q -- b.txt

printf 'c1\nc2\n' > c.txt; printf 'd1\nd2\n' > d.txt
git add c.txt d.txt; git commit -qm cd
printf 'c1\nc2 z\n' > c.txt; printf 'd1 z\nd2\n' > d.txt
git diff c.txt d.txt > "$SAFT/cli/testdata/multifile.diff"  # 2 files
git checkout -q -- c.txt d.txt

printf 'brand\nnew\n' > newf.txt; git add newf.txt
git diff --cached newf.txt > "$SAFT/cli/testdata/newfile.diff"   # new file
git reset -q

chmod +x c.txt
git diff c.txt > "$SAFT/cli/testdata/mode.diff"             # mode change only
git checkout -q -- c.txt 2>/dev/null || chmod -x c.txt

printf '\x00\x01\x02\x03bin' > bin.dat; git add bin.dat; git commit -qm bin
printf '\x00\x09\x02\x03\x04binchanged' > bin.dat
git diff bin.dat > "$SAFT/cli/testdata/binary.diff"         # binary

printf 'x1\nx2\nx3' > nonl.txt; git add nonl.txt; git commit -qm nonl   # no trailing \n
printf 'x1\nx2 changed\nx3' > nonl.txt
git diff nonl.txt > "$SAFT/cli/testdata/nonewline.diff"     # \ No newline sentinel

# Deleted file — fresh repo so the tree is clean
R1=$(mktemp -d); cd "$R1"
git init -q; git config user.email t@t.t; git config user.name t; git config core.autocrlf false
printf 'line1\nline2\nline3\n' > a.txt; git add a.txt; git commit -qm init
git rm -q a.txt
git diff --cached -- a.txt > "$SAFT/cli/testdata/delete.diff"

# Pure rename — fresh repo, -M enables rename detection
R2=$(mktemp -d); cd "$R2"
git init -q; git config user.email t@t.t; git config user.name t; git config core.autocrlf false
printf 'k1\nk2\nk3\nk4\nk5\n' > orig.txt; git add orig.txt; git commit -qm init
git mv orig.txt renamed.txt
git diff --cached -M > "$SAFT/cli/testdata/rename.diff"
```

Sanity-check that none came out empty: `wc -c "$SAFT"/cli/testdata/*.diff` — every file should be > 0
bytes. (New/deleted/rename need staging via `git add` / `--cached`, which is why they're handled
specially.)

## Step 3 — `cli/diff_test.odin`

Write tests that:
1. **Round-trip** every fixture: read it, `parse_diff`, `serialize`, assert equal to the original.
2. **Field-check** a couple: `simple.diff` → 1 file, `kind == .Modify`, paths `a.txt`, 1 hunk with
   ranges `(1,3)`/`(1,3)`. `multifile.diff` → 2 files. `multihunk.diff` → 1 file, 2 hunks.
3. **Kind-check** the awkward ones: newfile→`.Add_File`, delete→`.Delete_File`, rename→`.Rename`,
   mode→`.Mode_Change`, binary→`.Binary`.

**Hints**

1. `odin test .` runs with the working directory set to where you invoke it. If you `cd cli` first,
   the relative path `"testdata/simple.diff"` resolves correctly.
2. To pair a fixture with its expected kind cleanly, declare a tiny struct and a `[]` of them — Odin
   disables `map` literals by default, so a struct slice is the path of least resistance.
3. `expectf(t, cond, "msg %v", value)` gives you readable failures.

## Step 4 — `make test`

In the `Makefile`, add `test` to `.PHONY` and a target:

```make
test:
	cd cli && odin test .
```

## Verify

```sh
cd cli && odin test .
# or, from the repo root:
make test
```

You want: **`All tests were successful.`**

> **About the "leak" lines.** `odin test` runs under a tracking allocator that prints every heap
> allocation you didn't free — your `[dynamic]` arrays and the builder. They're reported as `+++ leak`
> but they do **not** fail the run (the program is exiting anyway). For M1 that's fine. If you want a
> clean report later, you'd free the `Diff` or parse into an arena and free it in one shot — a good
> M2 concern, not a today concern. This is exactly the "who owns this memory, and how long does it
> live?" question the whole track has been training you to ask.

Also confirm you didn't break the real build:

```sh
cd cli && odin build . -out:saft   # the existing CLI still compiles with diff.odin alongside it
```

---

<details>
<summary>Reference solution</summary>

`serialize`, appended to `cli/diff.odin`:

```odin
// serialize re-emits the parsed diff. Because each File_Diff.raw is a view that
// tiles src exactly, the result equals the original buffer.
serialize :: proc(d: Diff, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	for f in d.files {
		strings.write_string(&sb, f.raw)
	}
	return strings.to_string(sb)
}
```

`cli/diff_test.odin`:

```odin
package main

import "core:os"
import "core:testing"

FIXTURES :: []string {
	"testdata/simple.diff",
	"testdata/multihunk.diff",
	"testdata/multifile.diff",
	"testdata/newfile.diff",
	"testdata/delete.diff",
	"testdata/rename.diff",
	"testdata/mode.diff",
	"testdata/binary.diff",
	"testdata/nonewline.diff",
}

@(test)
test_roundtrip :: proc(t: ^testing.T) {
	for path in FIXTURES {
		data, derr := os.read_entire_file_from_path(path, context.allocator)
		testing.expectf(t, derr == nil, "could not read %s", path)
		src := string(data)
		d, pok := parse_diff(src)
		testing.expectf(t, pok, "parse failed for %s", path)
		out := serialize(d)
		testing.expectf(t, out == src, "round-trip mismatch for %s", path)
	}
}

@(test)
test_simple_fields :: proc(t: ^testing.T) {
	data, _ := os.read_entire_file_from_path("testdata/simple.diff", context.allocator)
	d, ok := parse_diff(string(data))
	testing.expect(t, ok)
	testing.expect(t, len(d.files) == 1)
	f := d.files[0]
	testing.expect(t, f.kind == .Modify)
	testing.expect(t, f.old_path == "a.txt")
	testing.expect(t, f.new_path == "a.txt")
	testing.expect(t, len(f.hunks) == 1)
	h := f.hunks[0]
	testing.expectf(t, h.old_start == 1 && h.old_count == 3, "old range %d,%d", h.old_start, h.old_count)
	testing.expectf(t, h.new_start == 1 && h.new_count == 3, "new range %d,%d", h.new_start, h.new_count)
}

Kind_Case :: struct {
	path: string,
	want: Hunk_Kind,
}

@(test)
test_kinds :: proc(t: ^testing.T) {
	cases := []Kind_Case {
		{"testdata/newfile.diff", .Add_File},
		{"testdata/delete.diff", .Delete_File},
		{"testdata/rename.diff", .Rename},
		{"testdata/mode.diff", .Mode_Change},
		{"testdata/binary.diff", .Binary},
	}
	for c in cases {
		data, _ := os.read_entire_file_from_path(c.path, context.allocator)
		d, ok := parse_diff(string(data))
		testing.expectf(t, ok, "parse failed for %s", c.path)
		testing.expectf(t, d.files[0].kind == c.want, "wrong kind for %s: got %v", c.path, d.files[0].kind)
	}
}

@(test)
test_multifile_and_multihunk :: proc(t: ^testing.T) {
	mf, _ := os.read_entire_file_from_path("testdata/multifile.diff", context.allocator)
	d, ok := parse_diff(string(mf))
	testing.expect(t, ok)
	testing.expectf(t, len(d.files) == 2, "expected 2 files, got %d", len(d.files))

	mh, _ := os.read_entire_file_from_path("testdata/multihunk.diff", context.allocator)
	d2, ok2 := parse_diff(string(mh))
	testing.expect(t, ok2)
	testing.expectf(t, len(d2.files) == 1, "expected 1 file, got %d", len(d2.files))
	testing.expectf(t, len(d2.files[0].hunks) == 2, "expected 2 hunks, got %d", len(d2.files[0].hunks))
}
```

`Makefile` additions:

```make
.PHONY: build install uninstall clean test

test:
	cd cli && odin test .
```

</details>

## You're done with M1 🎉

You built a real unified-diff parser in Odin: a two-level state machine over byte-views, with a
round-trip guarantee proven against nine real-world diff shapes. More importantly you practised the
core systems-programming reflex — *views vs copies, and tracking who owns memory and for how long*.

**What's next (M2):** group a parsed `Diff`'s files/hunks into separate commits and stage each with
`git apply --cached`, verifying that the union of the commits equals the original diff. That milestone
leans entirely on the byte-exactness you just built. See the brainstorm in
`~/.claude/plans/humming-baking-creek.md` for the full roadmap.
