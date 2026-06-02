# 04 — Parsing hunks

## Goal

Parse the `@@` regions inside a file section into `Hunk` values, extracting the four line numbers from
each `@@ -a,b +c,d @@` header. Then wire this into `parse_file_section` so files finally carry their
hunks. After this increment the parser is *functionally complete* — increment 05 only adds
serialization and tests.

## Why it matters

This is the inner split, and it reuses the exact marker-loop pattern from `parse_diff` — only the
marker changes from `diff --git ` to `@@ `. Seeing the same shape solve both levels is the payoff of
having kept `next_line` dumb. You'll also do your first real *tokenizing*: pulling integers out of a
structured line.

## New Odin concepts

**Parsing integers** — `strconv.parse_int(s, base) -> (value: int, ok: bool)`:

```odin
import "core:strconv"
v, ok := strconv.parse_int("42", 10)   // → 42, true
```

Pass base `10` explicitly (the default base `0` would try to infer hex/binary from prefixes — not what
we want for plain decimals). This is the increment where you add `import "core:strconv"`.

**Indexing a string gives a byte** (`u8`), and byte literals use single quotes:

```odin
s := "-5"
s[0] == '-'    // true — compare a byte to a byte literal
```

**Returning `nil` for a slice.** A `[]T` can be `nil` (an empty view). On failure, `return nil, false`
is the slice equivalent of `{}, false`.

**`strings.index`** (whole-substring search, vs `index_byte` for a single byte):

```odin
strings.index("-1,3 +1,3 @@", " @@")   // → byte offset of " @@", or -1
```

## The git-diff bits you'll touch

From 00: the hunk header `@@ -old +new @@` (§3) — including the optional count and the trailing section
heading — and the fact that body lines (§4), the no-newline sentinel, and everything else just ride
along inside `body`/`raw` as untouched bytes.

## Your task

### a) `parse_pair` — one range like `1,3` or `5`

```odin
parse_pair :: proc(s: string) -> (start: int, count: int)
```

`s` is the part after the sign, e.g. `"1,3"` or `"5"`. If there's a comma, parse both numbers. If
there's **no** comma, the count is omitted and defaults to `1`. Hint: `strings.index_byte(s, ',')`;
if `-1`, return `parse_int(s, 10)` and `1`.

### b) `parse_hunk_ranges` — pull the 4 numbers out of the header line

```odin
parse_hunk_ranges :: proc(header_line: string, h: ^Hunk) -> bool
```

`header_line` looks like `@@ -1,3 +1,3 @@\n` (possibly with a trailing heading after the second `@@`).
Steps:
1. Require it starts with `"@@ "`; strip that → `s`.
2. Find `" @@"` in `s`; the text before it is the ranges, e.g. `"-1,3 +1,3"`. (Anything after the
   `" @@"`, like a section heading or the newline, is ignored — but stays in the view.)
3. `strings.split` the ranges on `" "` → two parts; bail if not exactly 2.
4. Part 0 must start with `'-'`, part 1 with `'+'`. Strip the sign byte (`part[1:]`) and feed each to
   `parse_pair`, writing into `h.old_start/old_count` and `h.new_start/new_count`.

Write through the pointer: `h.old_start, h.old_count = parse_pair(...)`.

### c) `parse_one_hunk` — split a hunk into header line + body

```odin
parse_one_hunk :: proc(hk: string) -> (Hunk, bool)
```

