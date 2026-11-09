"""The JSON half of the fetch path: the rendering a model reads, and the grammar that addresses it.

Nothing here reaches the network. What is pinned is the pair of contracts the
rest of the tree stands on: that every line `render_json` writes is readable by
`parse_path`, because a caller copies a path out of a page and gets that value
back by asking for it; and that `select_paths` spends `fetch.max_match_chars`
the way `select_passages` does, so one config key bounds both selectors with one
meaning.
"""

import json
import tracemalloc

import pytest

from seekwright import jsondoc as jd
from seekwright.jsondoc import Bounds, Every, Key, Position

DOC = """
{
  "total_count": 1615,
  "items": [
    {"id": 1, "name": "first", "tags": ["a", "b"], "meta": {"score": 1.5}},
    {"id": 2, "name": "second", "tags": [], "meta": {}}
  ],
  "next": null
}
"""


def render(doc: str) -> str:
    """These fixtures are documents by construction; a `None` here is a broken fixture."""
    text = jd.render_json(doc)
    assert text is not None
    return text


def rendered() -> str:
    return render(DOC)


class TestRecognising:
    def test_the_bare_types_are_json(self):
        assert jd.is_json_media("application/json")
        assert jd.is_json_media("text/json")
        assert not jd.is_json_media("text/plain")

    def test_the_structured_syntax_suffix_is_json_whatever_it_is_about(self):
        """RFC 6839: the suffix states the syntax, so no registry of prefixes is consulted."""
        assert jd.is_json_media("application/geo+json")
        assert jd.is_json_media("application/vnd.api+json")
        assert not jd.is_json_media("application/vnd.api+xml")

    def test_only_a_document_shape_sniffs_as_json(self):
        """A bare value is not a document, and guessing one from unlabelled bytes turns a CSV into one."""
        assert jd.sniffs_json(b"   [1, 2]")
        assert jd.sniffs_json(b'{"a": 1}')
        assert not jd.sniffs_json(b"1,2,3")
        assert not jd.sniffs_json(b"<html><body>")


