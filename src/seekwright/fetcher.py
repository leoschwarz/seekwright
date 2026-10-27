"""Fetching a URL safely.

The URLs reaching this module are chosen by a language model, from text written
by whoever controls the page it last read. Every guardrail here assumes the URL
is hostile input, and the module owns its own HTTP client rather than borrowing
the shared one: that client follows redirects and carries provider API keys, and
neither is acceptable here.

Deliberately not a :class:`~.providers.base.SearchProvider`: that protocol takes
a query and reports a per-thousand cost, and a URL fetch has neither.
"""

from __future__ import annotations

import asyncio
import ipaddress
import socket
from collections.abc import Callable
from dataclasses import dataclass
from typing import TYPE_CHECKING, Protocol
from urllib.parse import urlsplit, urlunsplit

import httpx

from . import DEFAULT_USER_AGENT
from .extractors.base import (
    PDF_TYPES,
    ExtractionFailed,
    Extractor,
    describe_types,
    is_supported,
    media_type,
)
from .jsondoc import is_json_document_media
from .providers.base import ProviderError, QuotaExhausted

if TYPE_CHECKING:
    # `config.py` reads :data:`KNOWN_FALLBACKS` out of this module, so `Config` cannot be imported here at runtime.
    from .config import Config

ALLOWED_SCHEMES = frozenset({"http", "https"})

IMAGE_TYPES = frozenset({"image/png", "image/jpeg", "image/gif", "image/webp"})
"""The image media types this server will hand to a caller, and the only four it names.

They are the four the MCP SDK names for image content -- its own `Image` helper
maps exactly these four extensions -- which is the surface this proxy exists to
serve. `image/svg+xml` is deliberately absent: an SVG is a
document that can carry script, so a client that renders one executes what it
renders, and nothing here can look inside it. `image/jpg` is absent for a duller
reason -- it is not a registered type, and the header's spelling is not ours.
"""

_PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def sniff_image_type(body: bytes) -> str | None:
    """Which member of :data:`IMAGE_TYPES` these bytes are, from their own first bytes.

    The header's media type comes from the party being guarded against, while the
    string this server writes into an image block is what the caller's decoder
    trusts -- so the two have to be checked against each other. Magic numbers,
    not a decoder: this process never opens the image.
    """
    if body.startswith(_PNG_SIGNATURE):
        return "image/png"
    if body.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if body.startswith((b"GIF87a", b"GIF89a")):
        return "image/gif"
    if body.startswith(b"RIFF") and body[8:12] == b"WEBP":
        return "image/webp"
    return None

SCRAPPA_SCRAPER_ENDPOINT = "https://scrappa.co/api/web-scraper"
CRAWL4AI_CRAWL_PATH = "/crawl"
# The keyless reader takes the target as a *path suffix*, not a query parameter, and returns markdown.
JINA_READER_ENDPOINT = "https://r.jina.ai/"
# The reader's marker between its header block and the page, lower-cased because the parser compares header keys that way.
JINA_CONTENT_MARKER = "markdown content"
# The two keyed fallbacks dial the extraction endpoint of a provider name this tree already
# carries, so the credential and the permission set are the ones `[providers.tavily]` and
# `[providers.linkup]` already write for `search`.
TAVILY_EXTRACT_ENDPOINT = "https://api.tavily.com/extract"
LINKUP_FETCH_ENDPOINT = "https://api.linkup.so/v1/fetch"


class FetchBlocked(ProviderError):
    """A URL was refused by policy before, or during, the request.

    Not retryable: the answer will be the same next time, and a model that reads
    "retry shortly" will do exactly that.
    """

    def __init__(self, message: str) -> None:
        super().__init__("fetch", message, retryable=False)


class UrlBlocked(FetchBlocked):
    """A URL the guardrails refused before any request was sent.

    Raised only by the two checks that run against the URL *as written* --
    :func:`validate_url`'s scheme and shape rules and :func:`resolve_public`'s
    address rules -- so it is the one refusal a caller can act on by choosing a
    different URL. The REST projection reports it apart from a mid-flight one.

    The redirect call sites re-tag it as :class:`RedirectBlocked`.
    """

    def __init__(self, message: str) -> None:
        super().__init__(message)


class RedirectBlocked(FetchBlocked):
    """A URL the guardrails refused with a request already in flight.

    Both URL-level checks run a second time on a *redirect target* --
    :meth:`HttpFetcher._next_hop` validates the target's scheme and shape, and
    the hop loop re-checks its addresses -- and by then a request has gone out,
    so the refusal is of a URL nobody asked for. That is what makes the REST
    projection's 400/502 split a question of provenance.

    Deliberately a sibling of :class:`UrlBlocked`, not a subclass: the engine's
    one ``isinstance(exc, UrlBlocked)`` must not catch a redirect refusal.
    """

    def __init__(self, message: str) -> None:
        super().__init__(message)


@dataclass(slots=True)
class FetchedImage:
    """One image resource: the media type its own bytes agreed with, and the body.

    The two travel together because the agreement is the point -- the type was
    checked against the first bytes, not taken from the server's header.
    """

    media_type: str
    body: bytes


@dataclass(slots=True)
class FetchedPage:
    """One fetched and extracted page, before response metadata is attached."""

    url: str
    """Where the fetch actually landed, after any redirects."""
    title: str | None
    text: str
    content_type: str | None
    status_code: int
    truncated: bool
    total_chars: int
    path_addressable: bool = False
    """Whether `text` is a structure this build rendered, so `path` can select in it.

    Carried out of the extraction instead of inferred from the page: see
    :attr:`ExtractResult.path_addressable`. The fallback that reads a body with a
    library or a browser never sets it, because what it returns is prose.
    """

    image: FetchedImage | None = None
    """The whole image body, when the resource *is* an image and `fetch.allow_images` is on.

    An image page carries no text, and its bytes reach a caller only through the
    encodings that can hold them -- an MCP image content block, or the REST body's
    ``image`` field -- never inside the text a model reads. ``total_chars`` stays 0
    because the character coordinate system it indexes has nothing in it.
    """


UNCAPPED = 2**31 - 1
"""The ``max_chars`` value meaning "no cap".

Extraction is already memory-bounded -- ``max_download_bytes`` on the body,
and ``jsondoc``'s own ratio on a JSON rendering -- so an uncut page is a
bounded thing; this sentinel exists so callers can ask for it
explicitly (the query-targeted fetch does, because it selects passages from
the whole text) without a ``None`` thread through every fallback's signature.
"""


def resolved_cap(default: int, max_chars: int | None) -> int:
    """``max_chars=None`` means the fallback's own configured default."""
    return default if max_chars is None else max_chars


def _type_refusal(kind: str, extractor: Extractor) -> str:
    """Why a media type nothing here can read was refused, and what would change it.

    Derived from the backend's supported set so a backend swap cannot leave the
    sentence claiming a type the new backend does not have. An image's
    readability is the operator's decision, so that refusal names the switch.
    """
    message = (
        f"cannot extract text from {kind}; this tool reads "
        f"{describe_types(extractor.supported_types)}"
    )
    if kind in IMAGE_TYPES:
        message += (
            "; set fetch.allow_images = true to return image bytes to a caller "
            "that can read them"
        )
    return message


