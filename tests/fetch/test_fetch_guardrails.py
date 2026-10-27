"""The rules that keep a model-supplied URL from reaching somewhere it shouldn't.

This is the suite that matters most in the fetch path. Every other fetch failure
degrades to a notice; a guardrail failure reaches the network.

DNS is stubbed rather than hit: the assertions are about what the code does with
a resolution result, and pinning them to real DNS would make them fail on a
plane and pass against a hostile resolver.
"""

import asyncio
import io
import threading
import time
import tracemalloc
from collections.abc import Callable

import httpx
import pytest
from pypdf import PdfWriter
from pypdf.generic import DecodedStreamObject, DictionaryObject, NameObject

from seekwright import factory
from seekwright import fetcher as F
from seekwright.config import Config, FetchConfig, ProviderConfig
from seekwright.extractors.base import PDF_TYPES, ExtractResult
from seekwright.extractors.trafilatura import TrafilaturaExtractor
from seekwright.providers.base import ProviderError

_EXTRACTOR = TrafilaturaExtractor()
"""The default backend; these tests exercise the fetcher, not the choice of one."""


def _shared_stream_pdf(n_pages: int) -> bytes:
    """A well-formed PDF whose pages all show the same large content stream.

    pypdf re-walks the stream for every page, so parse time is `n_pages` times
    one page's work while the file itself stays small -- the multiplication the
    byte cap cannot see.
    """
    writer = PdfWriter()
    stream = DecodedStreamObject()
    stream.set_data(
        b"BT /F1 12 Tf "
        + b"(the quick brown fox jumps over the lazy dog) Tj\n1 0 0 1 0 14 Tm\n" * 4000
        + b"ET\n"
    )
    stream_ref = writer._add_object(stream)
    font = DictionaryObject()
    font[NameObject("/Type")] = NameObject("/Font")
    font[NameObject("/Subtype")] = NameObject("/Type1")
    font[NameObject("/BaseFont")] = NameObject("/Helvetica")
    resources = DictionaryObject(
        {NameObject("/Font"): DictionaryObject({NameObject("/F1"): writer._add_object(font)})}
    )
    for _ in range(n_pages):
        page = writer.add_blank_page(width=612, height=792)
        page[NameObject("/Resources")] = resources
        page[NameObject("/Contents")] = stream_ref
    out = io.BytesIO()
    writer.write(out)
    return out.getvalue()



BLOCKED_SCHEMES = [
    "file:///etc/passwd",
    "data:text/html,<b>hi",
    "javascript:alert(1)",
    "ftp://example.com/x",
    "gopher://example.com/",
]

BLOCKED_HOSTS = [
    "localhost",
    "127.0.0.1",
    "127.1",
    "0.0.0.0",
    "10.0.0.1",
    "192.168.1.1",
    "172.16.0.1",
    # The cloud metadata endpoint: the single most valuable target for an SSRF
    # against a server running in EC2/GCE, and reachable with no credentials.
    "169.254.169.254",
    "::1",
    "fd00::1",
    # Loopback wearing an IPv6 hat; `is_global` on the wrapper does not see it.
    "::ffff:127.0.0.1",
]


class TestSchemeAndShape:
    @pytest.mark.parametrize("url", BLOCKED_SCHEMES)
    def test_non_http_schemes_are_refused(self, url):
        with pytest.raises(F.FetchBlocked, match="not fetchable"):
            F.validate_url(url)

    def test_credentials_are_refused_not_stripped(self):
        """A model building a URL with a password is not a request to complete."""
        with pytest.raises(F.FetchBlocked, match="credentials"):
            F.validate_url("http://user:secret@example.com/")

    def test_missing_host_is_refused(self):
        with pytest.raises(F.FetchBlocked, match="no host"):
            F.validate_url("http:///path-only")

    def test_ordinary_url_passes_and_keeps_its_query(self):
        assert F.validate_url("https://e.com/a?b=1") == "https://e.com/a?b=1"

    def test_fragment_is_dropped(self):
        """Never sent to the server, so it cannot affect what comes back."""
        assert F.validate_url("https://e.com/a#frag") == "https://e.com/a"

    @pytest.mark.parametrize(
        "url",
        [
            "https://example.com:99999/",
            "https://example.com:70000/",
            "https://example.com:notaport/",
            "https://example.com:0/",
        ],
    )
    def test_an_unsendable_port_is_refused(self, url):
        """urlsplit validates the port lazily, so `:99999` passed every check
        here and failed at connect time with an OverflowError ExceptionGroup
        that bypassed every error handler below -- no FetchFailed, no log
        line, no fallback walk."""
        with pytest.raises(F.FetchBlocked, match="port"):
            F.validate_url(url)

    def test_an_ordinary_port_passes(self):
        assert F.validate_url("https://e.com:8443/a") == "https://e.com:8443/a"


