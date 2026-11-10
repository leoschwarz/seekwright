"""The table half of the fetch path: which bodies are tables, and the rendering `path` addresses.

Nothing here reaches the network and no extractor is involved. What is pinned
is that `render_table` writes `jsondoc`'s own line grammar -- one line per row
or cell, each starting at the root and labelled with the path that addresses
it -- because that shared grammar is the whole reason `fetch`'s `path`,
`structure` and `offset` answer a CSV with no new machinery, and a rendering
that drifted from it would be silently misread as a JSON shape. The two cuts
are pinned here too: a rendering is bounded by `jsondoc`'s budget, and a record
stream that stops parsing stops printing rather than failing the fetch.
"""

import csv

from seekwright import jsondoc as jd
from seekwright import tabledoc as td
from seekwright.jsondoc import Key, Position

TABLE = (
    "id,price,city,qty,note\n"
    "1,12.50,London,3,four\n"
    "2,7.00,Leeds,11,short\n"
    "3,3.99,Bristol,2,x\n"
    "4,120.00,Perth,1,long note here\n"
    "5,0.50,Cork,7,\n"
)


def render(text: str, delimiter: str = ",") -> str:
    """These fixtures are tables by construction; a `None` here is a broken fixture."""
    rendered = td.render_table(text, delimiter=delimiter)
    assert rendered is not None
    return rendered


def table() -> str:
    return render(TABLE)


class TestRecognising:
    def test_the_types_that_name_a_table_by_themselves(self):
        assert td.is_table_media("text/csv")
        assert td.is_table_media("application/csv")
        assert td.is_table_media("text/tab-separated-values")
        assert not td.is_table_media("text/plain")

    def test_a_spreadsheet_type_is_not_claimed(self):
        """`vnd.ms-excel` is as often a binary workbook as a CSV export, and a guess is not a read."""
        assert not td.is_table_media("application/vnd.ms-excel")


class TestRendering:
    def test_the_whole_small_table_renders(self):
        lines = table().split("\n")
        assert lines[:4] == [
            "$  object(1)",
            "$.rows  array(5)",
            "$.rows[0]  object(5)",
            '$.rows[0].id  "1"',
        ]
        assert '$.rows[0].price  "12.50"' in lines
        assert "$.rows[4]  object(5)" in lines

    def test_every_cell_is_a_quoted_string_whatever_it_holds(self):
        """A CSV has no types, so `007` and `1.50` come back as the exact text the file wrote."""
        lines = render("id,price,code,empty\n1,1.50,007,\n").split("\n")
        assert '$.rows[0].price  "1.50"' in lines
        assert '$.rows[0].code  "007"' in lines
        assert '$.rows[0].empty  ""' in lines

    def test_a_cell_holding_a_newline_stays_on_one_line(self):
        """The line grammar is one node per line, so the leaf is JSON-escaped, not wrapped."""
        rendered = render('a,b\n"x\ny",2\n')
        assert '$.rows[0].a  "x\\ny"' in rendered.split("\n")
        assert len(rendered.split("\n")) == 5

    def test_a_column_name_that_cannot_be_written_bare_is_quoted_and_reads_back(self):
        """The path is a caller's argument, so a header cell with a newline has to round-trip."""
        rendered = render('"a\nb",c\n1,2\n')
        path = '$.rows[0]["a\\nb"]'
        assert f'{path}  "1"' in rendered.split("\n")
        assert jd.parse_path(path) == [
            Key(name="rows"),
            Position(ordinal=0),
            Key(name="a\nb"),
        ]

    def test_a_column_name_holding_a_quote_is_json_quoted(self):
        assert '$.rows[0]["a\\"b"]  "1"' in render('a"b,c\n1,2\n').split("\n")

    def test_a_short_row_is_padded_and_a_long_row_is_cut_to_the_header(self):
        """Every row object has the header's width, which is what lets `render_schema` collapse it."""
        lines = render("a,b,c\n1\n1,2,3,4\n").split("\n")
        assert "$.rows[0]  object(3)" in lines
        assert "$.rows[1]  object(3)" in lines
        assert '$.rows[0].c  ""' in lines
        assert '$.rows[1].c  "3"' in lines
        assert not any(line.endswith('"4"') for line in lines)