def window_text(text: str, *, offset: int, max_chars: int) -> tuple[str, bool]:
    """Slice the window ``[offset, offset + max_chars)`` out of an extraction.

    Returns ``(window, more_remains)``; ``more_remains`` is what ``truncated``
    is built from. The ``"\\n\\n[...]"`` marker is appended *after* slicing, so
    the offsets a caller sees, and the ``offset`` it passes back to continue,
    always index the un-marker'd extraction.

    Cut at a paragraph break when one falls in the back half of the budget,
    mirroring the sentence-boundary rule in providers.base.truncate_snippet.
    A window that reaches the end of the page is returned whole. An offset past
    the end is the one exception: the page does hold text, so ``more_remains``
    stays truthful.
    """
    remainder = text[offset:]
    if len(remainder) <= max_chars and offset <= len(text):
        return remainder, False

    window = text[offset : offset + max_chars + 1]
    cut = window.rfind("\n\n")
    if cut <= max_chars // 2:
        cut = max_chars
    more_remains = offset + cut < len(text) or offset > len(text)
    sliced = text[offset : offset + cut].rstrip()
    if sliced and more_remains:
        sliced += "\n\n[...]"
    return sliced, more_remains


class ContentFetcher(Protocol):
    name: str

    # Each fallback declares its own price at its own class: its pack rate, or ``None`` -- "no price to record", not "free".
    # Read-only so a priced fallback satisfies it: a plain attribute is invariant, and ``float`` is not assignable to ``float | None``.
    @property
    def cost_per_1k(self) -> float | None: ...

    async def fetch(
        self, url: str, *, offset: int = 0, max_chars: int | None = None
    ) -> FetchedPage:
        """Fetch, extract, and window to ``[offset, offset + max_chars)``.

        ``max_chars=None`` means this fallback's own configured default
        (``self._max_text_chars``); ``total_chars`` always reports the full
        extraction, whatever the window.
        """
        ...
    async def aclose(self) -> None: ...


@dataclass(frozen=True)
class Fallback:
    """One row of :data:`KNOWN_FALLBACKS`: the facts the ladder and the report need.

    Each is declared by the fallback instead of read out of it somewhere else.
    ``name`` is what the journal line and the ladder log record; ``endpoint`` is
    the constant the fallback dials, which is how its host reaches the proxy
    allow-lists ``tools/egress_lists.py`` renders; ``build`` returns the built
    fallback, or ``None`` when this deployment has not given it what it needs.

    ``billable`` is the tier: ``fetch.fallback``'s validator refuses a fallback
    that can bill anywhere but last by asking this, so a new priced vendor
    inherits the rule rather than a new clause. A fallback whose host is this
    deployment's own config declares ``endpoint=None`` and names in
    ``fetch_key`` the ``[fetch]`` attribute holding that host, which is what
    lets ``--check`` report the host it cannot read.
    """

    name: str
    billable: bool
    endpoint: str | None
    build: Callable[[Config], ContentFetcher | None]
    # The ``[fetch]`` attribute holding this row's host, set exactly where ``endpoint`` is ``None``:
    # the row says where the operator writes the host no reading of ``src/`` can name.
    fetch_key: str | None = None

    def __post_init__(self) -> None:
        """A row either dials a named constant or reads a config key; never neither.

        A row declaring neither is a fallback whose host nothing in the tree can
        name: a strict fetch policy would have nothing to carry.
        """
        if self.endpoint is None and not self.fetch_key:
            raise ValueError(
                f"fetch fallback {self.name!r} declares endpoint=None and no fetch_key, "
                "so nothing in this tree names the host it dials"
            )


def validate_url(raw: str) -> str:
    """Check scheme and shape. Raises :class:`UrlBlocked`.

    Credentials are refused rather than stripped: a model constructing
    ``http://user:pass@host/`` has been told to exfiltrate something or is
    replaying a secret it read on a page.

    The port is settled here rather than at connect time: ``urlsplit`` accepts
    ``:99999`` and ``:notaport`` silently, and the failure would surface as an
    OverflowError/ExceptionGroup past every handler that maps a refusal onto
    :class:`FetchBlocked`.
    """
    try:
        parts = urlsplit(raw.strip())
    except ValueError as exc:
        raise UrlBlocked(f"unparseable URL: {exc}") from exc

    if parts.scheme.lower() not in ALLOWED_SCHEMES:
        raise UrlBlocked(
            f"scheme {parts.scheme or '(none)'!r} is not fetchable; "
            "only http and https are allowed"
        )
    if parts.username or parts.password:
        raise UrlBlocked("URLs with embedded credentials are refused")
    try:
        host = parts.hostname
    except ValueError as exc:
        raise UrlBlocked(f"invalid host: {exc}") from exc
    if not host:
        raise UrlBlocked("URL has no host")
    try:
        port = parts.port
    except ValueError as exc:
        raise UrlBlocked(f"invalid port: {exc}") from exc
    if port == 0:
        raise UrlBlocked("port 0 is not fetchable")
    return urlunsplit(
        (parts.scheme.lower(), parts.netloc, parts.path or "/", parts.query, "")
    )


def _is_public(address: str) -> bool:
    """Whether an IP literal is routable on the public internet.

    ``is_global`` already covers loopback, RFC1918, link-local (including the
    cloud metadata address 169.254.169.254), multicast and reserved ranges, in
    both address families. IPv4-mapped IPv6 is unwrapped first: ``is_global`` on
    the wrapper does not see through ``::ffff:127.0.0.1``.
    """
    try:
        ip = ipaddress.ip_address(address)
    except ValueError:
        return False
    mapped = getattr(ip, "ipv4_mapped", None)
    if mapped is not None:
        ip = mapped
    return ip.is_global


async def resolve_public(host: str) -> None:
    """Refuse a hostname that resolves anywhere non-public.

    Raises :class:`UrlBlocked`: this runs before the first request, so a refusal
    here is a refusal of the URL as written, not of a fetch that failed.

    *Every* returned address must be public, not merely the first: a hostile
    name can answer with one public and one private record.

    This narrows the window rather than closing it: httpx resolves the name again
    between this lookup and the connection, so a DNS entry that changes in that
    gap -- classic rebinding -- is not caught. ``fetch.allow_private_addresses``
    is the escape hatch for intranet fetches.
    """
    # An IP literal needs no lookup, and getaddrinfo would happily echo it back.
    if _is_ip_literal(host):
        if not _is_public(host.strip("[]")):
            raise UrlBlocked(f"{host} is not a public address")
        return

    try:
        infos = await asyncio.to_thread(
            socket.getaddrinfo, host, None, 0, socket.SOCK_STREAM
        )
    except socket.gaierror as exc:
        raise UrlBlocked(f"could not resolve {host}") from exc

    # sockaddr[0] is the address for both AF_INET and AF_INET6; str() because
    # the tuple is typed loosely enough to include ints for other families.
    addresses = {str(info[4][0]) for info in infos}
    if not addresses:
        raise UrlBlocked(f"could not resolve {host}")
    blocked = sorted(a for a in addresses if not _is_public(a))
    if blocked:
        raise UrlBlocked(
            f"{host} resolves to a non-public address ({blocked[0]}); "
            "fetching private, loopback and link-local addresses is disabled"
        )