class TestAddressBlocking:
    @pytest.mark.parametrize("host", BLOCKED_HOSTS)
    async def test_non_public_addresses_are_blocked(self, host, stub_dns):
        stub_dns(host, [host.strip("[]")] if _is_literal(host) else ["127.0.0.1"])
        with pytest.raises(F.FetchBlocked, match="not a public address|non-public"):
            await F.resolve_public(host)

    async def test_public_address_is_allowed(self, stub_dns):
        stub_dns("example.com", ["93.184.216.34"])
        await F.resolve_public("example.com")

    async def test_any_private_answer_blocks_the_whole_name(self, stub_dns):
        """A name answering with one public and one private record is refused.

        Checking only the first address would let a hostile resolver order its
        way past the guard.
        """
        stub_dns("split.test", ["93.184.216.34", "127.0.0.1"])
        with pytest.raises(F.FetchBlocked, match="non-public"):
            await F.resolve_public("split.test")

    async def test_unresolvable_name_is_blocked(self, stub_dns):
        stub_dns("nope.invalid", [])
        with pytest.raises(F.FetchBlocked, match="could not resolve"):
            await F.resolve_public("nope.invalid")


def _is_literal(host: str) -> bool:
    return F._is_ip_literal(host)


@pytest.fixture
def stub_dns(monkeypatch):
    """Replace getaddrinfo so resolution results are chosen by the test."""

    table: dict[str, list[str]] = {}

    def fake_getaddrinfo(host, *_args, **_kwargs):
        import socket

        addresses = table.get(host)
        if not addresses:
            raise socket.gaierror(-2, "Name or service not known")
        return [(0, 0, 0, "", (a, 0)) for a in addresses]

    monkeypatch.setattr("socket.getaddrinfo", fake_getaddrinfo)

    def register(host: str, addresses: list[str]) -> None:
        table[host] = addresses

    return register


HTML = (
    b"<!DOCTYPE html><html><head><title>Doc</title></head><body><article><p>"
    + b"Sentences of real body text. " * 40
    + b"</p></article></body></html>"
)


def make_fetcher(
    routes: dict[str, Callable[[httpx.Request], httpx.Response]], **kwargs
) -> F.HttpFetcher:
    """A fetcher wired to an in-memory transport, with address checks disabled.

    Address blocking is covered above; disabling it here keeps these tests about
    redirects, sizes and content types rather than about DNS.
    """

    def handler(request: httpx.Request) -> httpx.Response:
        route = routes.get(str(request.url))
        if route is None:
            return httpx.Response(404, content=b"missing")
        return route(request)

    extractor = kwargs.pop("extractor", _EXTRACTOR)
    fetcher = F.HttpFetcher(
        extractor=extractor, allow_private_addresses=True, **kwargs
    )
    fetcher._client = httpx.AsyncClient(
        transport=httpx.MockTransport(handler), follow_redirects=False
    )
    return fetcher


