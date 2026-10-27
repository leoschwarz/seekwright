"""``providers/base.py``: the shared clip helpers and their guard on field shape.

Both helpers take a value straight out of an upstream payload -- every adapter
calls them with ``item.get(...)`` -- where the field is documented as a string
and nothing enforces it. A nested object, list or number used to reach
``" ".join(text.split())`` and raise ``AttributeError``; that is not a
``ProviderError``, so it escaped the engine's provider-error handling and
surfaced as an internal error instead of a field the adapter dropped. The
helpers now drop a non-string themselves, which is the same
``isinstance(value, str)`` rule the adapters apply to their own fields, kept in
the one place all of them call.

The per-adapter tests (``tests/providers/test_serper.py``, ``tests/providers/test_linkup.py``, ``tests/providers/test_tavily.py``,
``tests/providers/test_searxng.py``, ``tests/providers/test_tinyfish.py``, ``tests/providers/test_scrappa.py``,
``tests/providers/test_algolia.py``) drive the same guard through ``search()``; these pin it at
the boundary itself, plus the shapes JSON cannot carry.

``TestIgnoredConstraints`` covers the other shared helper, and it lives here
rather than in an adapter's module because the token grammar is shared: the
per-adapter tests assert what *their* adapter reports, and these assert the
sentences it reports it with.
"""

import pytest

from seekwright.models import SearchQuery
from seekwright.providers.base import (
    ignored_constraints,
    truncate_snippet,
    truncate_text,
)

BAD_SHAPES = [{"nested": "object"}, ["a", "b"], 7, 0.5, True, b"bytes"]


class TestTruncateSnippet:
    def test_a_well_formed_string_is_whitespace_normalised(self):
        snippet, uncapped = truncate_snippet("a  b\n c", 40)
        assert snippet == "a b c"
        # The length is the normalised one the cap received, not the raw field's.
        assert uncapped == len("a b c")

    def test_a_long_string_is_clipped_at_a_sentence_boundary(self):
        snippet, uncapped = truncate_snippet(
            "One sentence here. A second sentence follows it.", 24
        )
        assert snippet == "One sentence here."
        assert uncapped == len("One sentence here. A second sentence follows it.")

    def test_the_length_is_what_the_cap_received(self):
        """`uncapped - len(clipped)` is the figure `search.cap` exists to carry."""
        snippet, uncapped = truncate_snippet("x" * 900, 500)
        assert uncapped == 900
        assert snippet is not None and len(snippet) < uncapped

    def test_none_stays_none(self):
        assert truncate_snippet(None, 40) == (None, None)

    def test_an_empty_string_stays_empty(self):
        """Not ``None``: the helpers never invented a value for a present one."""
        assert truncate_snippet("", 40) == ("", 0)

    @pytest.mark.parametrize("bad", BAD_SHAPES)
    def test_a_non_string_is_dropped_rather_than_raised(self, bad):
        # `None` for the length as well: the field never reached a clip, so
        # there is no discarded length to report.
        assert truncate_snippet(bad, 40) == (None, None)


class TestTruncateText:
    def test_a_well_formed_string_is_normalised_and_reports_no_cut(self):
        assert truncate_text("a  b\n c", 40) == ("a b c", False, 5)

    def test_a_long_string_is_clipped_and_reports_the_cut(self):
        text, truncated, uncapped = truncate_text(
            "One sentence here. A second sentence follows it.", 24
        )
        assert (text, truncated) == ("One sentence here.", True)
        assert uncapped == len("One sentence here. A second sentence follows it.")

    def test_the_length_is_what_the_cap_received(self):
        """The other half of the same measurement, for the extract cap."""
        text, truncated, uncapped = truncate_text("y" * 900, 500)
        assert truncated is True
        assert uncapped == 900
        assert text is not None and len(text) < uncapped

    def test_none_stays_none(self):
        assert truncate_text(None, 40) == (None, False, None)

    def test_a_blank_string_is_none_and_uncut(self):
        assert truncate_text("   ", 40) == (None, False, None)

    @pytest.mark.parametrize("bad", BAD_SHAPES)
    def test_a_non_string_is_dropped_and_reported_as_uncut(self, bad):
        assert truncate_text(bad, 40) == (None, False, None)