def _is_ip_literal(host: str) -> bool:
    try:
        ipaddress.ip_address(host.strip("[]"))
    except ValueError:
        return False
    return True


async def _validated_remote_target(url: str) -> str:
    """Validate a URL about to be handed to a remote fetch service, unconditionally.

    ``fetch.allow_private_addresses`` deliberately does not apply here. That
    setting lets this server reach your intranet; it says nothing about handing
    your internal hostnames to a third party, which is a leak rather than a
    fetch. Every remote fallback therefore refuses private addresses.
    """
    target = validate_url(url)
    await resolve_public(urlsplit(target).hostname or "")
    return target


class HttpFetcher:
    """Fetch a URL over HTTP and extract its text.

    The extraction backend is injected and required: a default would import a
    backend module at ``fetcher`` import time, so an install without the
    selected extra would fail on ``import server`` rather than on the fetch.
    """

    name = "fetch"
    # This process reading a socket: nothing to bill, so ``None`` rather than 0.0 -- see ``ContentFetcher.cost_per_1k``.
    cost_per_1k: float | None = None

    def __init__(
        self,
        *,
        extractor: Extractor,
        timeout: float = 15.0,
        max_download_bytes: int = 8_388_608,
        max_text_chars: int = 40_000,
        max_redirects: int = 3,
        allow_private_addresses: bool = False,
        allow_images: bool = False,
        # The same derived default the config carries, so a hand-built fetcher is not a second place the version is written.
        user_agent: str = DEFAULT_USER_AGENT,
    ) -> None:
        self._extractor = extractor
        self._max_download_bytes = max_download_bytes
        self._max_text_chars = max_text_chars
        self._max_redirects = max_redirects
        self._allow_private = allow_private_addresses
        self._allow_images = allow_images
        self._timeout = timeout
        # Its own client, for two security properties: every redirect hop needs re-validation,
        # and no provider Authorization header may ride to an arbitrary third-party site.
        self._client = httpx.AsyncClient(
            follow_redirects=False,
            timeout=httpx.Timeout(timeout, connect=min(5.0, timeout)),
            headers={
                "User-Agent": user_agent,
                # JSON rides at q=0.7: it is read here now, and an endpoint that
                # negotiates should answer with the document rather than a wrapper page.
                "Accept": "text/html,application/xhtml+xml,application/pdf;q=0.9,"
                "text/plain;q=0.8,application/json;q=0.7,*/*;q=0.1",
            },
        )

    async def fetch(
        self, url: str, *, offset: int = 0, max_chars: int | None = None
    ) -> FetchedPage:
        # One wall-clock budget for the whole chain: twice the per-request timeout, not the full timeout on every hop.
        try:
            async with asyncio.timeout(self._timeout * 2):
                return await self._fetch_chain(url, offset=offset, max_chars=max_chars)
        except TimeoutError as exc:
            raise ProviderError("fetch", "request timed out") from exc

    async def _fetch_chain(
        self, url: str, *, offset: int, max_chars: int | None
    ) -> FetchedPage:
        current = validate_url(url)
        hop = 0
        # Not a bounded `for`: every hop returns a page or raises, so the guard at the cap is the chain's only cap.
        while True:
            if not self._allow_private:
                # The first hop is the URL the caller wrote, every later one a redirect target: same guardrail,
                # opposite answer to "did a request go out?", so the refusal is re-tagged -- see `RedirectBlocked`.
                try:
                    await resolve_public(urlsplit(current).hostname or "")
                except UrlBlocked as exc:
                    if hop == 0:
                        raise
                    raise RedirectBlocked(exc.message) from exc

            try:
                response = await self._client.send(
                    self._client.build_request("GET", current),
                    stream=True,
                    follow_redirects=False,
                )
            except httpx.TimeoutException as exc:
                raise ProviderError("fetch", "request timed out") from exc
            except httpx.HTTPError as exc:
                # Not interpolated: httpx errors can carry request headers.
                raise ProviderError("fetch", "network error") from exc

            try:
                if response.is_redirect:
                    if hop >= self._max_redirects:
                        raise FetchBlocked(
                            f"more than {self._max_redirects} redirects"
                        )
                    current = self._next_hop(current, response)
                    hop += 1
                    continue
                return await self._read(current, response, offset=offset, max_chars=max_chars)
            finally:
                await response.aclose()

    def _next_hop(self, current: str, response: httpx.Response) -> str:
        # Reachable: the hop loop branches on httpx's `is_redirect`, a status-code test, so a 302 with no Location lands here.
        location = response.headers.get("location")
        if not location:
            raise ProviderError("fetch", "redirect without a Location header")

        # A request has already gone out by the time this runs, so a refusal here is a failed fetch rather
        # than a refused one: only this call site re-tags the `UrlBlocked` `validate_url` raises.
        try:
            target = validate_url(str(httpx.URL(current).join(location)))
        except UrlBlocked as exc:
            raise RedirectBlocked(exc.message) from exc
        # A redirect from https to http is either a misconfiguration or an
        # active downgrade; either way the caller asked for the secure one.
        if urlsplit(current).scheme == "https" and urlsplit(target).scheme == "http":
            raise FetchBlocked("refused a redirect from https to http")
        return target

    async def _read_body(
        self, response: httpx.Response, content_type: str | None
    ) -> bytes:
        """Read the body under the download cap, refusing a document cut in half.

        The cap is enforced against the accumulated bytes, not from
        Content-Length: that header is supplied by the party we are guarding
        against and is absent on chunked responses. The buffer is sliced rather
        than merely breaking the loop, because a server sending the whole body
        as one chunk would otherwise land it in memory in full.

        HTML degrades gracefully when cut -- the head is still the article. A
        PDF does not: its cross-reference table lives at the end. A JSON
        document likewise stops parsing, so `path` would answer "not a JSON
        document" about a page that was. A record stream is the exception that
        keeps its text, and an image cut short is a partial picture nothing
        here can tell apart from the original.
        """
        body = bytearray()
        capped = False
        async for chunk in response.aiter_bytes():
            remaining = self._max_download_bytes - len(body)
            if len(chunk) >= remaining:
                body.extend(chunk[:remaining])
                capped = True
                break
            body.extend(chunk)

        limit_kib = self._max_download_bytes // 1024
        kind = media_type(content_type)
        if capped and kind in PDF_TYPES:
            raise FetchBlocked(
                f"PDF exceeds the {limit_kib} KiB download limit and cannot be "
                "read in part; raise fetch.max_download_bytes to read it"
            )
        if capped and is_json_document_media(kind):
            raise FetchBlocked(
                f"JSON document exceeds the {limit_kib} KiB download limit, and "
                "one cut in the middle cannot be read as one; raise "
                "fetch.max_download_bytes to read it"
            )
        if capped and kind in IMAGE_TYPES:
            raise FetchBlocked(
                f"{kind} image exceeds the {limit_kib} KiB download limit and "
                "cannot be returned in part; raise fetch.max_download_bytes to "
                "return it"
            )
        return bytes(body)

    async def _read(
        self, url: str, response: httpx.Response, *, offset: int, max_chars: int | None
    ) -> FetchedPage:
        if response.status_code >= 400:
            # An error page's body is not content. Returning it would hand the
            # model a 404 page to summarise as though it were the article.
            raise ProviderError("fetch", f"HTTP {response.status_code}")

        content_type = response.headers.get("content-type")
        kind = media_type(content_type)
        # An admitted image is handed over whole before any extraction question is
        # asked: no backend extracts text from a picture, and the ladder would bill
        # a fallback to look for prose in a photograph.
        if kind in IMAGE_TYPES and self._allow_images:
            return await self._read_image(url, response, kind)
        if kind and not is_supported(self._extractor.supported_types, kind):
            raise FetchBlocked(_type_refusal(kind, self._extractor))

        body = await self._read_body(response, content_type)

        # The backend walks a stranger's bytes synchronously; a parse that will not stop holds the loop: it runs in a worker thread.
        # The wait gets the fetcher's per-request deadline, not a new config key: `fetch.timeout_seconds` sets it.
        try:
            extracted = await asyncio.wait_for(
                asyncio.to_thread(self._extractor.extract, body, content_type),
                self._timeout,
            )
        except ExtractionFailed as exc:
            raise FetchBlocked(f"cannot extract text: {exc}") from exc
        except TimeoutError as exc:
            # Not retryable -- the same bytes parse the same way next time.
            # The thread is waited on, not stopped, so the worker pool is the ceiling on what an abandoned parse costs.
            what = f"{kind} extraction" if kind else "extraction"
            raise FetchBlocked(
                f"cannot extract text: {what} did not finish within "
                f"{self._timeout:g} seconds; raise fetch.timeout_seconds to "
                "allow a longer parse"
            ) from exc

        text, truncated = window_text(
            extracted.text,
            offset=offset,
            max_chars=resolved_cap(self._max_text_chars, max_chars),
        )

        return FetchedPage(
            url=url,
            title=extracted.title,
            text=text,
            content_type=kind or None,
            status_code=response.status_code,
            truncated=truncated,
            total_chars=extracted.total_chars,
            path_addressable=extracted.path_addressable,
        )

    async def _read_image(
        self, url: str, response: httpx.Response, kind: str
    ) -> FetchedPage:
        """Hand back an image whole, and only when its bytes agree with its header.

        Nothing is extracted, so the empty ``text`` is what makes the ladder's
        emptiness gate and the response's paging fields read correctly.
        """
        body = await self._read_body(response, kind)
        if sniff_image_type(body) != kind:
            raise FetchBlocked(
                f"the response is served as {kind}, but its first bytes are not "
                "that image type"
            )
        return FetchedPage(
            url=url,
            title=None,
            text="",
            content_type=kind,
            status_code=response.status_code,
            truncated=False,
            total_chars=0,
            image=FetchedImage(media_type=kind, body=body),
        )

    async def aclose(self) -> None:
        await self._client.aclose()


