"""Escaping model special-token literals: the rule, its two passes, the boundary.

A scraped GitHub issue that quoted ``<|endoftext|>`` was embedded verbatim
into a model prompt, and an open-weight backend rejected the whole request.
The escape -- a U+200B after the opening delimiter of every such
literal -- is tested the way it is applied, in its three homes:

- ``sanitize_text`` -- the rule itself: the incident string, the shapes it
  covers, the false-positive canon it must leave untouched, and the
  idempotence that keeps caches and re-reads sound;
- ``sanitize_model`` -- the engines' pass over a response object, which is
  where the hit count reaches the decision line;
- the serialization boundary -- the ``WireModel`` pass every response dump
  goes through, which has to hold for a response built by a path that never
  touched an engine (a future tool, a cache layer).
"""

from seekwright.models import (
    AnswerResponse,
    AnswerSource,
    FetchMatch,
    FetchResponse,
    Result,
    SearchResponse,
)
from seekwright.sanitize import ZWSP, sanitize_model, sanitize_text


class TestSanitizeText:
    """The rule itself, and the canon of text it must not touch."""

    def test_the_incident_string(self):
        out, n = sanitize_text(
            "Encountered text corresponding to disallowed special token '<|endoftext|>'."
        )
        assert n == 1
        assert out == (
            "Encountered text corresponding to disallowed special token "
            f"'<{ZWSP}|endoftext|>'."
        )

    def test_the_escape_is_idempotent(self):
        """The property that makes cache re-reads safe: nothing to re-escape."""
        once, n = sanitize_text("<|im_start|>user<|im_end|>")
        assert n == 2
        twice, n2 = sanitize_text(once)
        assert n2 == 0
        assert twice == once

    def test_the_angle_shapes(self):
        # ChatML / Qwen / GLM / Mistral / Phi / GPT-OSS / Llama-3, and
        # DeepSeek's fullwidth spelling of the same shape.
        assert sanitize_text("<｜end▁of▁sentence｜>")[1] == 1
        assert sanitize_text("<|im_start|>system<|im_end|>")[1] == 2

    def test_the_literal_markers(self):
        assert sanitize_text("[INST] hi <<SYS>> x [/INST]")[1] == 3
        assert sanitize_text("<start_of_turn>model<end_of_turn>")[1] == 2

    def test_the_false_positive_canon_is_untouched(self):
        for s in [
            "<s>strike</s>",
            "<think>x</think>",
            "0 < |x| < 1",
            "a < b && c > d",
            "<|endoftext is unterminated",
            "",
        ]:
            assert sanitize_text(s) == (s, 0), s

    def test_the_count_counts_every_literal(self):
        out, n = sanitize_text("<|a|> and [INST] and <start_of_turn>")
        assert n == 3
        # Reversible: dropping the escapes restores the source byte for byte.
        assert out.replace(ZWSP, "") == "<|a|> and [INST] and <start_of_turn>"

    def test_text_without_delimiters_is_returned_unscanned(self):
        s = "nothing structural here"
        assert sanitize_text(s) == (s, 0)
        assert sanitize_text(s)[0] is s


