"""Provider interface.

A ``Protocol`` rather than an ABC: adapters share no implementation, and
structural typing keeps HTTP adapters and MCP-client adapters symmetric with no
coupling between them.
"""

from __future__ import annotations

from typing import Protocol, runtime_checkable

from ..models import ProviderResult, SearchQuery


class ProviderError(Exception):
    """A provider call failed. Carries enough detail to explain, not to leak."""

    def __init__(self, provider: str, message: str, *, retryable: bool = True) -> None:
        super().__init__(f"{provider}: {message}")
        self.provider = provider
        self.message = message
        self.retryable = retryable


class QuotaExhausted(ProviderError):
    def __init__(self, provider: str, message: str = "quota exhausted") -> None:
        super().__init__(provider, message, retryable=False)


@runtime_checkable
class SearchProvider(Protocol):
    """One upstream search backend."""

    name: str
    cost_per_1k: float

    async def search(self, q: SearchQuery) -> ProviderResult: ...

    async def aclose(self) -> None: ...


def ignored_constraints(
    q: SearchQuery,
    *,
    domains: bool,
    dates: bool,
    geo: bool,
    language: bool | None = None,
    safety: bool,
) -> str | None:
    """Name the constraints in ``q`` that an adapter cannot honour.

    Nothing filters an incapable provider out before dispatch, so saying what
    was dropped is the replacement: a caller told its domain filter was applied
    when it wasn't gets confidently wrong results.

    ``domains``, ``dates``, ``geo`` and ``safety`` are required keywords, so a
    new constraint is a type error at every call site instead of a bucket
    silently defaulting to "honoured".

    ``geo`` and ``language`` are the halves of the geo bucket. Passing
    ``language`` splits it, so ``geo`` speaks for the country half alone and the
    notice names only what really dropped. ``None`` keeps the joined
    ``country/language`` token, right for an adapter with no geo surface at all.

    ``safety`` fires whenever the caller set ``safe_search`` at all: ``False`` is
    a request too, and a backend with no such parameter ignores it as completely
    as it ignores ``True``.
    """
    missing: list[str] = []
    if not domains and (q.include_domains or q.exclude_domains):
        missing.append("domain")
    if not dates and q.recency:
        missing.append("dates")
    if language is None:
        if not geo and (q.country or q.language):
            missing.append("country/language")
    else:
        if not geo and q.country:
            missing.append("country")
        if not language and q.language:
            missing.append("language")
    if not safety and q.safe_search is not None:
        missing.append("safe-search")
    if not missing:
        return None
    return f"cannot filter by {' or '.join(missing)}; that constraint was ignored"


def site_filtered_query(q: SearchQuery) -> str:
    """Fold domain filters into the query string via `site:` operators.

    For the Google-backed providers, which take no domain-filter parameter: the
    operators *are* the interface. A provider with a native filter field uses
    that instead and never calls this.
    """
    parts = [q.query]
    if q.include_domains:
        joined = " OR ".join(f"site:{d}" for d in q.include_domains)
        parts.append(f"({joined})" if len(q.include_domains) > 1 else joined)
    parts.extend(f"-site:{d}" for d in q.exclude_domains)
    return " ".join(parts)


def _clip(text: str, limit: int) -> str:
    """Cut ``text`` to ``limit``, preferring a sentence boundary to mid-word."""
    if len(text) <= limit:
        return text
    window = text[: limit + 1]
    cut = max(window.rfind(". "), window.rfind("! "), window.rfind("? "))
    if cut > limit // 2:
        return window[: cut + 1]
    return text[:limit].rstrip() + "…"


def truncate_snippet(text: str | None, limit: int) -> tuple[str | None, int | None]:
    """Clip a snippet at a sentence boundary where possible.

    A proxy that forwards raw provider bodies is a tax on the caller's context
    window; :func:`truncate_text` bounds the other field a result can carry.

    Returns the clipped snippet *and the normalised length the cap received*.
    The clip happens before anything is recorded, so a recorded response cannot
    tell two cap settings apart; carrying the discarded length out to
    `Result._uncapped_chars` is what makes `policy.max_snippet_chars` measurable
    from real traffic. A ``None`` length means the field was not a string.

    Callers hand this the value straight out of an upstream payload, where the
    field is documented as a string and nothing enforces it, so shape drift is
    dropped rather than raised: an ``AttributeError`` from ``text.split()`` is
    not a ``ProviderError`` and would surface as an internal error.
    """
    if not isinstance(text, str):
        return None, None
    normalised = " ".join(text.split())
    return _clip(normalised, limit), len(normalised)


def truncate_text(
    text: str | None, limit: int
) -> tuple[str | None, bool, int | None]:
    """Clip inline page text, reporting whether anything was cut.

    The flag is the point: an extract that stops early is indistinguishable from
    a page that was simply short, and a caller that cannot tell them apart cannot
    judge whether `fetch` would give it anything more.

    The third element is :func:`truncate_snippet`'s second: the normalised length
    the cap received, which makes `policy.max_result_text_chars` measurable from
    what a deployment already records. A non-string drops for the same reason,
    and nothing was cut, so the flag is ``False``.
    """
    if not isinstance(text, str):
        return None, False, None
    normalised = " ".join(text.split())
    if not normalised:
        return None, False, None
    clipped = _clip(normalised, limit)
    return clipped, clipped != normalised, len(normalised)