class ScrappaFetcher:
    """Fetch a URL through Scrappa's scraper instead of over our own socket.

    The point is JavaScript: :class:`HttpFetcher` reads the HTML the server
    sends, and for a client-rendered page that is an empty shell. Scrappa runs a
    browser, so it is the fallback for pages the local path cannot read at all.
    Billed one credit per request, whatever the page holds -- which is why it is
    opt-in (``fetch.fallback = ["scrappa"]``) and never the primary. That
    per-call price is the one the fetch journal line records and the one
    ``fetch.cost_per_1k`` overrides.
    """

    name = "scrappa"
    # Declared at class level, not just in ``__init__``, so the class satisfies the ContentFetcher protocol.
    # ``0.30``/1k is the pack rate in providers.md ("Fetch endpoints among the in-tree providers"), declared
    # on the same basis as ``ProviderConfig.cost_per_1k``; ``[fetch] cost_per_1k`` stays the operator's
    # correction of it, one key for the whole ladder.
    cost_per_1k: float = 0.30

    def __init__(
        self,
        api_key: str,
        *,
        cost_per_1k: float | None = None,
        timeout: float = 30.0,
        max_text_chars: int = 40_000,
    ) -> None:
        self._api_key = api_key
        self._max_text_chars = max_text_chars
        self._timeout = timeout
        if cost_per_1k is not None:
            # The operator's `[fetch] cost_per_1k`, handed over by the ladder builder. Unset keeps the figure above.
            self.cost_per_1k = cost_per_1k
        # Its own client for the same reason HttpFetcher has one: the shared client carries other providers' credentials.
        self._client = httpx.AsyncClient(
            follow_redirects=True,
            timeout=httpx.Timeout(timeout, connect=min(5.0, timeout)),
        )

    async def fetch(
        self, url: str, *, offset: int = 0, max_chars: int | None = None
    ) -> FetchedPage:
        target = await _validated_remote_target(url)

        try:
            response = await self._client.get(
                SCRAPPA_SCRAPER_ENDPOINT,
                params={"url": target, "javascript": 1, "include_html": 0},
                headers={"x-api-key": self._api_key},
                timeout=self._timeout,
            )
        except httpx.TimeoutException as exc:
            raise ProviderError(self.name, "request timed out") from exc
        except httpx.HTTPError as exc:
            # Not interpolated: httpx errors can carry the API key header.
            raise ProviderError(self.name, "network error") from exc

        if response.status_code in (401, 403):
            raise ProviderError(
                self.name, "authentication rejected (check API key)", retryable=False
            )
        if response.status_code in (402, 429):
            raise QuotaExhausted(self.name, "rate limited or out of credits")
        if response.status_code >= 400:
            raise ProviderError(self.name, f"HTTP {response.status_code}")

        try:
            body = response.json()
        except ValueError as exc:
            raise ProviderError(self.name, "malformed JSON response") from exc
        if not isinstance(body, dict):
            raise ProviderError(self.name, "malformed JSON response")

        return self._to_page(target, body, offset=offset, max_chars=max_chars)

    def _to_page(
        self, url: str, body: dict[str, object], *, offset: int, max_chars: int | None
    ) -> FetchedPage:
        """Map the scraper payload onto a :class:`FetchedPage`.

        ``site_status_code`` is the *origin's* status, distinct from Scrappa's
        own -- a 404 page scraped successfully is a successful API call and a
        failed fetch, and the same rule as ``HttpFetcher._read`` applies: an
        error page's body is not content.
        """
        if body.get("success") is False:
            raise ProviderError(self.name, "scraper reported failure")

        status = body.get("site_status_code")
        status_code = status if isinstance(status, int) else 200
        if status_code >= 400:
            raise ProviderError(self.name, f"HTTP {status_code}")

        data = body.get("data")
        data = data if isinstance(data, dict) else {}
        title = data.get("title")
        text = data.get("body_text")
        text = text if isinstance(text, str) else ""
        final = body.get("final_url") or body.get("url")

        window, truncated = window_text(
            text, offset=offset, max_chars=resolved_cap(self._max_text_chars, max_chars)
        )
        return FetchedPage(
            url=str(final) if isinstance(final, str) and final else url,
            title=str(title) if isinstance(title, str) and title else None,
            text=window,
            # The scraper reports no content type. Claiming text/html would be a
            # guess, and the field is only ever surfaced, never dispatched on.
            content_type=None,
            status_code=status_code,
            truncated=truncated,
            total_chars=len(text),
        )

    async def aclose(self) -> None:
        await self._client.aclose()


