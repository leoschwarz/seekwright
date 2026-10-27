"""Core data models shared by providers, engine and the tool surface."""

from __future__ import annotations

from typing import Annotated, Any, Literal

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    PrivateAttr,
    SerializerFunctionWrapHandler,
    model_serializer,
)

from .sanitize import TEXT_FIELDS, sanitize_text


class WireModel(BaseModel):
    """Base for the shapes that cross into a caller's context window.

    Both rules live on the model because they are about the *boundary*, not about
    any one response. Absent fields are dropped rather than serialised as null
    (`"score": null` on twenty results is a hundred tokens saying nothing);
    pydantic has no config flag for it -- ``exclude_none`` is an argument to
    ``model_dump``, and it is FastMCP that calls it.

    The ``sanitize.TEXT_FIELDS`` fields are escaped so no tokenizer mistakes them
    for structure. FastMCP serialises the tool result and the REST routes dump
    these same models, so this is the single choke point where the guarantee
    holds by construction; the engines escape the response object first, where
    the hit count reaches the decision line.
    """

    model_config = ConfigDict(extra="forbid")

    @model_serializer(mode="wrap")
    def _drop_absent(self, handler: SerializerFunctionWrapHandler) -> dict[str, Any]:
        dumped = {k: v for k, v in handler(self).items() if v is not None}
        for key in TEXT_FIELDS:
            value = dumped.get(key)
            if isinstance(value, str):
                dumped[key] = sanitize_text(value)[0]
        return dumped


class SearchQuery(BaseModel):
    """A normalised search request, as it reaches a provider adapter.

    Domain, country, language, recency and safe-search are requests, not
    guarantees: an adapter that cannot honour one says so in
    ``ProviderResult.notice`` (``providers.base.ignored_constraints``).
    """

    query: str
    max_results: int = 5
    include_domains: list[str] = Field(default_factory=list)
    exclude_domains: list[str] = Field(default_factory=list)
    country: str | None = None
    # Two letters exactly: the region half is `country`'s job, so `de-DE` is refused
    # rather than narrowed invisibly.
    language: str | None = None
    # Each adapter maps it to its native shape; one with no date filter reports the gap in `notice`.
    recency: Literal["day", "week", "month", "year"] | None = None
    # `True` filters at the strongest level, `False` asks it not to, `None` sends nothing:
    # *unknown*, not *unfiltered* -- a `False` default sends an off-state no caller asked for.
    safe_search: bool | None = None


class Result(WireModel):
    """One search hit.

    Which fields are populated depends on the provider: a SERP backend fills
    ``snippet``, a content backend ``text``, an answer backend cites its sources
    here beside :attr:`SearchResponse.answer`.
    """

    title: str
    url: str
    snippet: str | None = None
    text: str | None = None
    # `bool | None`, not `bool = False`: a false would survive the absent-field rule
    # and serialise on every result of every provider.
    text_truncated: bool | None = None
    published_date: str | None = None
    score: float | None = None

    # Log-only: the length the policy cap clipped *from* (`engine._log_caps`), and private
    # so a measurement of discarded content never reaches the wire.
    _uncapped_chars: int | None = PrivateAttr(default=None)


class SearchResponse(WireModel):
    """The shape returned by the ``search`` tool."""

    query: str
    provider: str
    results: list[Result]
    answer: str | None = None
    retrieved_at: str | None = None
    notice: str | None = None


class FetchMatch(WireModel):
    """One contiguous matching span of a fetched page, located for re-fetch.

    ``offset`` indexes the page's *full* extracted text, so fetching again with
    it set expands the passage in place: the extraction is the only coordinate
    system both sides share.
    """

    offset: int
    text: str


class FetchImage(WireModel):
    """One image resource, carried to the caller as bytes instead of as text.

    The media type is the parent response\'s ``content_type`` -- one name for that
    fact -- and it is the type the bytes were checked against, not the type a
    server claimed. ``byte_count`` is the decoded size.

    Over MCP the same bytes arrive as an image content block, so this field is
    left out of the JSON projection and no picture reaches the context twice.
    """

    byte_count: int
    # The base64 alphabet holds no `<` and no `|`, so an image body cannot spell a
    # special-token delimiter and needs no escape pass; one would corrupt the bytes.
    base64: str


class FetchResponse(WireModel):
    """The shape returned by the ``fetch`` tool: one page, plus provenance.

    Deliberately not a :class:`SearchResponse`: ``query`` and ``results`` are
    each either meaningless or misleading for a single-URL fetch.

    The text carried here is untrusted third-party content; nothing in this proxy
    can make it safe to follow as instructions, and the tool description says so
    to the model too.

    ``text`` and ``matches`` are alternatives, never both -- the rule
    ``Result.snippet`` / ``Result.text`` follows. A query-targeted fetch leaves
    ``text`` unset, so a page is never shipped twice.
    """

    # Both URLs are reported because they differ after a redirect: `url` is where the fetch landed.
    url: str
    requested_url: str
    title: str | None = None
    # Absent when `matches` carries the content.
    text: str | None = None
    content_type: str | None = None
    status_code: int | None = None
    retrieved_at: str | None = None
    truncated: bool = False
    total_chars: int | None = None
    # Echoed only when non-zero, the paging caller's bookmark; the `Result.text_truncated` rule.
    offset: int | None = None
    matches: list[FetchMatch] | None = None
    # Set only when the resource is an image and `fetch.allow_images` is on; `text` and
    # `matches` stay unset alongside it, since there is no extraction to carry.
    image: FetchImage | None = None
    notice: str | None = None


