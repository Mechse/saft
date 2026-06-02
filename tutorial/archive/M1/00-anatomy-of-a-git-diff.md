# 00 — Anatomy of a git diff

Keep this page open while you do 01–05. It names every part of the format your parser has to handle.
All examples below are **real `git diff` output** (you'll generate your own copies in increment 05).

Our parser only handles the output of plain `git diff` / `git diff --cached` (the "unified" format).
That output always starts with the bytes `diff --git ` — that fact is load-bearing, as you'll see.

---

## 1. The shape: files, then hunks

A diff is a list of **file sections**. Each file section starts with a `diff --git` line and contains:

- a **header** (a few metadata lines), then
- zero or more **hunks** — the actual changed regions, each introduced by a `@@ ... @@` line.

```
diff --git a/a.txt b/a.txt      ← file section starts here
index 83db48f..8792505 100644   ┐
--- a/a.txt                     │ header (everything before the first @@)
+++ b/a.txt                     ┘
@@ -1,3 +1,3 @@                 ← hunk starts here
 line1                          ┐
-line2                          │ hunk body: ' ' context, '-' removed, '+' added
+line2 changed                  │
 line3                          ┘
```

That's the whole skeleton: **a buffer is a sequence of file sections; a file section is a header
followed by a sequence of hunks.** Your parser is two nested splits.

---

## 2. The header lines

Within a file section, before the first `@@`, you may see any of these. You dispatch on the **line
prefix**:

| Line starts with… | Meaning | What you extract |
|---|---|---|
| `diff --git a/X b/X` | start of a file section | old path `X`, new path `X` |
| `index 83db..8792 100644` | blob hashes + mode | *(ignore)* |
| `--- a/X` | the "before" file | old path (`/dev/null` if the file is new) |
| `+++ b/X` | the "after" file | new path (`/dev/null` if the file is deleted) |
| `@@ -1,3 +1,3 @@` | start of a hunk | the four line numbers (see §3) |

Git decorates paths with `a/` and `b/` prefixes. `--- /dev/null` or `+++ /dev/null` means the file
didn't exist on that side.

---

## 3. The hunk header: `@@ -old +new @@`

```
@@ -1,3 +1,3 @@
   │  │   │
   │  │   └─ new side: starts at line 1, spans 3 lines
   │  └──── old side: starts at line 1, spans 3 lines
   └─────── always two ranges, old then new
```

Format: `@@ -<old_start>,<old_count> +<new_start>,<new_count> @@`.

**Edge case — the count is optional.** When a range covers exactly one line, git omits the comma:
`@@ -5 +5,2 @@` means old = (start 5, **count 1**), new = (start 5, count 2). Your parser must default
a missing count to `1`.

**Edge case — a trailing section heading.** Git sometimes appends the enclosing function/context after
the closing `@@`:

```
@@ -7,4 +7,4 @@ l6
```

The ` l6` is decoration. Parse the numbers from *between* the two `@@` markers and ignore the rest —
but keep the whole line intact in your `raw`/`header` view so reconstruction stays byte-exact.

---

## 4. The body lines

After a hunk header, every line carries a one-character prefix:

| Prefix | Meaning |
|---|---|
| `' '` (space) | context — unchanged, shown on both sides |
| `-` | removed from the old file |
| `+` | added in the new file |
| `\` | a meta line, almost always `\ No newline at end of file` |

You don't need to interpret these for M1 — you keep the body as one exact byte-slice. But you must not
be *confused* by them: a `+` or `-` line is body, not a new hunk.

**Edge case — no trailing newline.** If a file doesn't end in `\n`, git emits a sentinel line:

```
@@ -1,3 +1,3 @@
 x1
-x2
+x2 changed
 x3
\ No newline at end of file
```

That `\ No newline…` line is part of the hunk body. As long as you slice the body as raw bytes, it's
handled for free.

---

## 5. The awkward file kinds

Not every file section has hunks. These are the cases your `kind` classifier must recognize:

**New file** — header gains `new file mode`, and `---` is `/dev/null`:
```
diff --git a/newf.txt b/newf.txt
new file mode 100644
index 0000000..5786b13
--- /dev/null
+++ b/newf.txt
@@ -0,0 +1,2 @@
+brand
+new
```

**Deleted file** — `deleted file mode`, and `+++` is `/dev/null`:
```
diff --git a/a.txt b/a.txt
deleted file mode 100644
index 83db48f..0000000
--- a/a.txt
+++ /dev/null
@@ -1,3 +0,0 @@
-line1
-line2
-line3
```

**Pure rename** — *no hunks at all*, no `---`/`+++`. Paths come from `rename from`/`rename to`:
```
diff --git a/orig.txt b/renamed.txt
similarity index 100%
rename from orig.txt
rename to renamed.txt
```

**Mode change only** — *no hunks*, just permission bits:
```
diff --git a/c.txt b/c.txt
old mode 100644
new mode 100755
```

**Binary file** — *no hunks*; git refuses to show line-level changes:
```
diff --git a/bin.dat b/bin.dat
index cc232b7..647c3fd 100644
Binary files a/bin.dat and b/bin.dat differ
```

> **Why `kind` matters later:** the whole point of saft is splitting a diff into commits. A binary
> file or a rename *cannot be split below the file level* — there are no hunks to divide. Recording
> `kind` now is what lets the later milestone know "this file goes into one commit, whole."

---

## 6. Multiple files, multiple hunks

A real diff stacks file sections back-to-back, and a file can have several hunks:

```
diff --git a/b.txt b/b.txt
index 01f84f8..a0eab4e 100644
--- a/b.txt
+++ b/b.txt
@@ -1,4 +1,4 @@        ← hunk 1
-l1
+l1 X
 l2
 l3
 l4
@@ -7,4 +7,4 @@ l6      ← hunk 2 (note the trailing heading)
 l7
 l8
 l9
-l10
+l10 Y
```

The next `diff --git` line is what ends the previous file section. The next `@@ ` line is what ends
the previous hunk. Both of your splits work the same way: **a new marker closes the previous span.**

---

## Cheat sheet (prefixes your parser dispatches on)

```
diff --git           → start a new FILE section
new file mode        → kind = Add_File
deleted file mode    → kind = Delete_File
rename from / to     → kind = Rename   (+ paths)
old mode / new mode  → kind = Mode_Change (if no hunks)
Binary files         → kind = Binary
--- / +++            → old/new path
@@                   → start a new HUNK (parse the 4 numbers)
 / + / - / \         → hunk body lines (kept raw)
```

Onward to [`01-skeleton-and-types.md`](01-skeleton-and-types.md).