def _build_scrappa(config: Config) -> ScrappaFetcher | None:
    """The paid fallback: keyed by the provider key, admitted by the permission set.

    Both gates are ones the deployment already writes for ``[providers.scrappa]``,
    so a permission set that omits the name leaves the fallback unbuilt rather
    than firing it (docs/reference/allow-list.md, site 7).
    """
    if not config.is_permitted("scrappa"):
        return None
    key = config.api_key("scrappa")
    if not key:
        return None
    # `[fetch] cost_per_1k` is the operator's correction of the figure the fallback declares on its own class;
    # an unset key hands over `None`, and the fallback keeps its own price. One key prices every priced fallback
    # in the ladder at once, since the config keys are frozen.
    return ScrappaFetcher(
        key,
        cost_per_1k=config.fetch.cost_per_1k,
        # A browser-served page waits longer than a static fetch, so the fallback floors its own timeout.
        timeout=max(config.fetch.timeout_seconds, 30.0),
        max_text_chars=config.fetch.max_text_chars,
    )


class Crawl4aiFetcher:
    """Fetch a URL through the self-hosted crawl4ai renderer, as markdown.

    The renderer fallback of the fetch ladder: a real Chromium that executes the
    JavaScript :class:`HttpFetcher` cannot, self-hosted so it costs nothing. It
    is a service the proxy talks to over HTTP, deliberately not a library in
    this process; `docs/reference/crawl4ai.md` holds the endpoint it speaks to.

    Security posture mirrors :class:`ScrappaFetcher`: own client, and the target
    passes :func:`_validated_remote_target` before anything is posted. With a
    browser on the far side the stakes are higher -- a rendered page can fetch
    more of your network from the inside.

    Only the free markdown path of the API is used: ``POST /crawl`` with empty
    default configs, which on the pinned 0.9.x line means bypass-cache plus
    markdown. See docs/reference/crawl4ai.md for the pinned shape.
    """

    name = "crawl4ai"
    # Self-hosted, so it costs nothing: ``None`` rather than 0.0, on the local fallback's rule -- nothing was billed.
    cost_per_1k: float | None = None

    def __init__(
        self,
        base_url: str,
        *,
        token: str | None = None,
        timeout: float = 60.0,
        max_text_chars: int = 40_000,
    ) -> None:
        self._base_url = base_url.rstrip("/")
        self._token = token
        self._max_text_chars = max_text_chars
        self._timeout = timeout
        # Its own client for the same reason both other fetchers have one.
        # Redirect-following is fine here: the target rides in the JSON body to the operator's own endpoint.
        self._client = httpx.AsyncClient(
            follow_redirects=True,
            timeout=httpx.Timeout(timeout, connect=min(5.0, timeout)),
        )

    def _headers(self) -> dict[str, str]:
        # Built per request rather than parked on the client: a credential that only exists at the call site
        # cannot ride along on any other request this client makes.
        if self._token:
            return {"Authorization": f"Bearer {self._token}"}
        return {}

    async def fetch(
        self, url: str, *, offset: int = 0, max_chars: int | None = None
    ) -> FetchedPage:
        target = await _validated_remote_target(url)

        try:
            response = await self._client.post(
                f"{self._base_url}{CRAWL4AI_CRAWL_PATH}",
                # Empty configs on purpose: the pinned server line already defaults to bypass-cache and markdown,
                # and every interesting non-default is a feature this fallback does not use.
                json={"urls": [target], "browser_config": {}, "crawler_config": {}},
                headers=self._headers(),
            )
        except httpx.TimeoutException as exc:
            raise ProviderError(self.name, "request timed out") from exc
        except httpx.HTTPError as exc:
            # Not interpolated: httpx errors can carry the Authorization header.
            raise ProviderError(self.name, "network error") from exc

        if response.status_code in (401, 403):
            raise ProviderError(
                self.name,
                "authentication rejected (check fetch.crawl4ai_token)",
                retryable=False,
            )
        if response.status_code >= 400:
            raise ProviderError(self.name, f"HTTP {response.status_code}")

        try:
            body = response.json()
        except ValueError as exc:
            raise ProviderError(self.name, "malformed JSON response") from exc
        if not isinstance(body, dict):
            raise ProviderError(self.name, "malformed JSON response")

        return self._to_page(target, body, offset=offset, max_chars=max_chars)

    def _to_page(
        self, url: str, body: dict[str, object], *, offset: int, max_chars: int | None
    ) -> FetchedPage:
        """Map the crawl payload onto a :class:`FetchedPage`.

        Two layers of success to separate. The envelope's ``success`` is the
        *service's*: a false there means the crawl never ran. Each entry in
        ``results`` then carries its own ``success`` and the origin's
        ``status_code`` -- a 404 page rendered successfully is a successful
        crawl and a failed fetch.
        """
        if body.get("success") is False:
            raise ProviderError(self.name, "crawler reported failure")

        results = body.get("results")
        if not isinstance(results, list) or not results:
            raise ProviderError(self.name, "malformed JSON response")
        result = results[0]
        if not isinstance(result, dict):
            raise ProviderError(self.name, "malformed JSON response")
        if result.get("success") is False:
            message = result.get("error_message")
            raise ProviderError(
                self.name,
                str(message)
                if isinstance(message, str) and message
                else "crawl failed",
            )

        status = result.get("status_code")
        status_code = status if isinstance(status, int) else 200
        if status_code >= 400:
            raise ProviderError(self.name, f"HTTP {status_code}")

        # Older server lines sent `markdown` as a string, newer ones a result dict: accept both, prefer raw,
        # since `fit_markdown` trades content for tidiness.
        markdown = result.get("markdown")
        if isinstance(markdown, dict):
            raw = markdown.get("raw_markdown")
            text = raw if isinstance(raw, str) else ""
        elif isinstance(markdown, str):
            text = markdown
        else:
            text = ""

        metadata = result.get("metadata")
        metadata = metadata if isinstance(metadata, dict) else {}
        title = metadata.get("title")
        final = result.get("redirected_url") or result.get("url")

        window, truncated = window_text(
            text, offset=offset, max_chars=resolved_cap(self._max_text_chars, max_chars)
        )
        return FetchedPage(
            url=str(final) if isinstance(final, str) and final else url,
            title=str(title) if isinstance(title, str) and title else None,
            text=window,
            # The renderer reports markdown, not a media type;
            # claiming text/html would be a guess, and the field is surfaced, never dispatched on.
            content_type=None,
            status_code=status_code,
            truncated=truncated,
            total_chars=len(text),
        )

    async def aclose(self) -> None:
        await self._client.aclose()