class SearchRequest(WireModel):
    """The ``search`` tool's parameter set, as the REST body spells it.

    One field per tool parameter and nothing else: ``SearchQuery.country`` is
    off it, so the two encodings cannot drift apart. The constraints are the
    tool schema's, restated because a body arrives without FastMCP's validation.

    ``provider`` is a plain string rather than the schema's ``Literal`` of
    seventeen names: which of them a deployment serves is a config fact, so a
    name outside the enabled set must reach :meth:`SearchEngine.resolve` for the
    message a caller can recover from.

    ``mode`` is the tool's own type, `Literal["free"]`, because it is an enum the
    schema fixes; a parameter the tool gains is projected here too, so a REST
    caller gets the same cost ceiling an MCP caller does.
    """

    query: str = Field(min_length=2, max_length=400)
    provider: str | None = None
    mode: Literal["free"] | None = None
    max_results: int = Field(5, ge=1, le=20)
    include_domains: list[str] | None = Field(None, max_length=20)
    exclude_domains: list[str] | None = Field(None, max_length=20)
    recency: Literal["day", "week", "month", "year"] | None = None
    # The tool's own bounds, restated: two letters exactly, so a regional tag is
    # refused here rather than narrowed on the way to an adapter.
    language: str | None = Field(None, min_length=2, max_length=2)
    safe_search: bool | None = None


class FetchRequest(WireModel):
    """The ``fetch`` tool's parameter set, as the REST body spells it.

    ``url`` is checked for length here, and for scheme, credentials and address
    by the fetcher's guardrails -- which is why a URL refused as written is a
    400 rather than a 502.

    ``path``'s floor is one because ``$`` alone is a complete request, and the
    grammar is not validated here: `jsondoc.parse_path` owns the one reading.

    ``provider`` is a plain string for the reason it is one on
    :class:`SearchRequest`; a name this deployment never built reaches
    :meth:`FetchEngine.resolve` for the sentence naming the names it did.
    Omitting it *is* the local read.
    """

    url: str = Field(min_length=8, max_length=2048)
    offset: int | None = Field(None, ge=0)
    query: str | None = Field(None, min_length=2, max_length=400)
    path: str | None = Field(None, min_length=1, max_length=400)
    provider: str | None = None


class AnswerRequest(WireModel):
    """The ``answer`` tool's parameter set, as the REST body spells it.

    One field per tool parameter and nothing else, as :class:`SearchRequest`:
    ``max_results`` and the system prompt are absent because the tool does not
    take them.

    ``depth`` is ``Literal`` and ``None`` is a real value: the plan applies the
    tool's default, so a body that omits it and one that sends ``"brief"`` mean
    the same thing. ``extra_queries`` carries the tool's item bounds as well as
    its count, so a one-character fragment cannot become a billed retrieval step.
    """

    query: str = Field(min_length=2, max_length=400)
    extra_queries: list[Annotated[str, Field(min_length=2, max_length=400)]] | None = (
        Field(None, max_length=2)
    )
    depth: Literal["brief", "report"] | None = None
    provider: str | None = None
    include_domains: list[str] | None = Field(None, max_length=20)
    exclude_domains: list[str] | None = Field(None, max_length=20)
    recency: Literal["day", "week", "month", "year"] | None = None
    # The same bounds as `SearchRequest`'s: a filter settable on one tool and not the
    # other is the trap the notice mechanism exists to prevent.
    language: str | None = Field(None, min_length=2, max_length=2)
    safe_search: bool | None = None


class AnswerSource(WireModel):
    """One result the prose actually cited.

    Built by the server from what it retrieved, never from what the model
    claimed: a URL the model invented has no material item behind it and so
    cannot reach this list. ``provider`` is the backend that supplied the
    result, which makes the list a ranking signal as well as a citation.
    """

    title: str
    url: str
    provider: str


class AnswerResponse(WireModel):
    """The shape returned by the ``answer`` tool.

    Deliberately not a :class:`SearchResponse`: the caller gets prose and the
    sources behind it, and the retrieval counts explain its grounding.

    No ``cost_usd``, no prompt, no material and no token counts: the caller is
    not the party paying, and the material is not the caller's to inspect --
    which is why the prose must be read against ``sources``.
    """

    query: str
    answer: str
    sources: list[AnswerSource]
    model: str
    depth: Literal["brief", "report"]
    # The two counts the caller can check the retrieval plan against.
    searches: int
    fetched: int
    retrieved_at: str | None = None
    # `bool | None`, not `bool = False`, so a complete answer does not serialise a
    # false -- the `Result.text_truncated` rule.
    truncated: bool | None = None
    notice: str | None = None


class ProviderResult(BaseModel):
    """What a provider adapter returns, before response metadata is added."""

    provider: str
    results: list[Result]
    answer: str | None = None
    cost_usd: float | None = None
    notice: str | None = None

    # Log-only: the usage an upstream reported for this call at the adapter's
    # ``cost_per_1k``; private, the same reason ``cost_usd`` stays off ``SearchResponse``.
    _reported_cost_usd: float | None = PrivateAttr(default=None)
