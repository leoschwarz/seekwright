"""Exa MCP response parsing.

The fixture below is the real format captured from ``https://mcp.exa.ai/mcp``:
the server returns formatted plain text, and its ``structuredContent`` is empty,
so this parser is the only thing standing between us and dropped results.
"""

from seekwright.providers.exa_mcp import ExaMcpProvider

SAMPLE = """\
Title: Write-Ahead Logging
URL: https://www.sqlite.org/wal.html
Published: 2026-04-13T00:00:00.000Z
Author: N/A
Highlights:
The default method by which SQLite implements atomic commit is a rollback journal.
...
The WAL approach inverts this. The original content is preserved in the database.
Title: SQLite WAL mode explained
URL: https://example.com/wal-explained
Published: N/A
Author: Someone
Highlights:
WAL allows readers and one writer to proceed concurrently.
"""

# Exa really does send `Title: N/A` -- the live endpoint returned one for
# modelcontextprotocol.io, whose heading was sitting in the body all along.
UNTITLED = """\
Title: N/A
URL: https://example.com/no-title
Highlights:
# What is the Model Context Protocol?
"""


def provider(**kw) -> ExaMcpProvider:
    return ExaMcpProvider(**kw)


class TestParsing:
    def test_extracts_all_records(self):
        results = provider()._parse(SAMPLE, limit=10)
        assert len(results) == 2
        assert results[0].title == "Write-Ahead Logging"
        assert results[0].url == "https://www.sqlite.org/wal.html"
        assert results[1].url == "https://example.com/wal-explained"

    def test_published_date_is_truncated_to_iso_day(self):
        results = provider()._parse(SAMPLE, limit=10)
        assert results[0].published_date == "2026-04-13"

    def test_na_published_is_omitted(self):
        results = provider()._parse(SAMPLE, limit=10)
        assert results[1].published_date is None

    def test_highlights_become_text(self):
        results = provider()._parse(SAMPLE, limit=10)
        text = results[0].text
        assert text is not None
        assert "rollback journal" in text
        # The '...' separators Exa emits are noise, not content.
        assert "..." not in text

    def test_no_snippet_is_emitted_alongside_text(self):
        """Exa is a content backend, so it fills `text` and nothing else.

        Measured against the live endpoint, every result used to carry both and
        the snippet was always a prefix of the text -- 8,700 characters of pure
        duplication at max_results=20.
        """
        results = provider()._parse(SAMPLE, limit=10)
        assert results
        for result in results:
            assert result.text is not None
            assert result.snippet is None

    def test_text_is_capped_and_says_so(self):
        results = provider(text_chars=40)._parse(SAMPLE, limit=10)
        text = results[0].text
        assert text is not None
        assert len(text) <= 60  # cap plus ellipsis/sentence slack
        assert results[0].text_truncated is True

    def test_short_text_is_neither_cut_nor_flagged(self):
        results = provider(text_chars=10_000)._parse(SAMPLE, limit=10)
        assert results[1].text == (
            "WAL allows readers and one writer to proceed concurrently."
        )
        # Omitted rather than False: every serialised field costs the caller
        # context, and "nothing was cut" is the uninteresting case.
        assert results[1].text_truncated is None

    def test_the_length_the_cap_discarded_is_recorded(self):
        """`search.cap` reads this: the pre-cap length, log-only and off the wire."""
        hit = provider(text_chars=40)._parse(SAMPLE, limit=10)[0]
        uncapped = hit._uncapped_chars
        assert uncapped is not None
        assert uncapped > len(hit.text or "")
        # Private, so a caller can never see it: the response carries the
        # clipped extract, never a measurement of the clip.
        assert "_uncapped_chars" not in hit.model_dump()

    def test_a_short_extract_reports_its_own_length(self):
        """The denominator: a hit the cap did not bite is still measured."""
        hit = provider(text_chars=10_000)._parse(SAMPLE, limit=10)[1]
        assert hit.text is not None
        assert hit._uncapped_chars == len(hit.text)

    def test_na_title_falls_back_to_the_url(self):
        results = provider()._parse(UNTITLED, limit=10)
        assert len(results) == 1
        assert results[0].title == "https://example.com/no-title"

    def test_na_title_does_not_drop_the_record(self):
        """The URL is a worse title than the page's own, but a true one.

        Dropping the record instead would lose a result Exa actually returned.
        """
        results = provider()._parse(UNTITLED, limit=10)
        assert results[0].text is not None
        assert "Model Context Protocol" in results[0].text

    def test_limit_is_respected(self):
        assert len(provider()._parse(SAMPLE, limit=1)) == 1

    def test_records_without_url_are_skipped(self):
        text = "Title: No URL here\nAuthor: X\nHighlights:\nsomething\n"
        assert provider()._parse(text, limit=5) == []

    def test_empty_input(self):
        assert provider()._parse("", limit=5) == []

    def test_garbage_input_does_not_raise(self):
        assert provider()._parse("total nonsense\nwith no fields", limit=5) == []