class TestHeaderRules:
    def test_an_empty_header_cell_gets_a_positional_name(self):
        assert '$.rows[0].column2  "2"' in render("id,,note\n1,2,3\n").split("\n")

    def test_a_long_header_cell_is_cut_to_the_cap(self):
        """The name labels every cell under it and is a printed path, so it cannot be unbounded."""
        rendered = render(f"{'z' * 200},b\n1,2\n")
        label = f"$.rows[0].{'z' * td.MAX_COLUMN_NAME_CHARS}"
        assert f'{label}  "1"' in rendered.split("\n")
        assert "z" * (td.MAX_COLUMN_NAME_CHARS + 1) not in rendered

    def test_a_bom_is_not_part_of_the_first_column_name(self):
        lines = render("\ufeffid,name\n1,Ada\n").split("\n")
        assert '$.rows[0].id  "1"' in lines
        assert '$.rows[0].name  "Ada"' in lines

    def test_a_blank_line_between_records_does_not_consume_a_row_index(self):
        lines = render("a,b\n1,x\n\n2,y\n").split("\n")
        assert "$.rows[1]  object(2)" in lines
        assert '$.rows[1].a  "2"' in lines
        assert "$.rows[2]" not in "\n".join(lines)

    def test_two_columns_with_one_name_print_twice_and_both_are_addressable(self):
        """The file's defect is reported, not renamed away: `path` answers both cells."""
        spans, _ = jd.select_paths(render("id,id\n1,2\n"), "$.rows[0].id", max_chars=6000)
        assert [text for _, text in spans] == ['$.rows[0].id  "1"\n$.rows[0].id  "2"']


class TestSharedGrammar:
    """The rendering is `jsondoc`'s line grammar, which is why `path` needed no change.

    `structure` and `path` are keyed off lines that start at the root and
    `jsondoc` can read, so these are the assertions a drift in the rendering
    would fail rather than have the engine misread.
    """

    def test_every_line_is_a_path_the_grammar_reads(self):
        for line in table().split("\n"):
            jd.parse_path(line.split("  ", 1)[0])

    def test_the_shape_names_the_columns_and_withholds_the_values(self):
        schema = jd.render_schema(table())
        assert schema is not None
        lines = schema.split("\n")
        assert "$.rows[*]  object(5)" in lines
        for column in ("id", "price", "city", "qty", "note"):
            assert f"$.rows[*].{column}  string" in lines
        assert "12.50" not in schema

    def test_one_column_of_every_row_is_one_wildcard_step(self):
        spans, dropped = jd.select_paths(table(), "$.rows[*].price", max_chars=6000)
        assert [text for _, text in spans] == [
            '$.rows[0].price  "12.50"',
            '$.rows[1].price  "7.00"',
            '$.rows[2].price  "3.99"',
            '$.rows[3].price  "120.00"',
            '$.rows[4].price  "0.50"',
        ]
        assert dropped == 0

    def test_a_slice_of_rows_is_two_whole_row_blocks(self):
        rendered = table()
        spans, dropped = jd.select_paths(rendered, "$.rows[1:3]", max_chars=6000)
        assert dropped == 0
        assert len(spans) == 1, "adjacent rows are one span"
        offset, block = spans[0]
        lines = block.split("\n")
        assert len(lines) == 12
        assert lines[0] == "$.rows[1]  object(5)"
        assert lines[6] == "$.rows[2]  object(5)"
        assert lines[-1] == '$.rows[2].note  "x"'
        assert rendered[offset : offset + len(block)] == block

    def test_a_column_name_holding_a_colon_stays_a_name_through_the_grammar(self):
        """`Price: USD` is one header cell, and a slice bound is never quoted.

        The only header character that ever broke the round trip, and it broke
        all three readers at once: the path, the shape view, and a `path` read of
        an unrelated column, since the selector re-reads every printed line.
        """
        rendered = render("id,Price: USD\n1,12.50\n")
        line = next(
            line for line in rendered.split("\n") if line.startswith('$.rows[0]["Price')
        )
        assert jd.parse_path(line.split("  ", 1)[0]) == [
            Key(name="rows"),
            Position(ordinal=0),
            Key(name="Price: USD"),
        ]
        schema = jd.render_schema(rendered)
        assert schema is not None
        assert '$.rows[*]["Price: USD"]  string' in schema.split("\n")
        spans, dropped = jd.select_paths(rendered, '$.rows[*]["Price: USD"]', max_chars=600)
        assert dropped == 0
        assert [text for _, text in spans] == ['$.rows[0]["Price: USD"]  "12.50"']