class TestSanitizeModel:
    """The engines' pass: every text-bearing field of a response, in place."""

    def test_a_search_response_walks_results_and_answer(self):
        response = SearchResponse(
            query="how do I quote <|endoftext|>",
            provider="fakeserp",
            results=[
                Result(
                    title="a title with <start_of_turn>",
                    url="https://e.com/tokens",
                    snippet="[INST] a snippet",
                    text=None,
                ),
                Result(
                    title="plain",
                    url="https://e.com/plain",
                    snippet=None,
                    text="text with <|im_end|>",
                ),
            ],
            answer="an answer quoting <<SYS>>",
        )
        assert sanitize_model(response) == 4
        assert response.results[0].title == f"a title with <{ZWSP}start_of_turn>"
        assert response.results[0].snippet == f"[{ZWSP}INST] a snippet"
        assert response.results[1].text == f"text with <{ZWSP}|im_end|>"
        assert response.answer == f"an answer quoting <{ZWSP}<SYS>>"

    def test_the_callers_own_strings_are_not_escaped(self):
        """``query`` and ``url`` are not web text; escaping them would be a lie."""
        response = SearchResponse(
            query="how do I quote <|endoftext|>",
            provider="fakeserp",
            results=[
                Result(
                    title="t",
                    url="https://e.com/?q=<|endoftext|>",
                    text="body",
                )
            ],
        )
        assert sanitize_model(response) == 0
        assert response.query == "how do I quote <|endoftext|>"
        assert response.results[0].url == "https://e.com/?q=<|endoftext|>"

    def test_fetch_and_answer_shapes_recurse_into_their_lists(self):
        fetch = FetchResponse(
            url="https://e.com",
            requested_url="https://e.com",
            title="a title with <end_of_turn>",
            matches=[
                FetchMatch(offset=0, text="[INST] a passage"),
                FetchMatch(offset=10, text="a plain passage"),
            ],
        )
        assert sanitize_model(fetch) == 2
        assert fetch.title == f"a title with <{ZWSP}end_of_turn>"
        matches = fetch.matches
        assert matches is not None
        assert matches[0].text == f"[{ZWSP}INST] a passage"
        assert matches[1].text == "a plain passage"

        answer = AnswerResponse(
            query="q",
            answer="prose with <|eom|>",
            sources=[
                AnswerSource(title="a source with <<SYS>>", url="https://e.com", provider="p"),
                AnswerSource(title="plain", url="https://e.com/2", provider="p"),
            ],
            model="m",
            depth="brief",
            searches=1,
            fetched=0,
        )
        assert sanitize_model(answer) == 2
        assert answer.answer == f"prose with <{ZWSP}|eom|>"
        assert answer.sources[0].title == f"a source with <{ZWSP}<SYS>>"

    def test_a_clean_response_counts_zero(self):
        response = SearchResponse(
            query="q",
            provider="fakeserp",
            results=[Result(title="t", url="https://e.com", snippet="s")],
        )
        assert sanitize_model(response) == 0


class TestSerializationBoundary:
    """The WireModel pass: the one choke point every response dump goes through."""

    def test_a_response_bypassing_the_engines_escapes_on_dump(self):
        """No engine in the path: the boundary alone has to make it safe."""
        response = SearchResponse(
            query="q",
            provider="p",
            results=[
                Result(
                    title="t",
                    url="https://e.com",
                    text="x <|endoftext|> y [INST] z",
                )
            ],
            answer="an <|im_end|>",
        )
        dumped = response.model_dump(mode="json")
        assert dumped["results"][0]["text"] == f"x <{ZWSP}|endoftext|> y [{ZWSP}INST] z"
        assert dumped["answer"] == f"an <{ZWSP}|im_end|>"

    def test_python_mode_dumps_escape_the_same(self):
        response = SearchResponse(
            query="q",
            provider="p",
            results=[Result(title="t", url="https://e.com", text="a <|im_start|> b")],
        )
        dumped = response.model_dump()
        assert dumped["results"][0]["text"] == f"a <{ZWSP}|im_start|> b"

    def test_a_leaf_model_escapes_its_own_fields(self):
        """Nested models run the same pass on themselves: no drift by depth."""
        assert FetchMatch(offset=0, text="[INST] x").model_dump()["text"] == (
            f"[{ZWSP}INST] x"
        )

    def test_a_cached_response_reread_escapes_once(self):
        """What a cache stores is the dump; re-serving it must change nothing."""
        response = SearchResponse(
            query="q",
            provider="p",
            results=[Result(title="t", url="https://e.com", text="raw <|im_start|> raw")],
        )
        first = response.model_dump(mode="json")
        reread = SearchResponse.model_validate(first)
        assert reread.model_dump(mode="json") == first