class TestCost:
    def test_base_cost_up_to_ten_results(self):
        assert provider().cost_for(10) == 0.007

    def test_extra_results_cost_more(self):
        # ~$1/1k per result beyond the first 10.
        assert provider().cost_for(15) == (7.0 + 5.0) / 1000.0


class TestUnsupportedConstraints:
    def test_a_dropped_filter_is_named(self):
        """Exa's MCP tool takes only query/numResults.

        Nothing filters it out before dispatch, so a caller that passed a filter
        has to be told it did not apply -- unfiltered results the caller knows
        about beat filtered-looking ones it doesn't.
        """
        from seekwright.models import SearchQuery
        from seekwright.providers.base import ignored_constraints

        notice = ignored_constraints(
            SearchQuery(query="q", include_domains=["a.com"], country="de"),
            domains=False,
            dates=False,
            geo=False,
            safety=False,
        )
        assert notice is not None
        assert "domain" in notice and "country/language" in notice

    def test_an_unconstrained_query_gets_no_notice(self):
        from seekwright.models import SearchQuery
        from seekwright.providers.base import ignored_constraints

        q = SearchQuery(query="q")
        assert (
            ignored_constraints(q, domains=False, dates=False, geo=False, safety=False)
            is None
        )

    def test_the_geo_bucket_can_be_reported_half_by_half(self):
        """An adapter that honours one half must not be reported as dropping both.

        Leaving `language` unset keeps the joined `country/language` token,
        which is right for an adapter with no geo surface at all -- it drops
        both halves. Naming them separately is how `searxng` and `tavily` say
        the language rode their own parameter while only the country went.
        """
        from seekwright.models import SearchQuery
        from seekwright.providers.base import ignored_constraints

        q = SearchQuery(query="q", country="de", language="de")
        assert (
            ignored_constraints(
                q, domains=True, dates=True, geo=False, language=True, safety=True
            )
            == "cannot filter by country; that constraint was ignored"
        )
        assert (
            ignored_constraints(
                q, domains=True, dates=True, geo=True, language=False, safety=True
            )
            == "cannot filter by language; that constraint was ignored"
        )
        assert (
            ignored_constraints(q, domains=True, dates=True, geo=False, safety=True)
            == "cannot filter by country/language; that constraint was ignored"
        )

    def test_a_geo_half_that_was_not_requested_is_not_named(self):
        """A half only enters the notice when the caller actually asked for it."""
        from seekwright.models import SearchQuery
        from seekwright.providers.base import ignored_constraints

        language_only = SearchQuery(query="q", language="de")
        assert (
            ignored_constraints(
                language_only, domains=True, dates=True, geo=False, language=True, safety=True
            )
            is None
        )
        country_only = SearchQuery(query="q", country="de")
        assert (
            ignored_constraints(
                country_only, domains=True, dates=True, geo=True, language=False, safety=True
            )
            is None
        )