class TestRedirects:
    async def test_redirect_is_followed_and_final_url_reported(self):
        fetcher = make_fetcher(
            {
                "https://a.test/": lambda r: httpx.Response(
                    302, headers={"location": "https://b.test/"}
                ),
                "https://b.test/": lambda r: httpx.Response(
                    200, content=HTML, headers={"content-type": "text/html"}
                ),
            }
        )
        page = await fetcher.fetch("https://a.test/")
        assert page.url == "https://b.test/", "the caller must see where it landed"
        await fetcher.aclose()

    async def test_too_many_redirects_is_blocked(self):
        def redirect_to(next_host: int) -> Callable[[httpx.Request], httpx.Response]:
            def handler(request: httpx.Request) -> httpx.Response:
                return httpx.Response(
                    302, headers={"location": f"https://h{next_host}.test/"}
                )

            return handler

        routes = {f"https://h{i}.test/": redirect_to(i + 1) for i in range(8)}
        fetcher = make_fetcher(routes)
        # The message is pinned because the in-loop guard is the chain's only cap,
        # naming max_redirects.
        with pytest.raises(F.FetchBlocked, match="more than 3 redirects"):
            await fetcher.fetch("https://h0.test/")
        await fetcher.aclose()

    @pytest.mark.parametrize("headers", [{}, {"location": ""}])
    async def test_a_redirect_without_a_usable_location_is_refused(self, headers):
        """A 3xx with no Location reaches the hop step, and is refused there.

        `is_redirect` is a status-code test in httpx -- its Location-aware
        property is `has_redirect_location`, which the hop loop does not use --
        so both a 302 with no Location header at all and one carrying an empty
        `Location` get past the branch above and land here.
        """
        fetcher = make_fetcher(
            {"https://n.test/": lambda r: httpx.Response(302, headers=headers)}
        )
        with pytest.raises(ProviderError, match="without a Location header") as exc:
            await fetcher.fetch("https://n.test/")
        assert not isinstance(exc.value, F.FetchBlocked), headers
        await fetcher.aclose()

    async def test_https_to_http_downgrade_is_refused(self):
        fetcher = make_fetcher(
            {
                "https://s.test/": lambda r: httpx.Response(
                    302, headers={"location": "http://s.test/"}
                )
            }
        )
        with pytest.raises(F.FetchBlocked, match="https to http"):
            await fetcher.fetch("https://s.test/")
        await fetcher.aclose()

    async def test_redirect_to_a_blocked_scheme_is_refused(self):
        fetcher = make_fetcher(
            {
                "https://r.test/": lambda r: httpx.Response(
                    302, headers={"location": "file:///etc/passwd"}
                )
            }
        )
        with pytest.raises(F.FetchBlocked, match="not fetchable"):
            await fetcher.fetch("https://r.test/")
        await fetcher.aclose()

    async def test_redirect_target_is_address_checked(self, stub_dns):
        """The hop matters as much as the first URL.

        The shared httpx client follows redirects automatically; if fetch used it,
        a redirect into link-local space would be followed with no check at all.
        """
        stub_dns("public.test", ["93.184.216.34"])
        stub_dns("evil.test", ["169.254.169.254"])
        fetcher = F.HttpFetcher(extractor=_EXTRACTOR)
        fetcher._client = httpx.AsyncClient(
            transport=httpx.MockTransport(
                lambda r: httpx.Response(
                    302, headers={"location": "https://evil.test/latest/meta-data/"}
                )
            ),
            follow_redirects=False,
        )
        with pytest.raises(F.FetchBlocked, match="non-public"):
            await fetcher.fetch("https://public.test/")
        await fetcher.aclose()

    async def test_a_redirect_target_refusal_is_tagged_as_post_dispatch(
        self, stub_dns
    ):
        """The 400/502 split the REST projection draws reads this tag, so it is
        pinned where it is set: a refusal of the URL *as written* is a
        `UrlBlocked`, a refusal of a redirect target is a `RedirectBlocked`.

        Same two guardrails either way -- the tag is provenance, and it is the
        only thing separating "the caller can choose a different URL" from "we
        sent the request and it failed".
        """
        stub_dns("public.test", ["93.184.216.34"])
        stub_dns("evil.test", ["169.254.169.254"])
        for location in ("https://evil.test/latest/meta-data/", "file:///etc/passwd"):
            fetcher = F.HttpFetcher(extractor=_EXTRACTOR)
            fetcher._client = httpx.AsyncClient(
                transport=httpx.MockTransport(
                    lambda _request, loc=location: httpx.Response(
                        302, headers={"location": loc}
                    )
                ),
                follow_redirects=False,
            )
            with pytest.raises(F.RedirectBlocked) as exc:
                await fetcher.fetch("https://public.test/")
            assert not isinstance(exc.value, F.UrlBlocked), location
            await fetcher.aclose()

    async def test_a_refusal_of_the_written_url_is_not_tagged_post_dispatch(self):
        """The other half of the pair: `validate_url` on hop 0 still raises the
        plain `UrlBlocked`, which is what makes the 400 row reachable."""
        fetcher = make_fetcher({})
        with pytest.raises(F.UrlBlocked) as exc:
            await fetcher.fetch("file:///etc/passwd")
        assert not isinstance(exc.value, F.RedirectBlocked)
        await fetcher.aclose()