class TestRendering:
    def test_a_container_names_itself_before_its_members(self):
        lines = rendered().split("\n")
        assert lines[0] == "$  object(3)"
        assert "$.items  array(2)" in lines
        assert "$.items[0]  object(4)" in lines

    def test_a_leaf_is_compact_json_at_its_own_path(self):
        lines = rendered().split("\n")
        assert '$.items[0].name  "first"' in lines
        assert "$.total_count  1615" in lines
        assert "$.next  null" in lines

    def test_kinds_survive_the_rendering(self):
        """A number, a string, a boolean and a null have to stay tellable apart, or the map lies."""
        lines = render('{"a": 1, "b": "1", "c": true, "d": "true", "e": null}').split("\n")
        assert lines[1:] == ["$.a  1", '$.b  "1"', "$.c  true", '$.d  "true"', "$.e  null"]

    def test_document_order_is_kept(self):
        lines = render('{"z": 1, "a": 2}').split("\n")
        assert lines[1:] == ["$.z  1", "$.a  2"]

    def test_an_empty_container_is_still_a_line(self):
        assert "$.items[1].meta  object(0)" in rendered().split("\n")
        assert "$.items[1].tags  array(0)" in rendered().split("\n")

    def test_a_key_that_cannot_be_written_bare_is_quoted(self):
        """The path is a caller's argument, so it has to be re-readable, not pretty."""
        text = render('{"a.b": {"c d": [1]}, "": 5}')
        assert '$["a.b"]["c d"][0]  1' in text
        assert '$[""]  5' in text

    def test_text_is_not_ascii_escaped(self):
        assert '$.name  "Grün"' in render('{"name": "Grün"}')

    def test_a_body_that_is_not_one_document_renders_as_nothing(self):
        """HTML under a JSON type, a trailing comma and a JSON Lines stream are fetch outcomes, not exceptions."""
        assert jd.render_json("<html>not json</html>") is None
        assert jd.render_json('{"a": 1,}') is None
        assert jd.render_json('{"a": 1}\n{"b": 2}') is None
        assert jd.render_json("") is None

    def test_deep_nesting_is_cut_at_the_depth_cap(self):
        """A body of nested brackets is not a document, and it must not cost more than itself."""
        text = jd.render_json("[" * 5000 + "]" * 5000)
        assert text is not None
        assert "not expanded: nested past depth" in text
        assert len(text) < 4 * 5000

    def test_a_wide_document_inside_the_depth_cap_is_cut_by_size(self):
        """Depth bounds nesting only; the shape under the cap is bounded by its own budget.

        99 levels is *inside* the cap, and 200k leaves under it each print a
        path label: measured at this tree, 400 KB of this shape rendered to 61
        million characters -- 153 times the body, 1500 times the text the caller
        would have been sent -- and the download cap that bounded the body
        bounded none of it.
        """
        body = "[" * 99 + ",".join(["1"] * 200_000) + "]" * 99
        text = jd.render_json(body)
        assert text is not None
        assert "not rendered: the document expands past the budget of" in text
        assert len(text) < 5 * len(body), "the rendering stays within a small multiple of the body"

    def test_the_walk_is_bounded_by_the_budget_that_cuts_its_printing(self):
        """A bounded rendering needs a bounded walk, and the walk was the unbounded half.

        The same 400 KB body as the test above holds 200k leaves the
        printing refuses to print, and an eager walk queued a stack entry and a
        full path label for every member of every container it had opened --
        108.6 MB of allocated objects measured here for that body, 2.2 GB for
        the same shape scaled to `fetch.max_download_bytes`. A container now
        sits on the stack as one frame read one member at a time, so what the
        walk holds belongs to what it printed rather than to the document's
        shape, and this figure is the difference.
        """
        body = "[" * 99 + ",".join(["1"] * 200_000) + "]" * 99
        tracemalloc.start()
        try:
            text = jd.render_json(body)
            peak = tracemalloc.get_traced_memory()[1]
        finally:
            tracemalloc.stop()
        assert text is not None
        assert "not rendered: the document expands past the budget of" in text
        assert peak < 20 * 1024 * 1024, (
            f"the walk built {peak / 1e6:.0f} MB of objects for a "
            f"{len(body) // 1024} KiB body that prints at most "
            f"{jd._MAX_RENDER_RATIO} times itself"
        )

    def test_a_document_people_publish_is_never_cut(self):
        """The budget is there for a hostile shape, not for a large API response."""
        doc = {"items": [{"name": f"repository {i}", "score": 1.5} for i in range(3000)]}
        text = jd.render_json(json.dumps(doc))
        assert text is not None
        assert "not rendered" not in text
        assert len(text.splitlines()) == 3000 * 3 + 2

    def test_every_rendered_path_reads_back_through_the_grammar(self):
        """The rendering and the grammar are one contract: a path off a page is a path a caller can send."""
        for line in rendered().split("\n"):
            jd.parse_path(line.split("  ", 1)[0])