class TestDelimiters:
    def test_a_tab_type_declares_its_delimiter_whatever_the_body_looks_like(self):
        """The type states the delimiter, so a body full of commas does not out-vote it."""
        assert td.table_delimiter("text/tab-separated-values", "a,b,c\n1,2,3\n") == "\t"

    def test_a_european_export_served_as_csv_is_read_on_semicolons(self):
        assert td.table_delimiter("text/csv", "a;b;c\n1;2;3\n") == ";"

    def test_a_comma_inside_a_quoted_value_does_not_move_the_delimiter(self):
        """Counting commas would be fooled here; parsing the head four ways is not."""
        assert td.table_delimiter("text/csv", 'a,b\n"x,y,z",2\n') == ","

    def test_a_pipe_separated_body_is_sniffed(self):
        assert td.table_delimiter("text/csv", "a|b|c\n1|2|3\n") == "|"

    def test_a_separator_inside_a_quoted_cell_does_not_outvote_the_delimiter(self):
        """An address cell of "1 Main St; London; UK" is one cell, not four columns."""
        body = 'id,address\n1,"1 Main St; London; UK"\n2,"2 Oak Ave; Leeds; UK"\n'
        assert td.table_delimiter("text/csv", body) == ","
        assert render(body).split("\n")[4] == (
            '$.rows[0].address  "1 Main St; London; UK"'
        )

    def test_prose_with_no_delimiter_stays_on_commas_and_renders_one_column(self):
        text = "some prose here\nand more of it\n"
        assert td.table_delimiter("text/csv", text) == ","
        assert render(text).split("\n")[3] == '$.rows[0]["some prose here"]  "and more of it"'


class TestCuts:
    """The two lines that say a rendering is not the whole table.

    The budget is `jsondoc`'s own, so a table costs at most what a JSON
    document of the same body costs, and the parse stop is the reader's field
    cap -- never raised, because `csv.field_size_limit` is process-global state.
    """

    def test_a_table_wider_than_its_budget_ends_with_the_line_naming_the_cut(self):
        body = "id,price,city,qty,note\n" + "".join(
            f"{n},12.50,London,3,four\n" for n in range(3000)
        )
        rendered = render(body)
        budget = max(jd.MIN_RENDER_CHARS, jd.MAX_RENDER_RATIO * len(body))
        last = rendered.split("\n")[-1]
        printed = int(last.split("]")[0].removeprefix("$.rows["))
        assert 0 < printed < 3000
        assert last == (
            f"$.rows[{printed}]  not rendered: the table expands past the budget of "
            f"{budget} characters, {jd.MAX_RENDER_RATIO} times the file's own "
            f"{len(body)}; {printed} rows are printed above and no further row "
            "of the file is addressable in this page -- fetch with `offset` to "
            "page through what is here, or raise fetch.max_download_bytes, the "
            "budget being a ratio of it"
        )
        assert f"$.rows  array({printed})" in rendered.split("\n")
        assert len(rendered) < 5 * len(body), "the rendering stays within a small multiple"
        assert jd.select_paths(rendered, f"$.rows[{printed + 5}]", max_chars=600)[0] == [], (
            "the row count printed is a bound, not the file's length"
        )

    def test_the_rows_above_a_parse_stop_are_kept_and_counted(self):
        """The record-stream rule: whole rows survive where the reader gave up."""
        body = "id,name\n1,Ada\n" + "x" * 200_000 + "\n"
        rendered = render(body)
        assert '$.rows[0].name  "Ada"' in rendered.split("\n")
        assert rendered.split("\n")[-1] == (
            "$.rows[1]  not rendered: this file stopped parsing at this row "
            f"(field larger than field limit ({csv.field_size_limit()})); "
            "the rows above it are complete"
        )
        assert len(rendered) < len(body) / 100

    def test_a_parse_stop_before_any_row_leaves_the_body_as_the_answer(self):
        """Columns and no row say nothing about the file, so the bytes ride on."""
        assert td.render_table("a\n" + "x" * 200_000 + "\n", delimiter=",") is None


class TestNothingToRender:
    def test_an_empty_body_renders_as_nothing(self):
        assert td.render_table("", delimiter=",") is None
        assert td.render_table("\n\n", delimiter=",") is None

    def test_a_header_only_file_is_a_table_with_no_rows(self):
        assert render("a,b\n") == "$  object(1)\n$.rows  array(0)"