def _build_crawl4ai(config: Config) -> Crawl4aiFetcher | None:
    """The self-hosted renderer: absent unless this deployment names its URL.

    No key and no third party, so `fetch.crawl4ai_url` is the whole prerequisite.
    Its three knobs are the only per-vendor keys `[fetch]` carries: a keyed
    fallback's credential is an environment variable, not a config key.
    """
    if not config.fetch.crawl4ai_url:
        return None
    return Crawl4aiFetcher(
        config.fetch.crawl4ai_url,
        token=config.fetch.crawl4ai_token,
        timeout=config.fetch.crawl4ai_timeout_seconds,
        max_text_chars=config.fetch.max_text_chars,
    )


def _split_reader_body(body: str) -> tuple[dict[str, str], str]:
    """Split the reader's ``text/plain`` body into its header block and the page.

    The body carries no schema: a run of ``Key: value`` lines, then the literal
    line ``Markdown Content:`` and the page under it. Only the two keys this
    fallback uses are read, so a new header line costs nothing here.

    A body with no marker line is returned whole as the page: the service
    answered with markdown it did not label, and dropping it would turn a
    usable read into an empty fallback.
    """
    lines = body.splitlines()
    for index, line in enumerate(lines):
        name, _, value = line.partition(":")
        if name.strip().lower() != JINA_CONTENT_MARKER:
            continue
        headers: dict[str, str] = {}
        for header in lines[:index]:
            key, sep, val = header.partition(":")
            if sep:
                headers[key.strip().lower()] = val.strip()
        # Anything after the marker on its own line is the page's first line,
        # not a header.
        first = [value.strip()] if value.strip() else []
        return headers, "\n".join(first + lines[index + 1 :])
    return {}, body


class JinaFetcher:
    """Fetch a URL through Jina Reader instead of over our own socket.

    The keyless hosted fallback: ``GET https://r.jina.ai/<url>`` renders the
    page server-side and hands it back as markdown, free and with no credential
    of any kind. It sits second in the ladder: a browser on the far side of the
    request, at no cost and with no service of the operator's own.

    Keyless is why this class has no credential field, so the only header it
    adds is the configured User-Agent. Everything else mirrors
    :class:`ScrappaFetcher`: its own client, and the target through
    :func:`_validated_remote_target` before anything is sent.

    The service is metered by IP rather than by key -- 20 requests per 60 s --
    which is a fallback failure like any other when hit. Its default cache is
    left on: re-rendering would spend one of those requests for nothing, so
    ``X-No-Cache: true`` is deliberately not sent.

    Free, so it declares no price: a page it served carries no ``cost_usd`` on
    its journal line.
    """

    name = "jina"
    cost_per_1k: float | None = None

    def __init__(
        self,
        *,
        user_agent: str = DEFAULT_USER_AGENT,
        timeout: float = 30.0,
        max_text_chars: int = 40_000,
    ) -> None:
        self._user_agent = user_agent
        self._max_text_chars = max_text_chars
        self._timeout = timeout
        # Its own client for the same reason every other fallback has one: none of the provider keys may ride to a third party.
        self._client = httpx.AsyncClient(
            follow_redirects=True,
            timeout=httpx.Timeout(timeout, connect=min(5.0, timeout)),
        )

    async def fetch(
        self, url: str, *, offset: int = 0, max_chars: int | None = None
    ) -> FetchedPage:
        target = await _validated_remote_target(url)

        try:
            response = await self._client.get(
                f"{JINA_READER_ENDPOINT}{target}",
                headers={
                    "Accept": "text/markdown",
                    "User-Agent": self._user_agent,
                },
                timeout=self._timeout,
            )
        except httpx.TimeoutException as exc:
            raise ProviderError(self.name, "request timed out") from exc
        except httpx.HTTPError as exc:
            # Not interpolated: httpx errors can carry request headers.
            raise ProviderError(self.name, "network error") from exc

        if response.status_code in (402, 429):
            # Free, but metered by IP: a burst shares one window with every
            # other caller behind this address.
            raise QuotaExhausted(self.name, "rate limited")
        if response.status_code >= 400:
            # 401/403 included, and not read as an auth failure: this fallback sends no credential,
            # so a rejection is the service refusing this address or target.
            raise ProviderError(self.name, f"HTTP {response.status_code}")

        return self._to_page(target, response.text, offset=offset, max_chars=max_chars)

    def _to_page(
        self, url: str, body: str, *, offset: int, max_chars: int | None
    ) -> FetchedPage:
        """Map the reader's text body onto a :class:`FetchedPage`.

        The two placeholder bodies the service returns when it has no page for
        us -- ``Loading...`` and ``Please enable JavaScript`` -- are read as
        *found nothing*, the same fact an extraction under
        ``fetch.min_text_chars`` means, which is what lets the next fallback
        fire. They are a statement about the read, not a length.

        ``status_code`` is 200 because that is what the reader answered and the
        only status it reports: the origin's own status is not in this body.
        """
        headers, text = _split_reader_body(body)
        if text.strip().startswith(("Loading...", "Please enable JavaScript")):
            text = ""

        title = headers.get("title")
        source = headers.get("url source")
        window, truncated = window_text(
            text, offset=offset, max_chars=resolved_cap(self._max_text_chars, max_chars)
        )
        return FetchedPage(
            url=source or url,
            title=title or None,
            text=window,
            # The reader returns markdown, not a media type;
            # claiming text/html would be a guess, and the field is surfaced, never dispatched on.
            content_type=None,
            status_code=200,
            truncated=truncated,
            total_chars=len(text),
        )

    async def aclose(self) -> None:
        await self._client.aclose()


def _build_jina(config: Config) -> JinaFetcher | None:
    """The keyless reader: the permission set is the only thing that can refuse it.

    There is no key to be missing, and the name is admissible through
    ``PERMITTED_FETCH_NAMES`` rather than ``KNOWN_PROVIDERS`` (allow-list.md,
    site 7).
    """
    if not config.is_permitted("jina"):
        return None
    return JinaFetcher(
        user_agent=config.fetch.user_agent,
        timeout=max(config.fetch.timeout_seconds, 30.0),
        max_text_chars=config.fetch.max_text_chars,
    )


