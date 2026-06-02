# 03 — Splitting into file sections

## Goal

Make `parse_diff` real. Split the whole buffer into one `File_Diff` per `diff --git` section, and for
each section figure out its `kind`, its paths, and where its header ends. You'll *stop just short* of
parsing the `@@` hunks — that's increment 04. After this step, `parse_diff` returns a `Diff` whose
files are correctly bounded and classified.

## Why it matters

This is the outer of the two nested splits. The pattern you use here — "walk lines; when you hit a
marker, close the previous span and open a new one" — is the exact same pattern you'll reuse for hunks
in 04. Learn it once here.

It's also where you meet Odin's memory model head-on: to *collect* a variable number of files you need
a growable array, and growable means **allocation**, which means **deciding who allocates**.

## New Odin concepts

**`strings.has_prefix`** — does a line start with a marker?

```odin
strings.has_prefix("diff --git a/x b/x", "diff --git ")   // → true
```

**Prefix dispatch with a conditionless `switch`.** Odin's `switch` with no expression means
`switch true` — the first `case` whose condition is true runs. No `break` needed (Odin cases don't
fall through). Multiple conditions in one case are comma-separated:

```odin
switch {
case strings.has_prefix(line, "new file mode "):
    is_new = true
case strings.has_prefix(line, "old mode "), strings.has_prefix(line, "new mode "):
    is_mode = true
case:                       // the default case (empty condition)
    // nothing
}
```

**Dynamic arrays** — `[]T` is a fixed view; `[dynamic]T` is a growable, owned array you can `append`
to. When you're done collecting, `arr[:]` gives you a plain `[]T` view of its contents:

```odin
xs := make([dynamic]int)
append(&xs, 10)
append(&xs, 20)
view := xs[:]        // []int of length 2
```

**Who allocates? The `context` system.** `make` and `append` allocate using `context.allocator` — an
implicit, ambient allocator Odin threads through every call. The existing saft code passes allocators
explicitly (you've seen `context.temp_allocator` all over `git.odin`). For a library procedure the
clean idiom is to accept an allocator with a default and install it:

```odin
parse_diff :: proc(src: string, allocator := context.allocator) -> (Diff, bool) {
    context.allocator = allocator   // every make/append below (and in callees) uses it
    // ...
}
```

`allocator := context.allocator` means "callers can pass one, but if they don't, use the ambient
default." Setting `context.allocator` inside the proc affects this call and everything it calls.

**`strings.split`** — split a string on a separator into `[]string` (each element is a *view*, no
content copied). It needs an allocator for the little array of views:

```odin
parts := strings.split("a/x b/x", " ", context.temp_allocator)   // → ["a/x", "b/x"]
```

**`strings.trim_right`** — trim trailing characters in a cutset, returning a view:

```odin
strings.trim_right("hello\n", "\r\n")   // → "hello"
```

## The git-diff bits you'll touch

From 00: the `diff --git` boundary (§1), the header lines and path extraction (§2), and the file-kind
classification (§5). You are **not** touching `@@` hunks or body lines yet.

## Your task

### a) Three small view helpers

```odin
// Strip a known prefix and the trailing newline. Returns a view.
line_value :: proc(line: string, prefix: string) -> string

// Drop a leading "a/" or "b/" git path decoration (leave "/dev/null" etc).
path_value :: proc(p: string) -> string

// Parse the "diff --git a/OLD b/NEW" line into the two paths.
parse_diff_git_paths :: proc(line: string) -> (old_path: string, new_path: string, ok: bool)
```

Hints: `line_value` is `strings.trim_right(line[len(prefix):], "\r\n")`. `path_value` checks
`has_prefix(p, "a/")` / `"b/"` and returns `p[2:]` if so. `parse_diff_git_paths` calls
`line_value(line, "diff --git ")`, then `strings.split` on `" "`; if you don't get exactly 2 parts,
return `ok = false`; otherwise `path_value` each part.

> Path parsing is best-effort for M1: it assumes paths contain no spaces (git quotes those — out of
> scope). Paths aren't load-bearing for the round-trip, so don't over-engineer this.

### b) `parse_file_section` — classify one section (no hunks yet)

```odin
parse_file_section :: proc(fs: string) -> (File_Diff, bool)
```

`fs` is one file's complete diff text (its `diff --git` line through to — but not including — the next
`diff --git`). Build a `File_Diff`:

1. Set `fd.raw = fs` immediately (the whole section, byte-exact).
2. Walk lines with `next_line`. Before each call, save `ls := pos` (the byte offset of this line).
3. If a line starts with `@@ `, record `first_hunk_at = ls` and **stop** the loop — the header ends
   here. (You won't parse the hunks until 04.)
4. Otherwise, `switch` on the line's prefix to set boolean flags (`is_new`, `is_deleted`, `is_rename`,
   `is_binary`, `is_mode`) and to capture paths (`diff --git`, `--- `, `+++ `, `rename from `,
   `rename to `).
5. After the loop: `header_end := first_hunk_at >= 0 ? first_hunk_at : len(fs)` and
   `fd.header = fs[:header_end]`.
6. Decide `fd.kind` from the flags, with this **precedence** (see note): Binary → Rename → Add_File →
   Delete_File → Mode_Change (only if no hunks) → else Modify.
7. Return `fd, true`. (The `hunks` field stays empty `nil` this increment.)

### c) `parse_diff` — split the buffer into sections

Replace your stub:

```odin
parse_diff :: proc(src: string, allocator := context.allocator) -> (Diff, bool)
```