class TestBodyHandling:
    async def test_oversized_body_is_capped_while_streaming(self):
        big = b"<html><body><p>" + b"x" * 3_000_000 + b"</p></body></html>"
        fetcher = make_fetcher(
            {
                "https://big.test/": lambda r: httpx.Response(
                    200, content=big, headers={"content-type": "text/html"}
                )
            },
            max_download_bytes=50_000,
        )
        page = await fetcher.fetch("https://big.test/")
        assert page.total_chars <= 60_000, "download must stop at the byte budget"
        await fetcher.aclose()

    async def test_truncated_pdf_says_so_instead_of_looking_corrupt(self):
        """A PDF cut short is unparseable, not merely shorter.

        Its cross-reference table lives at the end of the file, so hitting the
        download cap makes it unreadable. Caught in a real round-trip: a routine
        arXiv paper at 2.2 MB failed against a 2 MiB cap, and the error read as
        "corrupt file" rather than "limit too low".
        """
        fetcher = make_fetcher(
            {
                "https://doc.test/": lambda r: httpx.Response(
                    200,
                    content=b"%PDF-1.4\n" + b"x" * 100_000,
                    headers={"content-type": "application/pdf"},
                )
            },
            max_download_bytes=10_000,
        )
        with pytest.raises(F.FetchBlocked, match="exceeds the .* download limit"):
            await fetcher.fetch("https://doc.test/")
        await fetcher.aclose()

    async def test_a_truncated_json_document_names_the_limit(self):
        """This is about big JSON, and a cut document is the same trap as a cut PDF.

        Cut at the cap it no longer parses, so the caller got 40k characters of
        braces plus a sentence claiming the page was not a JSON document -- the
        opposite of the truth, and with no knob named.
        """
        fetcher = make_fetcher(
            {
                "https://big.test/": lambda r: httpx.Response(
                    200,
                    content=b'{"items": [' + b"1," * 60_000 + b'1]',
                    headers={"content-type": "application/json"},
                )
            },
            max_download_bytes=10_000,
        )
        with pytest.raises(F.FetchBlocked, match="JSON document exceeds the .* cut in the middle"):
            await fetcher.fetch("https://big.test/")
        await fetcher.aclose()

    async def test_a_truncated_record_stream_keeps_its_text(self):
        """A stream is the exception: the records at its head are whole."""
        record = b'{"n": 1}\n'
        fetcher = make_fetcher(
            {
                "https://big.test/": lambda r: httpx.Response(
                    200,
                    content=record * 4000,
                    headers={"content-type": "application/x-ndjson"},
                )
            },
            max_download_bytes=10_000,
        )
        page = await fetcher.fetch("https://big.test/")
        assert page.path_addressable is False
        assert page.total_chars >= 10_000, "the head of the stream is still returned"
        await fetcher.aclose()

    async def test_a_rendered_json_page_says_its_lines_can_be_selected(self):
        """The flag the engine reads is the extraction's, carried through the fetcher."""
        fetcher = make_fetcher(
            {
                "https://doc.test/": lambda r: httpx.Response(
                    200,
                    content=b'{"total": 1, "item": {"name": "a document worth fetching"}}',
                    headers={"content-type": "application/json"},
                )
            }
        )
        page = await fetcher.fetch("https://doc.test/")
        assert page.path_addressable is True
        await fetcher.aclose()

    async def test_page_text_beginning_with_a_dollar_is_not_claimed_as_a_document(self):
        """A Makefile is a normal fetch target on a code host, and its text starts `$ make`."""
        fetcher = make_fetcher(
            {
                "https://code.test/": lambda r: httpx.Response(
                    200,
                    content=b"$ make all\n" + b"# build the thing\n" * 40,
                    headers={"content-type": "text/plain"},
                )
            }
        )
        page = await fetcher.fetch("https://code.test/")
        assert page.text.startswith("$ make all")
        assert page.path_addressable is False
        await fetcher.aclose()

    async def test_a_dense_json_page_costs_its_render_budget_not_its_shape(self):
        """The probe the memory bound was asked for: objects built, not characters printed.

        The shape the issue names -- 99 levels, inside the depth cap,
        with leaves under them -- is served twice here: at its own 400,197 bytes
        with 200k leaves, and scaled to 8,000,197 bytes with 4M, just under the
        default `fetch.max_download_bytes` of 8,388,608. Measured against this fetcher
        and the default backend, that body came through at 2,296 MB of peak
        resident memory, having printed only the four times the body the issue had
        already closed, and the issue attributed the rest to `json.loads`. The
        measurement says otherwise: the same body parses to 32 MB of objects, and
        what cost the gigabytes was the renderer's queue -- one entry and one path
        label per member of every container it had opened, 4M of them, queued
        before the printing budget cut anything. The bound pinned here is
        therefore on objects built on the serving path, at the cap the issue names,
        and it sits with the rendering budget instead of with the document's shape.
        """
        def serving(content: bytes) -> F.HttpFetcher:
            """One route, one body: the mock transport never reads the request."""
            return make_fetcher(
                {
                    "https://dense.test/": lambda r: httpx.Response(
                        200,
                        content=content,
                        headers={"content-type": "application/json"},
                    )
                }
            )

        for leaves, bound_mb in ((200_000, 25), (4_000_000, 250)):
            body = ("[" * 99 + ",".join(["1"] * leaves) + "]" * 99).encode()
            fetcher = serving(body)
            tracemalloc.start()
            try:
                page = await fetcher.fetch("https://dense.test/")
                peak = tracemalloc.get_traced_memory()[1]
            finally:
                tracemalloc.stop()
            await fetcher.aclose()
            assert page.path_addressable, "the bound is not a refusal: the fallback still renders"
            assert page.total_chars == pytest.approx(
                4 * len(body), rel=0.01
            ), "the rendering stays at four times the body"
            assert peak < bound_mb * 1024 * 1024, (
                f"a {len(body) // 1024} KiB JSON page built {peak / 1e6:.0f} MB of "
                f"objects on the serving path; at the default cap the issue measured "
                f"2.2 GB for the scaled shape"
            )

    async def test_unsupported_content_type_is_refused(self):
        fetcher = make_fetcher(
            {
                "https://img.test/": lambda r: httpx.Response(
                    200, content=b"\x89PNG", headers={"content-type": "image/png"}
                )
            }
        )
        with pytest.raises(F.FetchBlocked) as exc:
            await fetcher.fetch("https://img.test/")
        # The phrase is derived from the backend's supported set, so it names
        # what this install can read -- JSON is in the set, and a
        # refusal that left it out would send a caller away from a fetchable type.
        assert "image/png" in str(exc.value)
        assert "this tool reads HTML, plain text, JSON and PDF" in str(exc.value)
        await fetcher.aclose()

    async def test_error_status_is_raised_not_returned_as_content(self):
        """A 404 page's text is noise the model would treat as the article."""
        fetcher = make_fetcher(
            {
                "https://nf.test/": lambda r: httpx.Response(
                    404,
                    content=b"<html><body>Not found</body></html>",
                    headers={"content-type": "text/html"},
                )
            }
        )
        with pytest.raises(ProviderError, match="404"):
            await fetcher.fetch("https://nf.test/")
        await fetcher.aclose()

    async def test_html_is_extracted_with_title(self):
        fetcher = make_fetcher(
            {
                "https://ok.test/": lambda r: httpx.Response(
                    200,
                    content=HTML,
                    headers={"content-type": "text/html; charset=utf-8"},
                )
            }
        )
        page = await fetcher.fetch("https://ok.test/")
        assert page.title == "Doc"
        assert "real body text" in page.text
        assert page.status_code == 200
        await fetcher.aclose()

    async def test_no_provider_credentials_are_sent(self):
        """The fetcher owns its client precisely so this stays true."""
        seen = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen.update(request.headers)
            return httpx.Response(
                200, content=HTML, headers={"content-type": "text/html"}
            )

        fetcher = F.HttpFetcher(extractor=_EXTRACTOR, allow_private_addresses=True)
        fetcher._client = httpx.AsyncClient(
            transport=httpx.MockTransport(handler), follow_redirects=False
        )
        await fetcher.fetch("https://ok.test/")
        assert "authorization" not in seen
        assert "x-api-key" not in seen
        await fetcher.aclose()