class TavilyFetcher:
    """Fetch a URL through Tavily's extract endpoint instead of over our own socket.

    The keyed fallback on a credential this deployment may already hold: `tavily`
    is a provider name, so `SEEKWRIGHT_TAVILY_API_KEY` is already in the
    environment wherever Tavily search is enabled, and its allow-list entry gates
    this fallback too. What it buys over :class:`HttpFetcher` is a markdown-first
    read performed by a service that owns the fetching.

    Tavily bills **successful extractions, not calls**: 1 credit per 5 at
    `basic`, 2 per 5 at `advanced` (`docs/reference/providers.md`). At the $8/1k
    credit rate :class:`TavilyProvider` declares, that is $1.60 per 1k basic
    extractions, which is why ``cost_per_1k`` defaults to 1.60.

    ``extract_depth`` stays `basic` for the reason the search adapter gives for
    ``search_depth``: the dearer depth doubles the credit. One URL goes in a
    call; `query` and `chunks_per_source` would select passages of a search
    result, and this fallback is asked for a page.

    The envelope is parsed here and never leaves the fallback, so
    ``path_addressable`` stays false -- handing the vendor body on as
    `application/json` would let ``path`` select inside the response.

    ``include_usage`` is not asked for: the journal prices a served page from
    ``cost_per_1k``, so the credit count would be a number nothing reads.
    """

    name = "tavily"
    # Declared at class level, not just assigned in ``__init__``, so the class satisfies the ContentFetcher protocol --
    # the shape ``TavilyProvider`` carries for ``SearchProvider``.
    cost_per_1k: float

    def __init__(
        self,
        api_key: str,
        *,
        cost_per_1k: float = 1.60,
        timeout: float = 30.0,
        max_text_chars: int = 40_000,
    ) -> None:
        self._api_key = api_key
        self._max_text_chars = max_text_chars
        self._timeout = timeout
        self.cost_per_1k = cost_per_1k
        # Its own client for the same reason every fallback has one: no provider key may ride to a third party.
        self._client = httpx.AsyncClient(
            timeout=httpx.Timeout(timeout, connect=min(5.0, timeout))
        )

    async def fetch(
        self, url: str, *, offset: int = 0, max_chars: int | None = None
    ) -> FetchedPage:
        target = await _validated_remote_target(url)

        try:
            response = await self._client.post(
                TAVILY_EXTRACT_ENDPOINT,
                json={
                    "urls": [target],
                    # `markdown`, the form the ladder wants; the vendor's other answer is plain text.
                    "format": "markdown",
                    "extract_depth": "basic",
                    # The vendor's own bound on the extraction, held inside its 1-60 s range; the client's bound is `self._timeout`.
                    "timeout": min(60.0, max(1.0, self._timeout)),
                },
                headers={"Authorization": f"Bearer {self._api_key}"},
                timeout=self._timeout,
            )
        except httpx.TimeoutException as exc:
            raise ProviderError(self.name, "request timed out") from exc
        except httpx.HTTPError as exc:
            # Not interpolated: httpx errors can carry the bearer header.
            raise ProviderError(self.name, "network error") from exc

        if response.status_code in (401, 403):
            raise ProviderError(
                self.name, "authentication rejected (check API key)", retryable=False
            )
        # 432 is this vendor's monthly-credits-exhausted code and 429 its short-term limit,
        # the same reading the search adapter on this key takes.
        if response.status_code in (429, 432):
            raise QuotaExhausted(self.name, "rate limited or out of credits")
        if response.status_code >= 400:
            raise ProviderError(self.name, f"HTTP {response.status_code}")

        try:
            body = response.json()
        except ValueError as exc:
            raise ProviderError(self.name, "malformed JSON response") from exc
        if not isinstance(body, dict):
            raise ProviderError(self.name, "malformed JSON response")

        return self._to_page(target, body, offset=offset, max_chars=max_chars)

    def _to_page(
        self, url: str, body: dict[str, object], *, offset: int, max_chars: int | None
    ) -> FetchedPage:
        """Map the extract payload onto a :class:`FetchedPage`.

        `results[]` holds one entry per URL that succeeded, and an HTTP 200 with
        an empty `results` array is the vendor's way of saying every URL failed.
        That body is read as *found nothing* -- the same fact JinaFetcher's
        placeholder bodies mean -- so the walk continues to the next fallback.
        `failed_results[]` carries the vendor's reason and is dropped.

        ``url`` is the entry's own landing URL when the vendor names one; this
        fallback sends one URL, so the array order does not matter.
        """
        results = body.get("results")
        entry = results[0] if isinstance(results, list) and results else None
        entry = entry if isinstance(entry, dict) else {}

        text = entry.get("raw_content")
        text = text if isinstance(text, str) else ""
        landed = entry.get("url")

        window, truncated = window_text(
            text, offset=offset, max_chars=resolved_cap(self._max_text_chars, max_chars)
        )
        return FetchedPage(
            url=str(landed) if isinstance(landed, str) and landed else url,
            # Extract reports no title: the markdown is the whole answer, and inventing one out of
            # its first heading would be a guess the caller cannot tell from the page's own title.
            title=None,
            text=window,
            # No media type is reported for the page, and the field is surfaced, never dispatched on.
            content_type=None,
            status_code=200,
            truncated=truncated,
            total_chars=len(text),
        )

    async def aclose(self) -> None:
        await self._client.aclose()


def _build_tavily(config: Config) -> TavilyFetcher | None:
    """The keyed extract fallback: the provider key is the credential, the permission set the gate.

    Both gates are the ones the deployment writes for `[providers.tavily]`, the
    same two :func:`_build_scrappa` asks.
    """
    if not config.is_permitted("tavily"):
        return None
    key = config.api_key("tavily")
    if not key:
        return None
    price: dict[str, float] = {}
    if config.fetch.cost_per_1k is not None:
        price = {"cost_per_1k": config.fetch.cost_per_1k}
    return TavilyFetcher(
        key,
        **price,
        # The extraction timeout is part of the request, so the client is floored at 30 s.
        timeout=max(config.fetch.timeout_seconds, 30.0),
        max_text_chars=config.fetch.max_text_chars,
    )