class TestIgnoredConstraints:
    """The token grammar every adapter's notice is built from.

    ``domains``/``dates``/``geo``/``safety`` are required keywords so the type
    checker flags a call site that has not answered the new bucket; ``language``
    is the one that defaults, and the default is load-bearing (below).
    """

    def test_an_unconstrained_query_gets_no_notice(self):
        q = SearchQuery(query="q")
        assert ignored_constraints(q, domains=False, dates=False, geo=False, safety=False) is None

    def test_every_dropped_bucket_is_named_in_one_sentence(self):
        q = SearchQuery(
            query="q",
            include_domains=["a.com"],
            recency="day",
            country="de",
            language="de",
            safe_search=True,
        )
        assert ignored_constraints(
            q, domains=False, dates=False, geo=False, language=False, safety=False
        ) == (
            "cannot filter by domain or dates or country or language or "
            "safe-search; that constraint was ignored"
        )

    def test_safe_search_alone_is_named(self):
        q = SearchQuery(query="q", safe_search=True)
        assert ignored_constraints(
            q, domains=True, dates=True, geo=True, safety=False
        ) == "cannot filter by safe-search; that constraint was ignored"

    def test_safe_search_false_is_a_constraint_too(self):
        """`False` is a request, not an absence.

        The caller asked the backend *not* to filter, which is a constraint like
        any other; an adapter with no such parameter ignored it just as
        completely as it ignores `True`, and saying nothing would leave the
        caller believing the backend is off.
        """
        q = SearchQuery(query="q", safe_search=False)
        assert ignored_constraints(
            q, domains=True, dates=True, geo=True, safety=False
        ) == "cannot filter by safe-search; that constraint was ignored"

    def test_safe_search_none_is_not_a_constraint(self):
        """The third state: nothing was asked, so nothing was dropped.

        `None` means the provider's own default stands, so an adapter with no
        parameter has not overridden anything and must not gain a notice -- this
        is the "no behavioural change when neither parameter is passed" rule.
        """
        assert (
            ignored_constraints(
                SearchQuery(query="q"), domains=True, dates=True, geo=True, safety=False
            )
            is None
        )

    def test_a_honoured_safe_search_is_not_named(self):
        q = SearchQuery(query="q", safe_search=True)
        assert ignored_constraints(q, domains=True, dates=True, geo=True, safety=True) is None

    def test_safe_search_joins_the_other_drops(self):
        q = SearchQuery(query="q", recency="week", safe_search=True)
        assert ignored_constraints(
            q, domains=True, dates=False, geo=True, safety=False
        ) == "cannot filter by dates or safe-search; that constraint was ignored"

    def test_the_geo_bucket_can_be_reported_half_by_half(self):
        """An adapter that honours one half must not be reported as dropping both.

        Leaving `language` unset keeps the joined `country/language` token,
        which is right for an adapter with no geo surface at all -- it drops
        both halves. Naming them separately is how `searxng` and `tavily` say
        the language rode their own parameter while only the country went.
        """
        q = SearchQuery(query="q", country="de", language="de")
        assert (
            ignored_constraints(q, domains=True, dates=True, geo=False, language=True, safety=True)
            == "cannot filter by country; that constraint was ignored"
        )
        assert (
            ignored_constraints(q, domains=True, dates=True, geo=True, language=False, safety=True)
            == "cannot filter by language; that constraint was ignored"
        )
        assert (
            ignored_constraints(q, domains=True, dates=True, geo=False, safety=True)
            == "cannot filter by country/language; that constraint was ignored"
        )

    def test_a_geo_half_that_was_not_requested_is_not_named(self):
        """A half only enters the notice when the caller actually asked for it."""
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

    def test_an_unset_language_keeps_the_joined_token(self):
        """The default is what an adapter with no geo surface at all relies on."""
        q = SearchQuery(query="q", language="de")
        assert ignored_constraints(
            q, domains=True, dates=True, geo=False, safety=True
        ) == "cannot filter by country/language; that constraint was ignored"
