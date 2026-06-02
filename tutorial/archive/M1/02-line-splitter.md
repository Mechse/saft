# 02 — A line reader that keeps its place

## Goal

Write one small procedure, `next_line`, that walks a buffer one line at a time. It returns each line
**including its trailing `\n`**, as a view into the original buffer, and advances a cursor so the next
call picks up where the last left off.

This is the engine the rest of the parser drives. Both of your splits — buffer → file sections, file
section → hunks — are just "call `next_line` in a loop and watch for marker lines".

## Why it matters

Odin's standard library has `strings.split_lines`, which would hand you a `[]string` of all the lines
in one call. Why not use it?

Two reasons, and they're the lesson:

1. **It copies / allocates.** It builds a new array. We want zero copies — views only.
2. **It throws away positions.** Once you have a bare `[]string`, you've lost *where each line was* in
   the original buffer. But our entire design depends on byte offsets: a `File_Diff.raw` is
   `src[section_start:section_end]`, and to compute those bounds you need to know the byte offset
   where each `diff --git` line begins. `split_lines` deletes exactly the information we need.

So we write our own iterator that yields a line **and** keeps a cursor (a byte offset). The cursor is
the whole point.

## New Odin concepts

**Strings are byte views.** An Odin `string` is a `{pointer, length}` view of UTF-8 bytes. Slicing
makes a *new view of the same bytes* — no copy:

```odin
s := "hello"
mid := s[1:4]   // "ell" — points INTO s, no allocation
```

`s[a:b]` is the half-open range `[a, b)`: index `a` up to but not including `b`. `s[a:]` runs to the
end; `s[:b]` from the start.

**`len`** gives a string's byte length: `len("hello") == 5`.

**Pointers**, so a procedure can advance the caller's cursor. `^int` is "pointer to int"; `&x` takes
a pointer; `p^` reads/writes through it:

```odin
bump :: proc(p: ^int) { p^ = p^ + 1 }
n := 0
bump(&n)        // n is now 1
```

**`strings.index_byte`** finds the first occurrence of a byte, or `-1`:

```odin
import "core:strings"
strings.index_byte("a\nb", '\n')   // → 1
strings.index_byte("abc", '\n')    // → -1
```

Note `'\n'` is a single byte (a *rune/byte* literal with single quotes), not the string `"\n"`.

This is the increment where you finally add `import "core:strings"` to `diff.odin`.

## The git-diff bits you'll touch

All of them, indirectly — `next_line` doesn't care about diff syntax at all. It just yields lines. The
*callers* (increments 03–04) will look at each line's prefix. Keeping `next_line` dumb is good design:
one job, done once.

## Your task

Add to `cli/diff.odin`:

```odin
next_line :: proc(s: string, pos: ^int) -> (line: string, ok: bool) {
    // ...
}
```

Behaviour:
- If `pos^` is at or past the end of `s`, return `"", false` (nothing left).
- Otherwise find the next `\n` starting at `pos^`. Return the slice from `pos^` **through and
  including** that `\n`, and set `pos^` to just past it.
- If there is no more `\n` (the final line has no trailing newline), return the rest of the buffer and
  set `pos^` to `len(s)`.

**Hints**

1. Save the start: `start := pos^`.
2. Search only the remainder: `strings.index_byte(s[start:], '\n')`. The result is an offset
   *relative to `start`*, so the absolute newline index is `start + nl`.
3. "Include the newline" means the slice ends at `start + nl + 1`.
4. Set `pos^` to that same end index so the next call continues after the newline.

**Edge cases to handle**

- Empty input, or cursor already at the end → `"", false`.
- Last line with **no** trailing `\n` → return it, set `pos^ = len(s)`.
- A buffer ending in `\n` must **not** then yield a spurious empty line. (Check: with the logic above,
  after the final `\n` the cursor equals `len(s)`, so the next call returns `false`. Good.)

**The invariant that makes this correct:** if you concatenate every `line` returned, you get `s` back
exactly. Lines tile the buffer with no gaps and no overlaps. Hold onto that — it's what makes
`serialize(parse(src)) == src` true later.

## Verify

```sh
cd cli
odin check .
```

It must still compile. There's no test runner until increment 05, so trace it by hand on paper for
`"a\nbb\nc"`:

- call 1 → `"a\n"`, cursor 0 → 2
- call 2 → `"bb\n"`, cursor 2 → 5
- call 3 → `"c"`, cursor 5 → 6
- call 4 → `"", false`

Concatenate the three lines: `"a\n" + "bb\n" + "c" == "a\nbb\nc"`. ✓

> Want live feedback now instead of waiting for 05? Drop a throwaway `scratch_test.odin` with an
> `@(test)` proc that asserts the trace above, run `odin test .`, then delete it. You'll learn the
> real test setup in increment 05 — this is just an optional sneak peek.

---

<details>
<summary>Reference solution</summary>

Add the import at the top (alongside `package main`):

```odin
import "core:strings"
```

Then the procedure:

```odin
// next_line returns the line starting at pos^, INCLUDING its trailing '\n'
// (if any), and advances pos^ past it. Returns ok=false at end of buffer.
// The returned string is a view into s — no allocation.
next_line :: proc(s: string, pos: ^int) -> (line: string, ok: bool) {
	if pos^ >= len(s) do return "", false
	start := pos^
	nl := strings.index_byte(s[start:], '\n')
	if nl < 0 {
		pos^ = len(s)
		return s[start:], true
	}
	end := start + nl + 1 // include the newline
	pos^ = end
	return s[start:end], true
}
```

`do` is Odin's one-line statement form: `if cond do stmt` with no braces. You'll see it throughout the
existing codebase (e.g. `truncate_per_file` in `helper.odin`).

</details>

Next: [`03-file-sections.md`](03-file-sections.md) — split the buffer into per-file sections and
classify each one.
