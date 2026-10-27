"""Tavily -- a keyed content backend: SERP ranking plus pre-cleaned page text.

Free tier is 1,000 credits a month, then $0.008/credit; a basic search is one
credit per request whatever the result count. So ``cost_per_1k`` is 8.00 and
``cost_for`` is flat, unlike Serper's >10-results doubling.

`search_depth` is fixed at ``basic``: ``advanced`` doubles the credit, so it is
deployment policy, not a caller choice. ``content`` is pre-cleaned page text, so
the cap that matters is ``policy.max_result_text_chars``, not the snippet one.
"""

from __future__ import annotations

from typing import Any

import httpx

from ..models import ProviderResult, Result, SearchQuery
from .base import (
    ProviderError,
    QuotaExhausted,
    ignored_constraints,
    truncate_text,
)

ENDPOINT = "https://api.tavily.com/search"

# Tavily's `country` is a closed enum of lowercase English country names, valid only
# on the `general` topic this adapter uses; codes map onto them below.
_COUNTRY_BY_CODE: dict[str, str] = {
    "af": "afghanistan", "al": "albania", "dz": "algeria", "ad": "andorra",
    "ao": "angola", "ar": "argentina", "am": "armenia", "au": "australia",
    "at": "austria", "az": "azerbaijan", "bs": "bahamas", "bh": "bahrain",
    "bd": "bangladesh", "bb": "barbados", "by": "belarus", "be": "belgium",
    "bz": "belize", "bj": "benin", "bt": "bhutan", "bo": "bolivia",
    "ba": "bosnia and herzegovina", "bw": "botswana", "br": "brazil",
    "bn": "brunei", "bg": "bulgaria", "bf": "burkina faso", "bi": "burundi",
    "kh": "cambodia", "cm": "cameroon", "ca": "canada", "cv": "cape verde",
    "cf": "central african republic", "td": "chad", "cl": "chile",
    "cn": "china", "co": "colombia", "km": "comoros", "cg": "congo",
    "cd": "congo", "cr": "costa rica", "hr": "croatia", "cu": "cuba",
    "cy": "cyprus", "cz": "czech republic", "dk": "denmark",
    "dj": "djibouti", "do": "dominican republic", "ec": "ecuador",
    "eg": "egypt", "sv": "el salvador", "gq": "equatorial guinea",
    "er": "eritrea", "ee": "estonia", "et": "ethiopia", "fj": "fiji",
    "fi": "finland", "fr": "france", "ga": "gabon", "gm": "gambia",
    "ge": "georgia", "de": "germany", "gh": "ghana", "gr": "greece",
    "gt": "guatemala", "gn": "guinea", "ht": "haiti", "hn": "honduras",
    "hu": "hungary", "is": "iceland", "in": "india", "id": "indonesia",
    "ir": "iran", "iq": "iraq", "ie": "ireland", "il": "israel",
    "it": "italy", "jm": "jamaica", "jp": "japan", "jo": "jordan",
    "kz": "kazakhstan", "ke": "kenya", "kw": "kuwait", "kg": "kyrgyzstan",
    "lv": "latvia", "lb": "lebanon", "ls": "lesotho", "lr": "liberia",
    "ly": "libya", "li": "liechtenstein", "lt": "lithuania",
    "lu": "luxembourg", "mg": "madagascar", "mw": "malawi",
    "my": "malaysia", "mv": "maldives", "ml": "mali", "mt": "malta",
    "mr": "mauritania", "mu": "mauritius", "mx": "mexico", "md": "moldova",
    "mc": "monaco", "mn": "mongolia", "me": "montenegro", "ma": "morocco",
    "mz": "mozambique", "mm": "myanmar", "na": "namibia", "np": "nepal",
    "nl": "netherlands", "nz": "new zealand", "ni": "nicaragua",
    "ne": "niger", "ng": "nigeria", "kp": "north korea",
    "mk": "north macedonia", "no": "norway", "om": "oman", "pk": "pakistan",
    "pa": "panama", "pg": "papua new guinea", "py": "paraguay",
    "pe": "peru", "ph": "philippines", "pl": "poland", "pt": "portugal",
    "qa": "qatar", "ro": "romania", "ru": "russia", "rw": "rwanda",
    "sa": "saudi arabia", "sn": "senegal", "rs": "serbia",
    "sg": "singapore", "sk": "slovakia", "si": "slovenia",
    "so": "somalia", "za": "south africa", "kr": "south korea",
    "ss": "south sudan", "es": "spain", "lk": "sri lanka", "sd": "sudan",
    "se": "sweden", "ch": "switzerland", "sy": "syria", "tw": "taiwan",
    "tj": "tajikistan", "tz": "tanzania", "th": "thailand", "tg": "togo",
    "tt": "trinidad and tobago", "tn": "tunisia", "tr": "turkey",
    "tm": "turkmenistan", "ug": "uganda", "ua": "ukraine",
    "ae": "united arab emirates", "gb": "united kingdom",
    "us": "united states", "uy": "uruguay", "uz": "uzbekistan",
    "ve": "venezuela", "vn": "vietnam", "ye": "yemen", "zm": "zambia",
    "zw": "zimbabwe",
}
# Common aliases Tavily's enum does not list but callers write.
_COUNTRY_BY_CODE.update({"uk": "united kingdom", "usa": "united states"})
_COUNTRY_NAMES = frozenset(_COUNTRY_BY_CODE.values())