`hk` is one hunk's full text: the `@@` line plus its body lines. Set `h.raw = hk`. Split off the first
line: find the first `\n`; `h.header` is everything up to and including it, `h.body` is the rest. (If
there's no `\n` at all, the header is the whole thing and the body is empty.) Then call
`parse_hunk_ranges(h.header, &h)`; if it fails, `return {}, false`.

### d) `parse_hunks` — split a region into hunks

```odin
parse_hunks :: proc(hs: string) -> ([]Hunk, bool)
```

`hs` begins at the first `@@ `. This is the **same marker loop** as `parse_diff`, with marker `@@ `
and `parse_one_hunk` instead of `parse_file_section`. Collect into a `[dynamic]Hunk`, return `hunks[:]`.

### e) Wire it into `parse_file_section`

Add this just before `parse_file_section` returns:

```odin
if first_hunk_at >= 0 {
    hunks, hok := parse_hunks(fs[header_end:])
    if !hok do return {}, false
    fd.hunks = hunks
}
```

`fs[header_end:]` is exactly the slice that starts at the first `@@` — the hunks region.

**Hints**

1. `parse_hunks` and `parse_diff` are structurally identical. If you wrote one, copy its shape.
2. Because `hs` starts exactly at a `@@ `, the first hunk's start offset is `0`, so the hunks tile
   `hs` with no gaps — which is what keeps `header + Σ hunk.raw == fs`, and ultimately the whole
   round-trip, byte-exact.

**Edge cases**

- **Omitted count:** `@@ -5 +5,2 @@` → old = (5, 1). Handled by `parse_pair`.
- **Trailing heading:** `@@ -7,4 +7,4 @@ l6` → parse `-7,4 +7,4`, ignore ` l6`, but keep it in the
  `header` view.
- **Deleted file ranges:** `@@ -1,3 +0,0 @@` → new = (0, 0). Zero is a perfectly valid number; don't
  special-case it.
- **No-newline sentinel** (`\ No newline at end of file`): it's just another body line. You already
  keep the body as raw bytes, so nothing to do.

## Verify

```sh
cd cli
odin check .
```

Must compile. You're now one increment away from proving it actually works.

---

<details>
<summary>Reference solution</summary>

Add the import:

```odin
import "core:strconv"
```

```odin
// parse_pair reads "start" or "start,count" (count defaults to 1 when omitted).
parse_pair :: proc(s: string) -> (start: int, count: int) {
	comma := strings.index_byte(s, ',')
	if comma < 0 {
		start, _ = strconv.parse_int(s, 10)
		return start, 1
	}
	start, _ = strconv.parse_int(s[:comma], 10)
	count, _ = strconv.parse_int(s[comma + 1:], 10)
	return start, count
}

// parse_hunk_ranges parses "@@ -a,b +c,d @@ ..." into h's four ints.
parse_hunk_ranges :: proc(header_line: string, h: ^Hunk) -> bool {
	if !strings.has_prefix(header_line, "@@ ") do return false
	s := header_line[3:]
	end := strings.index(s, " @@")
	if end < 0 do return false
	parts := strings.split(s[:end], " ", context.temp_allocator)
	if len(parts) != 2 do return false
	if len(parts[0]) < 1 || parts[0][0] != '-' do return false
	if len(parts[1]) < 1 || parts[1][0] != '+' do return false
	h.old_start, h.old_count = parse_pair(parts[0][1:])
	h.new_start, h.new_count = parse_pair(parts[1][1:])
	return true
}

parse_one_hunk :: proc(hk: string) -> (Hunk, bool) {
	h: Hunk
	h.raw = hk
	nl := strings.index_byte(hk, '\n')
	if nl < 0 {
		h.header = hk
		h.body = ""
	} else {
		h.header = hk[:nl + 1]
		h.body = hk[nl + 1:]
	}
	if !parse_hunk_ranges(h.header, &h) do return {}, false
	return h, true
}

// parse_hunks splits a region that begins at "@@ " into one Hunk per "@@ " line.
parse_hunks :: proc(hs: string) -> ([]Hunk, bool) {
	hunks := make([dynamic]Hunk)
	hunk_start := -1
	pos := 0
	for {
		ls := pos
		line, ok := next_line(hs, &pos)
		if !ok do break
		if strings.has_prefix(line, "@@ ") {
			if hunk_start >= 0 {
				h, hok := parse_one_hunk(hs[hunk_start:ls])
				if !hok do return nil, false
				append(&hunks, h)
			}
			hunk_start = ls
		}
	}
	if hunk_start >= 0 {
		h, hok := parse_one_hunk(hs[hunk_start:])
		if !hok do return nil, false
		append(&hunks, h)
	}
	return hunks[:], true
}
```

And the wiring inside `parse_file_section` (immediately before `return fd, true`):

```odin
	if first_hunk_at >= 0 {
		hunks, hok := parse_hunks(fs[header_end:])
		if !hok do return {}, false
		fd.hunks = hunks
	}
```

</details>

Next: [`05-serializer-and-tests.md`](05-serializer-and-tests.md) — prove it's correct.
