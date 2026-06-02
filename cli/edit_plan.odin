package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"

// The editable plan is a JSON document the user opens in $EDITOR. Assignments are terse
// (whole files by index, hunks by {file, hunk} index) so they are easy to move between
// commits; all human-readable context lives in a read-only `legend` that the parser
// ignores. See serialize_plan_json / parse_edited_plan below.

@(private = "file")
Hunk_Ref_JSON :: struct {
	file: int,
	hunk: int,
}

@(private = "file")
Commit_JSON :: struct {
	message: string,
	files:   []int,
	hunks:   []Hunk_Ref_JSON,
}

@(private = "file")
Legend_JSON :: struct {
	files: []string,
	hunks: []string,
}

@(private = "file")
Plan_Out_JSON :: struct {
	commits: []Commit_JSON,
	legend:  Legend_JSON,
}

// Plan_In_JSON is the parse target: only `commits` is read. An unknown `legend` key in
// the user's file is skipped by json.unmarshal.
@(private = "file")
Plan_In_JSON :: struct {
	commits: []Commit_JSON,
}

// serialize_plan_json renders the proposed split as the editable JSON document. The
// legend lists every file (index → path/kind) and every hunk of every multi-hunk file
// (fileIdx:hunkIdx → @@ header | one-line preview), so the user can move any hunk and
// even split a file the model left whole.
serialize_plan_json :: proc(d: Diff, groups: []Group, allocator := context.allocator) -> string {
	commits := make([]Commit_JSON, len(groups), context.temp_allocator)
	for g, gi in groups {
		hrs := make([]Hunk_Ref_JSON, len(g.hunk_refs), context.temp_allocator)
		for hr, i in g.hunk_refs {
			hrs[i] = {hr.file_idx, hr.hunk_idx}
		}
		commits[gi] = {message = g.message, files = g.file_indices, hunks = hrs}
	}

	file_lines := make([dynamic]string, context.temp_allocator)
	hunk_lines := make([dynamic]string, context.temp_allocator)
	for f, fi in d.files {
		append(&file_lines, fmt.tprintf("[%d] %s (%s)", fi, display_path(f), kind_label(f.kind)))
		for h, hi in f.hunks {
			append(
				&hunk_lines,
				fmt.tprintf(
					"%d:%d  %s | %s",
					fi,
					hi,
					strings.trim_right(h.header, "\r\n"),
					hunk_preview(h, context.temp_allocator),
				),
			)
		}
	}

	out := Plan_Out_JSON {
		commits = commits,
		legend = {files = file_lines[:], hunks = hunk_lines[:]},
	}

	data, err := json.marshal(
		out,
		json.Marshal_Options{pretty = true, use_spaces = true, spaces = 2},
		allocator,
	)
	if err != nil {
		return strings.clone("{\n  \"commits\": []\n}", allocator)
	}
	return string(data)
}

// parse_edited_plan decodes the user's edited JSON back into committable Groups. JSON
// syntax errors return false (the caller keeps the prior plan). A successfully-parsed but
// malformed plan (duplicate/missing/out-of-range refs, no-hunk files placed in `hunks`)
// is forced valid by repair_groups_partition; any commit left without a message gets a
// deterministic fallback so user-written messages are never overwritten by the model.
parse_edited_plan :: proc(text: string, d: Diff, allocator := context.allocator) -> ([]Group, bool) {
	p: Plan_In_JSON
	if err := json.unmarshal_string(text, &p, allocator = context.temp_allocator); err != nil {
		return nil, false
	}

	raw := make([dynamic]Group, context.temp_allocator)
	for c in p.commits {
		fis := make([]int, len(c.files), context.temp_allocator)
		copy(fis, c.files)
		hrs := make([]Hunk_Ref, len(c.hunks), context.temp_allocator)
		for h, i in c.hunks {
			hrs[i] = Hunk_Ref{h.file, h.hunk}
		}
		append(&raw, Group{file_indices = fis, hunk_refs = hrs, message = c.message})
	}

	groups := repair_groups_partition(raw[:], d, allocator)
	for &g in groups {
		if len(g.message) == 0 {
			g.message = fallback_message(d, g, allocator)
		}
	}
	return groups, true
}

// hunk_preview returns a single-line, rune-safe-truncated preview of a hunk's first one
// or two changed (+/-) lines, for the read-only legend.
@(private = "file")
hunk_preview :: proc(h: Hunk, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	pos := 0
	shown := 0
	for shown < 2 {
		line, ok := next_line(h.body, &pos)
		if !ok do break
		if len(line) == 0 do continue
		if line[0] != '+' && line[0] != '-' do continue
		if shown > 0 do strings.write_string(&sb, " ")
		strings.write_string(&sb, strings.trim_right(line, "\r\n"))
		shown += 1
	}
	return truncate_runes(strings.to_string(sb), 60, allocator)
}

// truncate_runes returns s clipped to at most n runes (with an ellipsis), never splitting
// a multi-byte rune — so the result is always valid UTF-8 for the JSON encoder.
@(private = "file")
truncate_runes :: proc(s: string, n: int, allocator := context.temp_allocator) -> string {
	count := 0
	for _, idx in s {
		if count == n {
			return strings.concatenate({s[:idx], "…"}, allocator)
		}
		count += 1
	}
	return s
}