class LinkupFetcher:
    """Fetch a URL through Linkup's fetch endpoint instead of over our own socket.

    The keyed fallback that renders JavaScript: `renderJs` is the failure class
    :class:`HttpFetcher` cannot cover and the one ``crawl4ai`` covers self-hosted.
    It rides the key `[providers.linkup]` already carries for `search`, so the
    operator adds no secret.

    The vendor prices `/fetch` per call by a `mode` × `renderJs` table: the cell
    this fallback sends -- `standard`, `renderJs: true`, no `schema` -- is
    `$0.005` (`docs/reference/providers.md`), so ``cost_per_1k`` defaults to
    5.00, the price of the call made. `mode` stays `standard`: `pro` is a price
    cliff.

    ``renderJs`` is sent `true` rather than left at the vendor's default, because
    a fallback that does not render is a worse :class:`HttpFetcher`.
    `extractImages`, `includeRawHtml` and `includeRawContent` are sent `false` so
    a vendor-side default change cannot buy bytes this ladder has no path for.
    Image bytes reach a caller only through `fetch.allow_images`, so
    `images[]` is dropped. `schema` cannot appear, and `instructions` without
    one is a 400.

    The envelope is parsed here and never leaves the fallback, so
    ``path_addressable`` stays false.
    """

    name = "linkup"
    # Declared at class level, as in ``TavilyFetcher``: the protocol needs the attribute, not only the instance.
    cost_per_1k: float

    def __init__(
        self,
        api_key: str,
        *,
        cost_per_1k: float = 5.00,
        timeout: float = 30.0,
        max_text_chars: int = 40_000,
    ) -> None:
        self._api_key = api_key
        self._max_text_chars = max_text_chars
        self._timeout = timeout
        self.cost_per_1k = cost_per_1k
        # Its own client, for the reason every fallback has one: the LinkUp key may ride to api.linkup.so and nowhere else.
        self._client = httpx.AsyncClient(
            timeout=httpx.Timeout(timeout, connect=min(5.0, timeout))
        )

    async def fetch(
        self, url: str, *, offset: int = 0, max_chars: int | None = None
    ) -> FetchedPage:
        target = await _validated_remote_target(url)

        try:
            response = await self._client.post(
                LINKUP_FETCH_ENDPOINT,
                json={
                    "url": target,
                    "renderJs": True,
                    "mode": "standard",
                    "extractImages": False,
                    "includeRawHtml": False,
                    "includeRawContent": False,
                },
                headers={"Authorization": f"Bearer {self._api_key}"},
                timeout=self._timeout,
            )
        except httpx.TimeoutException as exc:
            raise ProviderError(self.name, "request timed out") from exc
        except httpx.HTTPError as exc:
            # Not interpolated: httpx errors can carry the bearer header.
            raise ProviderError(self.name, "network error") from exc

        if response.status_code in (401, 403):
            raise ProviderError(
                self.name, "authentication rejected (check API key)", retryable=False
            )
        # A spent account and a burst share 429 here, as the search adapter on this key reads it;
        # LinkUp's 402 belongs to the keyless x402 lane this tree never enters.
        if response.status_code == 429:
            raise QuotaExhausted(self.name, "rate limited or out of credits")
        if response.status_code >= 400:
            raise ProviderError(self.name, f"HTTP {response.status_code}")

        try:
            body = response.json()
        except ValueError as exc:
            raise ProviderError(self.name, "malformed JSON response") from exc
        if not isinstance(body, dict):
            raise ProviderError(self.name, "malformed JSON response")

        return self._to_page(target, body, offset=offset, max_chars=max_chars)

    def _to_page(
        self, url: str, body: dict[str, object], *, offset: int, max_chars: int | None
    ) -> FetchedPage:
        """Map the fetch payload onto a :class:`FetchedPage`.

        `markdown` is the field the service always returns, and an empty one is a
        page it could not read -- the near-empty class `fetch.min_text_chars`
        refuses, so the walk goes on to the next fallback.

        ``url`` stays the target the caller wrote: the service follows no links,
        so there is no landed address to report in its place.
        """
        text = body.get("markdown")
        text = text if isinstance(text, str) else ""

        window, truncated = window_text(
            text, offset=offset, max_chars=resolved_cap(self._max_text_chars, max_chars)
        )
        return FetchedPage(
            url=url,
            # The payload carries no page title: `favicon`, `contentType` and the typed `data` are the
            # other fields, and none of them is a title.
            title=None,
            text=window,
            # `contentType` names a kind ("html"), not a media type; claiming one from it would be a guess,
            # and the field is surfaced, never dispatched on.
            content_type=None,
            status_code=200,
            truncated=truncated,
            total_chars=len(text),
        )

    async def aclose(self) -> None:
        await self._client.aclose()


def _build_linkup(config: Config) -> LinkupFetcher | None:
    """The keyed rendering fallback: the provider key is the credential, the permission set the gate.

    The two gates are the ones `[providers.linkup]` already writes, exactly as in
    :func:`_build_tavily`: the same key serves `search` and this fallback.
    """
    if not config.is_permitted("linkup"):
        return None
    key = config.api_key("linkup")
    if not key:
        return None
    price: dict[str, float] = {}
    if config.fetch.cost_per_1k is not None:
        price = {"cost_per_1k": config.fetch.cost_per_1k}
    return LinkupFetcher(
        key,
        **price,
        # A rendered page waits longer than a static fetch, so the client is floored at 30 s.
        timeout=max(config.fetch.timeout_seconds, 30.0),
        max_text_chars=config.fetch.max_text_chars,
    )


KNOWN_FALLBACKS: dict[str, Fallback] = {
    "crawl4ai": Fallback(
        name="crawl4ai",
        billable=False,
        # Not a constant: the host is `fetch.crawl4ai_url`, this deployment's own config, so the strict fetch list answers for it.
        endpoint=None,
        fetch_key="crawl4ai_url",
        build=_build_crawl4ai,
    ),
    "jina": Fallback(
        name="jina",
        billable=False,
        endpoint=JINA_READER_ENDPOINT,
        build=_build_jina,
    ),
    "scrappa": Fallback(
        name="scrappa",
        billable=True,
        endpoint=SCRAPPA_SCRAPER_ENDPOINT,
        build=_build_scrappa,
    ),
    "tavily": Fallback(
        name="tavily",
        billable=True,
        endpoint=TAVILY_EXTRACT_ENDPOINT,
        build=_build_tavily,
    ),
    "linkup": Fallback(
        name="linkup",
        billable=True,
        endpoint=LINKUP_FETCH_ENDPOINT,
        build=_build_linkup,
    ),
}
"""The fallback registry: what ``fetch.fallback`` may name, and what each name needs.

``FetchConfig._validate_fallback`` rejects a name outside this mapping and a
billable fallback anywhere but last, both by asking the row. It is the shape
``KNOWN_PROVIDERS`` and ``KNOWN_EXTRACTORS`` have, for the same reason: a name
that parses and never fires is the failure mode all three exist to remove.

What the ladder does with a fallback is three edits, and this list is the whole of
them:

1. a class implementing :class:`ContentFetcher` -- here, or its own module when
   the ``fetcher.py`` split lands, whose verdict stands (Out);
2. one row here, with its builder beside the class it builds;
3. nothing else is needed to build it: the name is admitted to ``fetch.fallback``
   by this mapping rather than by a ``Literal`` member, a branch in
   ``factory.build_fetch_stack`` is not needed, and a keyed fallback takes its
   credential from ``SEEKWRIGHT_<PROVIDER>_API_KEY`` like the provider it shares
   a name with, so no ``[fetch]`` key per vendor is added either.

``cli._report_fetch`` reads this mapping too, so the three edits above are the
whole of what an operator sees as well: every name in ``fetch.fallback`` gets one
status row, and what that row says -- permitted or not, keyed or keyless, and
which ``[fetch]`` key is missing when a configured-by-URL fallback has no host -- is
read off ``billable``, ``endpoint`` and ``fetch_key`` here. A fallback added to this
mapping is reported without an edit to ``cli.py``, so that holds in the CLI as
well as in the ladder.

Its host joins the proxy allow-lists the same way: ``tools/egress_lists.py``
renders the constant each row names, and refuses to render a tree whose row names
none.
"""
