# 01 — Skeleton & data types

## Goal

Create `cli/diff.odin`. Define the data types that model a parsed diff, plus a stub `parse_diff`
procedure that compiles but does nothing yet. By the end, `odin check .` passes.

## Why it matters

Before you parse anything, you decide *what shape the answer has*. Good types make the parser almost
write itself; vague types make it a mess. Our shape mirrors the format from increment 00 exactly: a
`Diff` holds `File_Diff`s, each holding `Hunk`s. And — the big idea — every text field is a `string`
that will be a **view** into the original buffer, not a copy.

## New Odin concepts

You're new to Odin, so here's everything you'll use in this file, each with a tiny example.

**Package declaration.** Every `.odin` file in a directory shares one package. The existing CLI files
all start with `package main`, so yours must too — that's how `diff.odin` becomes part of the same
program as `git.odin`.

```odin
package main
```

**Enums** — a type with a fixed set of named values:

```odin
Color :: enum { Red, Green, Blue }
c := Color.Red          // or, when the type is known from context, just `.Red`
```

**Structs** — a record of named fields:

```odin
Point :: struct {
    x: int,
    y: int,
}
p := Point{x = 1, y = 2}
```

Fields of the same type can share one declaration — handy for our four hunk line-numbers:

```odin
Span :: struct {
    start, end: int,   // both are int
}
```

**Slices** — `[]T` is a *view* of `len` consecutive `T`s living somewhere else. It does not own that
memory; it's a `{pointer, length}` pair. A `string` in Odin is essentially `[]u8` with this same
borrowed-view nature. `[]Hunk` is "a view of some Hunks". This borrowed-ness is exactly what we want.

```odin
xs: []int = ...   // a view of ints
n := len(xs)
```

**Multiple return values**, and the `(value, ok)` idiom Odin uses everywhere for "this might fail":

```odin
lookup :: proc(key: string) -> (value: int, ok: bool) {
    return 0, false
}
v, ok := lookup("x")
if !ok { /* handle failure */ }
```

**The zero value `{}`.** Every type has a zero value; `{}` is a literal for it. Returning `{}, false`
from a `(T, bool)` procedure means "no meaningful value, and it failed".

## The git-diff bits you'll touch

None yet — this increment is pure modelling. But map the format (from 00) onto the types as you write
them: `Diff` = the whole buffer, `File_Diff` = one `diff --git` section, `Hunk` = one `@@` region.

## Your task

Create `cli/diff.odin` containing:

1. An enum `Hunk_Kind` with values: `Modify`, `Add_File`, `Delete_File`, `Rename`, `Binary`,
   `Mode_Change`. (These are the file kinds from 00 §5; `Modify` is the ordinary case.)

2. A struct `Hunk` with:
   - four `int` fields: `old_start`, `old_count`, `new_start`, `new_count`
   - `header: string` — the `@@ ... @@` line (a view)
   - `body: string` — the lines after the header (a view)
   - `raw: string` — header + body together, byte-exact (a view)

3. A struct `File_Diff` with:
   - `kind: Hunk_Kind`
   - `old_path, new_path: string`
   - `header: string` — the `diff --git` line through the last header line, before the first hunk
   - `hunks: []Hunk`
   - `raw: string` — the whole file section, byte-exact

4. A struct `Diff` with:
   - `files: []File_Diff`
   - `src: string` — the original buffer everything else points into

5. A stub procedure:
   ```odin
   parse_diff :: proc(src: string) -> (Diff, bool) {
       return {}, false
   }
   ```

**Hints**

1. Match the existing house style: `Type_Name :: struct { ... }`, tabs for indentation, a trailing
   comma after each field.
2. Put a short `//` comment on each `string` field noting it's a *view into src* — you'll thank
   yourself in increment 02 when you have to keep that promise.
3. You don't need any `import`s yet. (Odin errors on unused imports, so don't add one until a later
   increment actually needs it.)

**Edge cases:** none yet.

## Verify

```sh
cd cli
odin check .
```

It should pass with no errors. (Unused package-level types and procedures are fine in Odin — no
warnings for those.) If you see "unused import", you added an import you don't need yet; remove it.

---

<details>
<summary>Reference solution</summary>

```odin
package main

// diff.odin — a unified-diff parser.
//
// Every text field below is a *view* (a slice) into the original buffer passed
// to parse_diff, not a copy. That makes byte-exact reconstruction free and
// means a Diff is only valid while its `src` stays alive.

Hunk_Kind :: enum {
	Modify, // ordinary changes to an existing file
	Add_File, // new file (`new file mode ...`)
	Delete_File, // removed file (`deleted file mode ...`)
	Rename, // `rename from` / `rename to`
	Binary, // `Binary files ... differ` — cannot be split below file level
	Mode_Change, // permission/mode change only
}

Hunk :: struct {
	// Parsed from the `@@ -old_start,old_count +new_start,new_count @@` line.
	old_start, old_count, new_start, new_count: int,
	header:                                     string, // the "@@ ... @@" line (view)
	body:                                       string, // the +/-/space/'\' lines (view)
	raw:                                        string, // header + body, byte-exact (view)
}

File_Diff :: struct {
	kind:               Hunk_Kind,
	old_path, new_path: string, // views into src
	header:             string, // "diff --git" line through "+++ ..." (view)
	hunks:              []Hunk,
	raw:                string, // the whole file section, byte-exact (view)
}

Diff :: struct {
	files: []File_Diff,
	src:   string, // the original buffer every view above points into
}

// parse_diff turns raw `git diff` output into a structured Diff.
// (stub: filled in over the next increments)
parse_diff :: proc(src: string) -> (Diff, bool) {
	return {}, false
}
```

Notice the aligned fields — Odin's formatter (`odinfmt`, if you run it) aligns the comments; you don't
have to do that by hand. The alignment in `old_start, old_count, ...` pushing `header` far right is
cosmetic.

</details>

Next: [`02-line-splitter.md`](02-line-splitter.md) — your first real logic.