class _GrindingExtractor:
    """A backend whose extraction does not return on its own.

    The shape this is about: the bytes are already under the download cap,
    and what the cap cannot bound is how long the parse then runs. `busy=True`
    burns interpreter time the way pypdf does; the default waits on a timer the
    way a parse that has lost the plot does. `stop` releases the thread the
    deadline abandoned, so the suite never waits for a parse it refused.
    """

    name = "grinding"
    supported_types = PDF_TYPES

    def __init__(self, *, seconds: float, busy: bool = False) -> None:
        self._seconds = seconds
        self._busy = busy
        self._stop = False
        self.thread: threading.Thread | None = None

    def stop(self) -> None:
        self._stop = True

    def extract(self, body: bytes, content_type: str | None) -> ExtractResult:
        self.thread = threading.current_thread()
        deadline = time.perf_counter() + self._seconds
        while not self._stop and time.perf_counter() < deadline:
            if self._busy:
                pass
            else:
                time.sleep(0.01)
        return ExtractResult(text="extracted", title=None, total_chars=9)


_IMAGE_BODIES = {
    "image/png": b"\x89PNG\r\n\x1a\n" + b"a png body",
    "image/jpeg": b"\xff\xd8\xff\xe0" + b"a jpeg body",
    "image/gif": b"GIF89a" + b"a gif body",
    "image/webp": b"RIFF\x08\x00\x00\x00WEBP" + b"a webp body",
}
"""One body per admitted image type, each carrying its own signature."""