# The incident payload pinned verbatim: the scraped field that killed an agent turn.
# https://github.com/open-webui/open-webui/issues/27094, body as of 2026-10-18.
GOLDEN_INCIDENT_TEXT = """## Bug Description

When the RAG text splitter is configured to `token`, fetching web pages that contain the literal string `<|endoftext|>` (e.g. in scraped documentation, code examples, or dataset pages) causes an unhandled exception and the request silently fails with no response.

## Steps to Reproduce

1. Go to **Admin Panel → Documents → Text Splitter** and set it to `token`
2. Start a chat with a model that has web search enabled
3. Ask a question that causes Open WebUI to fetch a page containing the literal text `<|endoftext|>` (common on ML/AI documentation and dataset pages)
4. Observe the error — no response is returned

## Error Message

```
Encountered text corresponding to disallowed special token '<|endoftext|>'.
If you want this text to be encoded as a special token, pass it to `allowed_special`,
e.g. `allowed_special={'<|endoftext|>', ...}`.
If you want this text to be encoded as normal text, disable the check for this token by
passing `disallowed_special=(enc.special_tokens_set - {'<|endoftext|>'})`.
To disable this check for all special tokens, pass `disallowed_special=()`.
```

## Root Cause

In `backend/open_webui/routers/retrieval.py`, `TokenTextSplitter` (from LangChain) is instantiated without `allowed_special`, so tiktoken uses its default strict mode and raises a `ValueError` when it encounters any special token literal in the content being chunked.

The length function on line 1585 already correctly passes `disallowed_special=()`, but the `TokenTextSplitter` on line 1687 does not:

```python
# Line 1584-1585 — CORRECT, already safe:
encoding = tiktoken.get_encoding(str(config.TIKTOKEN_ENCODING_NAME))
return lambda text: len(encoding.encode(text, disallowed_special=()))

# Line 1687-1692 — BUG, missing allowed_special:
text_splitter = TokenTextSplitter(
    encoding_name=str(config.TIKTOKEN_ENCODING_NAME),
    chunk_size=config.CHUNK_SIZE,
    chunk_overlap=config.CHUNK_OVERLAP,
    add_start_index=True,
    # ← no allowed_special here, tiktoken will crash on <|endoftext|> etc.
)
```

## Proposed Fix

Pass `allowed_special="all"` to `TokenTextSplitter` so special token literals in web content are treated as plain text, consistent with how the length function is already handled:

```python
text_splitter = TokenTextSplitter(
    encoding_name=str(config.TIKTOKEN_ENCODING_NAME),
    chunk_size=config.CHUNK_SIZE,
    chunk_overlap=config.CHUNK_OVERLAP,
    add_start_index=True,
    allowed_special="all",
)
```

## Workaround

Set the RAG Text Splitter back to the default (`character`) in **Admin Panel → Documents**. This avoids `TokenTextSplitter` entirely and the crash does not occur.

## Environment

- **Branch:** `dev`
- **File:** `backend/open_webui/routers/retrieval.py`
- **Affected setting:** RAG Text Splitter = `token`
- **Trigger:** Any web fetch returning a page with `<|endoftext|>` in its content"""


class TestGoldenIncidentPayload:
    """The payload behind the incident, through the full boundary."""

    def test_the_payload_escapes_completely(self):
        out, n = sanitize_text(GOLDEN_INCIDENT_TEXT)
        assert n == 7
        assert "<|endoftext|>" not in out
        # The exact line the backend rejected, as it now leaves the proxy:
        assert f"disallowed special token '<{ZWSP}|endoftext|>'." in out

    def test_the_payload_travels_the_boundary_and_back(self):
        response = SearchResponse(
            query="tiktoken special tokens",
            provider="freeserp",
            results=[
                Result(
                    title="open-webui #27094",
                    url="https://github.com/open-webui/open-webui/issues/27094",
                    text=GOLDEN_INCIDENT_TEXT,
                )
            ],
        )
        dumped = response.model_dump(mode="json")
        served = dumped["results"][0]["text"]
        assert "<|endoftext|>" not in served
        assert served.count(ZWSP) == 7
        # A cache re-reading what it stored serves the bytes unchanged.
        assert SearchResponse.model_validate(dumped).model_dump(mode="json") == dumped
        # And dropping the escapes restores the page byte for byte.
        assert served.replace(ZWSP, "") == GOLDEN_INCIDENT_TEXT