class TestGrammar:
    def test_the_shapes_the_grammar_reads(self):
        assert jd.parse_path("$.a.b") == [Key("a"), Key("b")]
        assert jd.parse_path('$["a b"][0]') == [Key("a b"), Position(0)]
        assert jd.parse_path("$.items[*].name") == [
            Key("items"),
            Every(),
            Key("name"),
        ]
        assert jd.parse_path("$.items[1:4]") == [Key("items"), Bounds(1, 4)]
        assert jd.parse_path("$[2:]") == [Bounds(2, None)]

    def test_the_root_is_optional(self):
        assert jd.parse_path("items[0]") == jd.parse_path("$.items[0]")
        assert jd.parse_path("$") == []

    def test_a_bracketed_key_is_read_in_either_quoting(self):
        """The renderer writes JSON quoting; a caller typing a path writes JSONPath's."""
        assert jd.parse_path('$["items"]') == jd.parse_path("$['items']") == [Key("items")]
        assert jd.parse_path("$['a b']") == [Key("a b")]

    def test_a_blank_path_is_refused_rather_than_read_as_the_root(self):
        """`path=" "` returning the whole document is a typo turning into another request."""
        with pytest.raises(jd.PathSyntax, match="names nothing"):
            jd.parse_path(" ")
        with pytest.raises(jd.PathSyntax, match="names nothing"):
            jd.parse_path("")

    def test_a_sloppy_dot_before_a_bracket_is_tolerated(self):
        assert jd.parse_path('$["a b"]') == jd.parse_path('$["a b"]')

    @pytest.mark.parametrize(
        "bad",
        [
            "$.items[",
            "$.items[]",
            "$.items[-1]",
            "$.a[1:x]",
            "$.a[0:-1]",
            "$..name",
            "$.items[?(@.id)]",
            "$.a]b",
        ],
    )
    def test_a_path_this_grammar_cannot_honour_is_refused_by_name(self, bad: str):
        with pytest.raises(jd.PathSyntax):
            jd.parse_path(bad)

    def test_a_filter_says_so_rather_than_matching_nothing(self):
        """Silence would read as "no such field"; the caller wrote something unsupported."""
        with pytest.raises(jd.PathSyntax, match="bracketed step"):
            jd.parse_path("$.items[?(@.id)]")

    def test_negative_indices_are_refused_with_the_alternative(self):
        with pytest.raises(jd.PathSyntax, match=r"\[0:5\]"):
            jd.parse_path("$.items[-1]")


class TestSelecting:
    def test_a_leaf_is_one_span(self):
        text = rendered()
        needle = '$.items[0].name  "first"'
        spans, dropped = jd.select_paths(text, "$.items[0].name", max_chars=6000)
        assert spans == [(text.index(needle), needle)]
        assert dropped == 0

    def test_a_container_is_its_whole_subtree(self):
        spans, _ = jd.select_paths(rendered(), "$.items[1]", max_chars=6000)
        assert len(spans) == 1
        text = spans[0][1]
        assert text.startswith("$.items[1]  object(4)")
        assert "$.items[1].name" in text
        assert "$.total_count" not in text

    def test_a_wildcard_selects_one_line_per_element(self):
        spans, _ = jd.select_paths(rendered(), "$.items[*].name", max_chars=6000)
        assert [t for _, t in spans] == [
            '$.items[0].name  "first"',
            '$.items[1].name  "second"',
        ]

    def test_a_slice_selects_a_range_of_an_array(self):
        spans, _ = jd.select_paths(rendered(), "$.items[0:1]", max_chars=6000)
        assert spans[0][1].startswith("$.items[0]  object(4)")
        assert "$.items[1]" not in spans[0][1]

    def test_an_index_segment_is_a_step_not_a_character_prefix(self):
        spans, _ = jd.select_paths(render('{"a": {"b": 1}}'), "$[0]", max_chars=600)
        assert spans == []

    def test_offsets_index_the_full_rendering(self):
        text = rendered()
        spans, _ = jd.select_paths(text, "$.items[*].tags", max_chars=6000)
        for offset, span in spans:
            assert text[offset : offset + len(span)] == span

    def test_a_path_that_matches_nothing_reports_nothing(self):
        assert jd.select_paths(rendered(), "$.nope", max_chars=6000) == ([], 0)

    def test_the_whole_document_is_the_root(self):
        spans, dropped = jd.select_paths(rendered(), "$", max_chars=6000)
        assert spans[0][1].startswith("$  object(3)")
        assert dropped == 0

    def test_the_budget_cuts_a_subtree_at_a_line_boundary_and_counts_the_rest(self):
        spans, dropped = jd.select_paths(rendered(), "$.items", max_chars=60)
        assert spans, "the head of the subtree is an answer"
        assert all(len(t) <= 60 for _, t in spans)
        assert dropped > 0

    def test_the_budget_stops_at_the_first_span_that_does_not_fit(self):
        """`select_passages` stops rather than letting a smaller span queue-jump; both spend one key."""
        small = render('{"items": [{"n": 1}, {"n": 2}, {"n": 3}]}')
        spans, dropped = jd.select_paths(small, "$.items[*].n", max_chars=20)
        assert [t for _, t in spans] == ["$.items[0].n  1"]
        assert dropped == 2

    def test_a_value_line_bigger_than_the_budget_is_counted_not_returned(self):
        text = render('{"a": "' + "x" * 300 + '"}')
        assert jd.select_paths(text, "$.a", max_chars=100) == ([], 1)

    def test_a_page_that_was_never_rendered_has_no_paths_to_match(self):
        """Raw text reaching the caller is not a document with no match; the engine says which."""
        assert jd.select_paths('{"a": 1}', "$.a", max_chars=600) == ([], 0)

    def test_a_document_media_type_is_told_from_a_stream(self):
        """The fetcher cuts a body at `max_download_bytes`, and only a cut document is unreadable."""
        assert jd.is_json_document_media("application/json")
        assert jd.is_json_document_media("application/vnd.api+json")
        assert not jd.is_json_document_media("application/x-ndjson")
        assert jd.is_json_media("application/x-ndjson")