class TestImages:
    """What `fetch.allow_images` admits, and what it does not.

    The switch is off by default, and the existing refusal test above is what
    that default buys; these are the rules that hold once an operator turns it
    on -- the header has to agree with the bytes, the byte cap holds the way a
    PDF's does, and the type set stays the four MCP names.
    """

    @pytest.mark.parametrize("media_type", sorted(_IMAGE_BODIES))
    async def test_an_image_is_returned_whole_when_the_operator_allowed_it(
        self, media_type
    ):
        body = _IMAGE_BODIES[media_type]
        fetcher = make_fetcher(
            {
                "https://img.test/": lambda r: httpx.Response(
                    200, content=body, headers={"content-type": media_type}
                )
            },
            allow_images=True,
        )
        page = await fetcher.fetch("https://img.test/")
        assert page.image is not None
        assert page.image.media_type == media_type
        assert page.image.body == body
        # No text, no title, nothing truncated: the bytes are the whole resource.
        assert page.text == ""
        assert page.title is None
        assert page.truncated is False
        await fetcher.aclose()

    async def test_a_header_that_lies_about_the_bytes_is_refused(self):
        """The media type is a claim by the party the guard is aimed at.

        The string this server writes into an image block is what the caller's
        decoder trusts, so the bytes have to say the same thing the header did.
        """
        fetcher = make_fetcher(
            {
                "https://img.test/": lambda r: httpx.Response(
                    200,
                    content=b"<html><body>not an image</body></html>",
                    headers={"content-type": "image/png"},
                )
            },
            allow_images=True,
        )
        with pytest.raises(F.FetchBlocked, match="first bytes are not"):
            await fetcher.fetch("https://img.test/")
        await fetcher.aclose()

    async def test_svg_stays_refused_with_the_switch_on(self):
        """An SVG is a document that can carry script, so rendering it executes it."""
        fetcher = make_fetcher(
            {
                "https://img.test/": lambda r: httpx.Response(
                    200,
                    content=b"<svg xmlns=\"http://www.w3.org/2000/svg\"/>",
                    headers={"content-type": "image/svg+xml"},
                )
            },
            allow_images=True,
        )
        with pytest.raises(F.FetchBlocked) as exc:
            await fetcher.fetch("https://img.test/")
        assert "image/svg+xml" in str(exc.value)
        # The switch is not an offer for a type it never admitted.
        assert "allow_images" not in str(exc.value)
        await fetcher.aclose()

    async def test_an_image_cut_at_the_download_cap_is_refused_not_shortened(self):
        """Half a picture is a broken picture, so the PDF rule holds for images."""
        fetcher = make_fetcher(
            {
                "https://img.test/": lambda r: httpx.Response(
                    200,
                    content=_IMAGE_BODIES["image/png"] + b"z" * 100_000,
                    headers={"content-type": "image/png"},
                )
            },
            allow_images=True,
            max_download_bytes=10_000,
        )
        with pytest.raises(F.FetchBlocked, match="image/png image exceeds the .* download limit"):
            await fetcher.fetch("https://img.test/")
        await fetcher.aclose()

    async def test_an_image_of_another_type_is_refused_rather_than_relabelled(self):
        """A GIF served as `image/png` is neither, and the caller cannot tell.

        Trusting the header and re-labelling the bytes would hand a decoder a
        file it was not built for; the refusal is the honest answer.
        """
        fetcher = make_fetcher(
            {
                "https://img.test/": lambda r: httpx.Response(
                    200,
                    content=_IMAGE_BODIES["image/gif"],
                    headers={"content-type": "image/png"},
                )
            },
            allow_images=True,
        )
        with pytest.raises(F.FetchBlocked, match="first bytes are not"):
            await fetcher.fetch("https://img.test/")
        await fetcher.aclose()

    async def test_the_switch_reaches_the_local_fetcher_through_the_factory(self):
        """A key `build_fetch_stack` forgets to pass is a key that does nothing.

        Both halves, because the default is the decision: the same stack built
        from the default config refuses images.
        """
        on = Config(
            providers={"serper": ProviderConfig()}, fetch=FetchConfig(allow_images=True)
        )
        off = Config(providers={"serper": ProviderConfig()})

        allowed, _ = await factory.build_fetch_stack(on)
        refused, _ = await factory.build_fetch_stack(off)
        try:
            assert allowed is not None and refused is not None
            assert allowed._allow_images is True
            assert refused._allow_images is False
        finally:
            for fetcher in (allowed, refused):
                if fetcher is not None:
                    await fetcher.aclose()

    def test_the_signature_table_names_exactly_the_admitted_types(self):
        assert sorted(F.IMAGE_TYPES) == sorted(_IMAGE_BODIES)
        assert (
            F.sniff_image_type(b"<svg xmlns=\"http://www.w3.org/2000/svg\"/>") is None
        )
        # A RIFF container is not yet a WebP; AVI and WAV share the wrapper.
        assert F.sniff_image_type(b"RIFF\x08\x00\x00\x00AVI ") is None


