package main

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"

// serialize_plan_json → parse_edited_plan must round-trip a mixed whole-file + split
// plan: same membership and messages, and a valid partition.
@(test)
test_plan_json_roundtrip :: proc(t: ^testing.T) {
	// files: [0]=2 hunks, [1]=3 hunks, [2]=0 hunks (binary-like).
	d := mk_diff({2, 3, 0})
	input := []Group {
		{file_indices = {2}, hunk_refs = {{0, 0}, {0, 1}}, message = "feat: a"},
		{hunk_refs = {{1, 0}, {1, 1}, {1, 2}}, message = "fix: b"},
	}
	testing.expect(t, groups_partition_ok(input, d))

	text := serialize_plan_json(d, input, context.allocator)
	defer delete(text)

	parsed, ok := parse_edited_plan(text, d, context.allocator)
	defer free_groups(parsed)
	testing.expect(t, ok)
	testing.expect(t, groups_partition_ok(parsed, d))
	testing.expect(t, groups_equal(input, parsed))
}

// A malformed plan (duplicate hunk, out-of-range hunk, no-hunk file in `hunks`, missing
// hunks, blank message) must be auto-repaired into a valid partition with non-empty
// messages.
@(test)
test_parse_edited_plan_repairs :: proc(t: ^testing.T) {
	d := mk_diff({2, 3, 0})
	text := `{
	  "commits": [
	    { "message": "c1", "files": [2], "hunks": [ {"file":0,"hunk":0}, {"file":0,"hunk":0} ] },
	    { "message": "",   "files": [],  "hunks": [ {"file":1,"hunk":0}, {"file":1,"hunk":9}, {"file":2,"hunk":0} ] }
	  ]
	}`
	parsed, ok := parse_edited_plan(text, d, context.allocator)
	defer free_groups(parsed)
	testing.expect(t, ok)
	testing.expect(t, groups_partition_ok(parsed, d))
	for g in parsed {
		testing.expect(t, len(g.message) > 0)
	}
}

// An unknown `legend` key in the user's file must be ignored, not rejected.
@(test)
test_parse_ignores_legend :: proc(t: ^testing.T) {
	d := mk_diff({2, 3, 0})
	text := `{
	  "commits": [ { "message": "m", "files": [0, 1, 2], "hunks": [] } ],
	  "legend": { "files": ["[0] x"], "hunks": ["8:1  @@ foo @@ | +bar"] }
	}`
	parsed, ok := parse_edited_plan(text, d, context.allocator)
	defer free_groups(parsed)
	testing.expect(t, ok)
	testing.expect(t, groups_partition_ok(parsed, d))
}

// Invalid JSON must return false (the caller keeps the prior plan).
@(test)
test_parse_syntax_error :: proc(t: ^testing.T) {
	d := mk_diff({1})
	_, ok := parse_edited_plan("{ this is not json", d, context.allocator)
	testing.expect(t, !ok)
}

// The legend must carry one single-line entry per hunk, each containing its @@ header.
@(test)
test_serialize_legend_preview :: proc(t: ^testing.T) {
	data, _ := os.read_entire_file_from_path("testdata/multihunk3.diff", context.allocator)
	defer delete(data)
	d, ok := parse_diff(string(data))
	defer diff_destroy(d)
	testing.expect(t, ok)
	testing.expectf(t, len(d.files[0].hunks) == 3, "expected 3 hunks, got %d", len(d.files[0].hunks))

	groups := []Group{{hunk_refs = {{0, 0}, {0, 1}, {0, 2}}, message = "m"}}
	text := serialize_plan_json(d, groups, context.allocator)
	defer delete(text)

	Legend_Check :: struct {
		legend: struct {
			hunks: []string,
		},
	}
	lc: Legend_Check
	uerr := json.unmarshal_string(text, &lc, allocator = context.temp_allocator)
	testing.expect(t, uerr == nil)
	testing.expectf(t, len(lc.legend.hunks) == 3, "expected 3 legend hunks, got %d", len(lc.legend.hunks))
	for line in lc.legend.hunks {
		testing.expect(t, strings.contains(line, "@@"))
		testing.expect(t, !strings.contains(line, "\n"))
	}
}

// --- test helper ---

groups_equal :: proc(a, b: []Group) -> bool {
	if len(a) != len(b) do return false
	for g, i in a {
		if g.message != b[i].message do return false
		if len(g.file_indices) != len(b[i].file_indices) do return false
		for fi, j in g.file_indices do if fi != b[i].file_indices[j] do return false
		if len(g.hunk_refs) != len(b[i].hunk_refs) do return false
		for hr, j in g.hunk_refs do if hr != b[i].hunk_refs[j] do return false
	}
	return true
}