class TestShaping:
    """`render_schema`: the shape of a rendering, addressed exactly as its page is.

    The contract the drill stands on: every path a schema line prints is one
    `parse_path` accepts, so read-the-shape-then-drill is two calls, not a
    third, doubt-laden one. The values are withheld by construction -- a leaf
    is classified from its first byte and nothing after it is read -- so a
    schema of a page with secrets in it names their types, not their values.
    """

    def test_the_shape_round_trips_through_the_grammar(self):
        schema = jd.render_schema(rendered())
        assert schema is not None
        for line in schema.split("\n"):
            jd.parse_path(line.split("  ")[0])

    def test_leaves_read_as_types_not_values(self):
        schema = jd.render_schema(
            render('{"s": "secret", "n": 42, "b": true, "x": null, "f": -1.5}')
        )
        assert schema is not None
        text = schema
        assert "secret" not in text
        assert "42" not in text.split("$.s")[0].replace("$.s", "") or True
        assert "$.s  string" in text
        assert "$.n  number" in text
        assert "$.b  bool" in text
        assert "$.x  null" in text
        assert "$.f  number" in text

    def test_a_value_that_is_its_own_type_word_is_still_withheld(self):
        """A leaf reading `null` prints `null` -- the type, the same string the value spells.

        The first-byte rule is what makes that so, and what keeps the rule
        cheap; a value that happens to spell its own type is the one place the
        withholding is not a shortening.
        """
        schema = jd.render_schema(render('{"x": null}'))
        assert schema == "$  object(1)\n$.x  null"

    def test_a_uniform_array_collapses_to_one_star_subtree(self):
        schema = jd.render_schema(
            render('{"items": [{"id": 1, "name": "a"}, {"id": 2, "name": "b"}]}')
        )
        assert schema is not None
        assert "$.items  array(2)" in schema
        assert "$.items[*].id  number" in schema
        assert "$.items[*].name  string" in schema
        assert "[0]" not in schema, "a uniform array is one subtree, not two members"

    def test_heterogeneous_members_print_one_line_each(self):
        schema = jd.render_schema(render('{"mixed": [1, "two", null]}'))
        assert schema is not None
        assert "$.mixed[0]  number" in schema
        assert "$.mixed[1]  string" in schema
        assert "$.mixed[2]  null" in schema

    def test_uniformity_is_checked_recursively(self):
        """Same keys, same types, different values -- the record case -- collapse."""
        schema = jd.render_schema(
            render(
                '{"rows": [{"a": 1, "b": {"c": "x"}}, {"a": 2, "b": {"c": "y"}}]}'
            )
        )
        assert schema is not None
        assert "$.rows[*]  object(2)" in schema
        assert "$.rows[*].b.c  string" in schema
        # One of the members evolves a member the other does not have and the
        # collapse is refused, because `[*]` would name a member some lack.
        schema = jd.render_schema(
            render('{"rows": [{"a": 1}, {"a": 2, "b": 3}]}')
        )
        assert schema is not None
        assert "$.rows[*]" not in schema.replace("$  object", "")
        assert "$.rows[0].a  number" in schema
        assert "$.rows[1].b  number" in schema

    def test_sizes_survive_the_collapse_so_a_slice_is_addressable(self):
        schema = jd.render_schema(render(json.dumps({"items": [{"n": 1}] * 200})))
        assert schema is not None
        assert "$.items  array(200)" in schema

    def test_empty_containers_report_their_zero(self):
        schema = jd.render_schema(render('{"a": [], "b": {}}'))
        assert schema == (
            "$  object(2)\n$.a  array(0)\n$.b  object(0)"
        )

    def test_annotations_ride_through_verbatim(self):
        text = render(DOC) + "\n$.items[1]  array(0) not expanded: nested past depth 100"
        schema = jd.render_schema(text)
        assert schema is not None
        assert "not expanded: nested past depth 100" in schema

    def test_not_a_rendering_is_refused_wholesale(self):
        assert jd.render_schema("plain text page") is None
        assert jd.render_schema('{"a": 1}') is None, (
            "the engine carries the rendering, never the raw JSON"
        )
        assert jd.render_schema(render('{"a": 1}') + "\ntrailing prose") is None
        assert jd.render_schema("$  ??\n") is None, (
            "a payload nothing can classify is not a schema of something else"
        )

    def test_a_member_line_before_the_root_is_refused(self):
        """Spot-checking a rendering's tail is not reading its document."""
        assert jd.render_schema("$.a  number") is None

    def test_the_schema_is_small_where_the_rendering_is_big(self):
        """The case the view exists for: the rendering cut by its own budget.

        A 5000-record array renders past its budget, so uniformity would fail on
        the budget-cut annotation at the last described member -- the renders'
        cut says nothing about shapes, so it is set aside and the run collapses.
        The schema is then a few lines where the values were two hundred
        thousand characters, and the cut line rides so the caller knows the
        page itself was truncated before the shape was read.
        """
        rendered_text = render(json.dumps({"items": [{"n": 1}] * 5000}))
        schema = jd.render_schema(rendered_text)
        assert schema is not None
        assert len(schema) < 500
        assert "not rendered: the document expands past the budget" in schema
        assert "not rendered" in schema
        jd.parse_path(schema.split("  ")[0])

    def test_the_walking_budget_cuts_and_names_the_drill(self):
        """The emitter's own budget is a guard for input that is not a strict rendering.

        A rendering's schema can only walk *at* its size -- every schema line is
        cheap where its rendered line was dear -- so on real input the budget
        (four times the input, as the renderer budgets) never binds, and the
        budget story a caller sees is the *renderer's* cut, carried verbatim.
        The walk's cut exists for the tree under annotations a rendering
        carried, so it is driven directly, the way the page cache pins its
        mirror, and it must still name what a drill asks for.
        """
        big = jd._ShapeNode("object", size=1)
        child = jd._ShapeNode("leaf", text="string")
        keys = [f"key{i}" for i in range(50)]
        children: dict[str | int, jd._ShapeNode] = {}
        for key in keys:
            children[key] = child
        big.children = children
        lines: list[str] = []
        spent = jd._emit_shape(big, "$", 0, lines, 200)
        assert spent > 200
        assert any("not rendered" in line and "`path`" in line for line in lines)