def _country_param(value: str) -> str | None:
    """Map a caller's country onto Tavily's closed enum, or ``None``.

    Names go through lowercased, codes through the table. The two Congo codes
    share one enum entry; which of them a boost resolves to is upstream's
    semantics.
    """
    lowered = value.strip().lower()
    if lowered in _COUNTRY_NAMES:
        return lowered
    return _COUNTRY_BY_CODE.get(lowered)


class TavilyProvider:
    name = "tavily"
    # Class level too, not just `__init__`: the protocol is structural (provider-contract.md).
    cost_per_1k: float

    def __init__(
        self,
        client: httpx.AsyncClient,
        api_key: str,
        *,
        cost_per_1k: float = 8.00,
        text_chars: int = 2000,
        timeout: float = 10.0,
    ) -> None:
        self._client = client
        self._api_key = api_key
        self.cost_per_1k = cost_per_1k
        # No snippet_chars: a content backend fills `text` and nothing else.
        self._text_chars = text_chars
        self._timeout = timeout

    def cost_for(self, _max_results: int) -> float:
        """Per-query cost in USD. Flat: basic search is one credit per request.

        The argument is ignored rather than absent because callers treat
        ``cost_for`` as duck-typed; another provider scales with it.
        """
        return self.cost_per_1k / 1000.0

    async def search(self, q: SearchQuery) -> ProviderResult:
        # The query goes verbatim: Tavily has native domain fields, so no `site:` folding.
        body: dict[str, Any] = {
            "query": q.query,
            "search_depth": "basic",
            "max_results": q.max_results,
            "include_answer": "basic",
            "include_raw_content": False,
            # Reported usage, not an estimate: the response's `usage.credits` comes back as
            # `_reported_cost_usd` on `search.ok` for the cost-drift check to diff.
            "include_usage": True,
        }
        if q.recency:
            body["time_range"] = q.recency
        if q.include_domains:
            body["include_domains"] = q.include_domains
        if q.exclude_domains:
            body["exclude_domains"] = q.exclude_domains

        # `country`, `language` and `safe_search` are ranking knobs upstream, not hard
        # filters.
        country = _country_param(q.country) if q.country else None
        if country is not None:
            body["country"] = country
        if q.language:
            body["language"] = q.language.lower()
        if q.safe_search is not None:
            # Sent only when asked: `None` leaves Tavily's default standing, not "off".
            body["safe_search"] = q.safe_search

        try:
            resp = await self._client.post(
                ENDPOINT,
                json=body,
                headers={
                    "Authorization": f"Bearer {self._api_key}",
                    "Content-Type": "application/json",
                },
                timeout=self._timeout,
            )
        except httpx.TimeoutException as exc:
            raise ProviderError(self.name, "request timed out") from exc
        except httpx.HTTPError as exc:
            # Redaction rule: docs/reference/provider-contract.md, "Failures".
            raise ProviderError(self.name, "network error") from exc

        if resp.status_code in (401, 403):
            raise ProviderError(
                self.name, "authentication rejected (check API key)", retryable=False
            )
        # 432 is Tavily's monthly-credits-exhausted code; 429 is short-term rate limiting.
        if resp.status_code in (429, 432):
            raise QuotaExhausted(self.name, "rate limited or out of credits")
        if resp.status_code >= 400:
            raise ProviderError(self.name, f"HTTP {resp.status_code}")

        try:
            data = resp.json()
        except ValueError as exc:
            raise ProviderError(self.name, "malformed JSON response") from exc
        if not isinstance(data, dict):
            # Non-object JSON is the same contracted error as unparseable:
            # provider-contract.md, "Failures".
            raise ProviderError(self.name, "malformed JSON response")

        raw_answer = data.get("answer")
        result = ProviderResult(
            provider=self.name,
            results=self._parse(data, q.max_results),
            answer=raw_answer if isinstance(raw_answer, str) else None,
            cost_usd=self.cost_for(q.max_results),
            # Native domains, `time_range`, `country`, `language` and `safe_search` are
            # honoured; a country outside the enum is dropped, so it alone is noticed.
            notice=ignored_constraints(
                q,
                domains=True,
                dates=True,
                geo=country is not None,
                language=True,
                safety=True,
            ),
        )
        usage = data.get("usage")
        if isinstance(usage, dict):
            credits = usage.get("credits")
            if isinstance(credits, int | float) and not isinstance(credits, bool):
                result._reported_cost_usd = credits * self.cost_per_1k / 1000.0
        return result

    def _parse(self, data: dict[str, Any], limit: int) -> list[Result]:
        """``results[]``: {title, url, content, score, published_date}."""
        out: list[Result] = []
        for item in (data.get("results") or [])[:limit]:
            if not isinstance(item, dict):
                continue
            url = item.get("url")
            title = item.get("title")
            if not url or not title:
                continue
            text, truncated, uncapped = truncate_text(item.get("content"), self._text_chars)
            published = item.get("published_date")
            score = item.get("score")
            result = Result(
                title=str(title),
                url=str(url),
                text=text,
                text_truncated=truncated or None,
                published_date=published if isinstance(published, str) else None,
                score=float(score) if isinstance(score, int | float) else None,
            )
            # Log-only, and private so it cannot reach the wire (`search.cap`).
            result._uncapped_chars = uncapped
            out.append(result)
        return out

    async def aclose(self) -> None:
        # The lifespan owns the shared client (docs/reference/provider-contract.md).
        return None