1. Install the allocator (see concepts above).
2. If `src` doesn't start with `"diff --git "`, return `{}, false`. *(Our input is raw `git diff`
   output, which always does. This guarantees the sections tile `src` from byte 0.)*
3. `files := make([dynamic]File_Diff)`.
4. Walk lines. Track `section_start` (init `-1`). On each `diff --git ` line at offset `ls`: if a
   section was already open (`section_start >= 0`), parse `src[section_start:ls]` and `append` it;
   then set `section_start = ls`.
5. After the loop, parse and append the final section `src[section_start:]`.
6. If no files were collected, return `{}, false`. Otherwise return
   `Diff{files = files[:], src = src}, true`.

**Hints**

1. The "close the previous span when you see the next marker" trick is identical in `parse_diff`
   (marker = `diff --git `) and, soon, in `parse_hunks` (marker = `@@ `). Same shape.
2. `ls := pos` must be captured *before* calling `next_line(src, &pos)` — that's the start offset of
   the line you're about to read.
3. If `parse_file_section` returns `false`, propagate it: `return {}, false`.

**Edge cases**

- `kind` precedence note: a single file can match several flags (e.g. a *new binary* file is both
  `Add_File` and `Binary`). Pick one with the precedence above — **Binary wins**, because the property
  that matters downstream is "has no hunks, cannot be split below file level." Keep your test fixtures
  unambiguous (a plain modified binary, a plain new text file) so you don't have to agonise over this.
- Sections with no hunks (binary, pure rename, mode-only): `first_hunk_at` stays `-1`, so `header` is
  the entire section and `hunks` is empty. That's correct.

## Verify

```sh
cd cli
odin check .
```

Must compile. You can't fully exercise it until `serialize` and the tests exist (increment 05), but
the structure is now in place and classified.

---

<details>
<summary>Reference solution</summary>

```odin
// line_value strips a known prefix and the trailing newline, returning a view.
line_value :: proc(line: string, prefix: string) -> string {
	return strings.trim_right(line[len(prefix):], "\r\n")
}

// path_value drops a leading "a/" or "b/" git decoration (leaving /dev/null etc).
path_value :: proc(p: string) -> string {
	if strings.has_prefix(p, "a/") || strings.has_prefix(p, "b/") do return p[2:]
	return p
}

parse_diff_git_paths :: proc(line: string) -> (old_path: string, new_path: string, ok: bool) {
	rest := line_value(line, "diff --git ")
	parts := strings.split(rest, " ", context.temp_allocator)
	if len(parts) != 2 do return "", "", false
	return path_value(parts[0]), path_value(parts[1]), true
}

parse_file_section :: proc(fs: string) -> (File_Diff, bool) {
	fd: File_Diff
	fd.raw = fs

	is_new, is_deleted, is_rename, is_binary, is_mode: bool
	first_hunk_at := -1

	pos := 0
	for {
		ls := pos
		line, ok := next_line(fs, &pos)
		if !ok do break
		if strings.has_prefix(line, "@@ ") {
			first_hunk_at = ls
			break
		}
		switch {
		case strings.has_prefix(line, "diff --git "):
			op, np, pok := parse_diff_git_paths(line)
			if pok {
				fd.old_path = op
				fd.new_path = np
			}
		case strings.has_prefix(line, "new file mode "):
			is_new = true
		case strings.has_prefix(line, "deleted file mode "):
			is_deleted = true
		case strings.has_prefix(line, "rename from "):
			is_rename = true
			fd.old_path = line_value(line, "rename from ")
		case strings.has_prefix(line, "rename to "):
			is_rename = true
			fd.new_path = line_value(line, "rename to ")
		case strings.has_prefix(line, "old mode "), strings.has_prefix(line, "new mode "):
			is_mode = true
		case strings.has_prefix(line, "Binary files "):
			is_binary = true
		case strings.has_prefix(line, "--- "):
			fd.old_path = path_value(line_value(line, "--- "))
		case strings.has_prefix(line, "+++ "):
			fd.new_path = path_value(line_value(line, "+++ "))
		}
	}

	header_end := len(fs)
	if first_hunk_at >= 0 do header_end = first_hunk_at
	fd.header = fs[:header_end]

	switch {
	case is_binary:
		fd.kind = .Binary
	case is_rename:
		fd.kind = .Rename
	case is_new:
		fd.kind = .Add_File
	case is_deleted:
		fd.kind = .Delete_File
	case is_mode && first_hunk_at < 0:
		fd.kind = .Mode_Change
	case:
		fd.kind = .Modify
	}

	// Hunks are parsed in increment 04; for now `fd.hunks` stays nil.
	return fd, true
}

parse_diff :: proc(src: string, allocator := context.allocator) -> (Diff, bool) {
	context.allocator = allocator
	if !strings.has_prefix(src, "diff --git ") do return {}, false

	files := make([dynamic]File_Diff)
	section_start := -1
	pos := 0
	for {
		ls := pos
		line, ok := next_line(src, &pos)
		if !ok do break
		if strings.has_prefix(line, "diff --git ") {
			if section_start >= 0 {
				fd, fok := parse_file_section(src[section_start:ls])
				if !fok do return {}, false
				append(&files, fd)
			}
			section_start = ls
		}
	}
	if section_start >= 0 {
		fd, fok := parse_file_section(src[section_start:])
		if !fok do return {}, false
		append(&files, fd)
	}
	if len(files) == 0 do return {}, false
	return Diff{files = files[:], src = src}, true
}
```

</details>

Next: [`04-hunk-parsing.md`](04-hunk-parsing.md) — fill in the hunks.
