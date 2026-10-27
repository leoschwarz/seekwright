"""Wire shapes: what a caller actually receives.

These models are mostly field lists, so the only behaviour worth a test is the
rule that is not visible from reading them -- an unset field does not reach the
caller as a null. It is enforced by a serialiser rather than a config flag
(``exclude_none`` is an argument to ``model_dump``, and FastMCP is what calls
it), which makes it exactly the kind of thing that regresses silently.

``TestSearchQuery`` is the other kind of field-list test: the constraint set is
a contract every adapter is written against, so a rename or an added field has
to fail here rather than only in whichever adapter forgot it.
"""

import base64

import pytest

from seekwright.models import (
    FetchImage,
    FetchMatch,
    FetchRequest,
    FetchResponse,
    Result,
    SearchQuery,
    SearchResponse,
)
from seekwright.sanitize import ZWSP


class TestFetchImage:
    """The one response field that carries bytes rather than text."""

    def test_a_body_that_would_need_escaping_is_left_whole(self):
        """The base64 alphabet has no `<` and no `|`, so no delimiter can be spelled.

        The escape pass every other caller-readable field goes through would
        corrupt the bytes, so `image.base64` stays out of it -- asserted against
        a body whose decoded form *is* a special-token literal.
        """
        encoded = base64.b64encode(b"<|endoftext|>").decode("ascii")
        response = FetchResponse(
            url="https://e.com/a.png",
            requested_url="https://e.com/a.png",
            content_type="image/png",
            image=FetchImage(byte_count=13, base64=encoded),
        )
        dumped = response.model_dump(mode="json")
        assert dumped["image"] == {"byte_count": 13, "base64": encoded}
        assert ZWSP not in dumped["image"]["base64"]

    def test_the_image_carries_no_media_type_of_its_own(self):
        """`content_type` names the type once; a second name for it could disagree."""
        assert set(FetchImage.model_fields) == {"byte_count", "base64"}


class TestAbsentFieldsAreDropped:
    def test_a_result_omits_what_it_has_no_value_for(self):
        dumped = Result(title="t", url="https://e.com", text="x").model_dump()
        assert dumped == {"title": "t", "url": "https://e.com", "text": "x"}

    def test_a_set_field_survives(self):
        dumped = Result(
            title="t", url="https://e.com", text="x", text_truncated=True
        ).model_dump()
        assert dumped["text_truncated"] is True

    def test_false_is_not_absent(self):
        """Only ``None`` means absent. A real `false` still has to be reported --
        `truncated: false` is the fetcher saying the page fit."""
        dumped = FetchResponse(
            url="https://e.com", requested_url="https://e.com", text="t"
        ).model_dump()
        assert dumped["truncated"] is False

    def test_a_plain_fetch_serialises_exactly_as_it_did(self):
        """`text`, not `matches`, and no zero `offset` key."""
        dumped = FetchResponse(
            url="https://e.com", requested_url="https://e.com", text="t"
        ).model_dump()
        assert "offset" not in dumped
        assert "matches" not in dumped

    def test_an_image_is_absent_until_there_is_one(self):
        """The `image` field is invisible until a caller is handed bytes."""
        dumped = FetchResponse(
            url="https://e.com", requested_url="https://e.com", text="t"
        ).model_dump()
        assert "image" not in dumped

    def test_matches_carry_the_content_without_text(self):
        """Same never-both rule as `Result.snippet` / `Result.text`."""
        dumped = FetchResponse(
            url="https://e.com",
            requested_url="https://e.com",
            matches=[FetchMatch(offset=300, text="the matching passage")],
            total_chars=40_000,
        ).model_dump()
        assert "text" not in dumped
        assert dumped["matches"] == [
            {"offset": 300, "text": "the matching passage"}
        ]

    def test_a_non_zero_offset_is_echoed(self):
        dumped = FetchResponse(
            url="https://e.com", requested_url="https://e.com", text="t", offset=40_000
        ).model_dump()
        assert dumped["offset"] == 40_000

    def test_the_rule_reaches_nested_results(self):
        response = SearchResponse(
            query="q",
            provider="exa",
            results=[Result(title="t", url="https://e.com")],
        )
        dumped = response.model_dump()
        assert "answer" not in dumped
        assert dumped["results"] == [{"title": "t", "url": "https://e.com"}]


class TestSearchQuery:
    """The constraint set every adapter is written against.

    Not a wire shape -- nothing serialises it -- but the field list is the
    contract, and the two newest members are the ones a silent change would cost
    the most: `language` replaced `locale` outright (there is deliberately no
    second field, and no region half), and `safe_search` is a tri-state where
    the third state is a behaviour, not an absence.
    """

    def test_the_constraint_set_is_exactly_these_eight_fields(self):
        assert set(SearchQuery.model_fields) == {
            "query",
            "max_results",
            "include_domains",
            "exclude_domains",
            "country",
            "language",
            "recency",
            "safe_search",
        }

    def test_locale_is_gone_rather_than_kept_beside_language(self):
        """Two fields for one wire parameter in five adapters, and a rule for
        which one wins, is the shape this rename exists to avoid."""
        assert "locale" not in SearchQuery.model_fields
        assert not hasattr(SearchQuery(query="q"), "locale")

    def test_language_defaults_to_none(self):
        assert SearchQuery(query="q").language is None

    @pytest.mark.parametrize("value", [True, False, None])
    def test_safe_search_carries_all_three_states(self, value):
        """`None` is a real state, not a synonym for `False`.

        `None` means "send nothing", so the provider's own default stands --
        unknown, never unfiltered. A `bool = False` default would have made
        every adapter send an explicit off-state no caller asked for.
        """
        assert SearchQuery(query="q", safe_search=value).safe_search is value

    def test_safe_search_defaults_to_none_not_false(self):
        assert SearchQuery(query="q").safe_search is None

class TestFetchRequestProvider:
    """``FetchRequest.provider``, the fifth `fetch` parameter.

    A plain string rather than a ``Literal`` of the fetch registry, because
    which names a deployment builds is config, a key and a permission set --
    so the model cannot enumerate them.
    """

    def test_a_name_the_tree_has_never_heard_of_survives_the_body(self):
        """The body cannot know the set, so it does not try to police it.

        A ``Literal`` would answer such a name with a schema error instead of
        handing it to ``FetchEngine.resolve``, which is where the caller learns
        the names this server *does* run.
        """
        request = FetchRequest.model_validate(
            {"url": "https://e.com/a", "provider": "scraper"}
        )
        assert request.provider == "scraper"

    def test_the_field_is_a_string_and_not_a_vocabulary(self):
        assert FetchRequest.model_fields["provider"].annotation == str | None

    def test_an_omitted_provider_stays_out_of_the_body(self):
        """No name *is* the local read; there is no name for the local fetcher."""
        body = FetchRequest.model_validate({"url": "https://e.com/a"})
        assert "provider" not in body.model_dump()
        assert body.provider is None