class TestExtractionTime:
    """The guard on parse time, which the download cap cannot provide.

    A cap on bytes is a cap on the input; a mutated PDF under that cap can
    still send pypdf into a CPU loop, and extraction used to run on the event
    loop, where that loop is everyone else's request.
    """

    @staticmethod
    def _pdf_routes(
        url: str, content: bytes
    ) -> dict[str, Callable[[httpx.Request], httpx.Response]]:
        return {
            url: lambda r: httpx.Response(
                200, content=content, headers={"content-type": "application/pdf"}
            )
        }

    async def test_extraction_holds_the_event_loop_open(self):
        """A parse burning CPU must not stall the loop it runs inside."""
        grinder = _GrindingExtractor(seconds=0.5, busy=True)
        fetcher = make_fetcher(
            self._pdf_routes("https://doc.test/", b"%PDF-1.4\nnot a real document\n%%EOF\n"),
            extractor=grinder,
        )
        ticks = 0

        async def ticker() -> None:
            nonlocal ticks
            while True:
                ticks += 1
                await asyncio.sleep(0.01)

        beating = asyncio.create_task(ticker())
        try:
            page = await fetcher.fetch("https://doc.test/")
        finally:
            beating.cancel()
            await fetcher.aclose()

        assert page.text == "extracted"
        assert grinder.thread is not None
        assert grinder.thread is not threading.current_thread(), (
            "extraction still ran on the event loop's own thread"
        )
        # Half a second of another thread's arithmetic is ~50 ticks, so a stalled
        # loop reads near zero.
        assert ticks >= 10, f"the event loop only ticked {ticks} times"

    async def test_a_real_pdf_that_outgrows_its_bytes_is_refused(self):
        """The input class is reachable without a single corrupt byte.

        One large content stream referenced by every page: the file is a few
        hundred kilobytes, so the download cap waves it through, and the parse
        work scales with the page count rather than with the bytes. This is the
        case named above -- parse *time* is a different axis from size --
        run through the real parser rather than through a stand-in.
        """
        grinder_pdf = _shared_stream_pdf(10)
        assert len(grinder_pdf) < 1_000_000, "must stay far under the download cap"
        fetcher = make_fetcher(self._pdf_routes("https://heavy.test/", grinder_pdf), timeout=0.5)
        started = time.perf_counter()
        try:
            with pytest.raises(F.FetchBlocked, match="did not finish within"):
                await fetcher.fetch("https://heavy.test/")
            elapsed = time.perf_counter() - started
        finally:
            await fetcher.aclose()
        # The parse runs ~2s, so the 0.5s deadline decides; the 1.0s chain budget
        # never answers.
        assert 0.45 <= elapsed < 1.0, f"returned in {elapsed:.2f}s"

    async def test_an_overrunning_parse_comes_back_as_a_refusal(self):
        """The refusal is the one `ExtractionFailed` already produces.

        Same non-retryable shape, same `cannot extract text` prefix the REST
        projection already groups with an unreadable body -- a parse that ran
        too long is not a network fault, and the same bytes will run too long
        again.
        """
        grinder = _GrindingExtractor(seconds=5.0)
        # `timeout` is the only bound, the fetcher's per-request budget; the chain
        # budget sits behind it.
        fetcher = make_fetcher(
            self._pdf_routes(
                "https://slow.test/", b"%PDF-1.4\nnot a real document\n%%EOF\n"
            ),
            extractor=grinder,
            timeout=1.0,
        )
        started = time.perf_counter()
        try:
            with pytest.raises(F.FetchBlocked) as exc:
                await fetcher.fetch("https://slow.test/")
        finally:
            grinder.stop()
            await fetcher.aclose()
        elapsed = time.perf_counter() - started

        assert "cannot extract text" in str(exc.value)
        assert "application/pdf" in str(exc.value)
        assert "fetch.timeout_seconds" in str(exc.value)
        assert exc.value.retryable is False
        assert 0.95 <= elapsed < 1.9, (
            f"returned in {elapsed:.2f}s: expected the 1s deadline, not the "
            "5s parse or the 2s chain budget"
        )
