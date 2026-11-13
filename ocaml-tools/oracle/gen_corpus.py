"""Write the corpus inputs under ``test/differential/corpus/``.

Everything the corpus contains is spelled out here in the generator, so the
inputs are reproducible from the tooling alone and a reviewer can read the case
matrix without diffing files one by one. The goldens beside them are written by
``gen_goldens.py``; nothing in this file reads the port or the oracle, so
regenerating the inputs cannot change what a golden pins.

Run: ``python3 ocaml-tools/oracle/gen_corpus.py``
"""

from __future__ import annotations

import json
import pathlib
import re
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parents[2]
CORPUS = ROOT / "test" / "differential" / "corpus"

# {1 config: TOML inputs}

_configuration_doc = (ROOT / "docs" / "reference" / "configuration.md").read_text()
_doc_example = re.findall(r"```toml\n(.*?)```", _configuration_doc, re.DOTALL)[0]
_deploying_doc = (ROOT / "docs" / "reference" / "deploying.md").read_text()
_role_blocks = re.findall(r"### The (search|fetch) role\n+```toml\n(.*?)```", _deploying_doc, re.DOTALL)

_ALL_PROVIDERS = [
    "algolia", "anysearch", "deepseek", "exa", "exa:free", "freeserp", "linkup",
    "parallel", "parallel:free", "querit", "scrappa", "search1api", "searxng",
    "serpapi", "serper", "tavily", "tinyfish",
]


def _all_providers_block() -> str:
    out = []
    for name in _ALL_PROVIDERS:
        table = f'[providers."{name}"]' if ":" in name else f"[providers.{name}]"
        extra = (
            'url = "http://searx.internal:8080"\n'
            if name == "searxng"
            else ('app_id = "A"\nindex = "i"\n' if name == "algolia" else "")
        )
        out.append(f"{table}\nenabled = true\n{extra}")
    return "".join(out)


CONFIG_CASES: dict[str, str] = {
    "01-empty": "",
    "02-policy-only": "[policy]\nmax_snippet_chars = 100\n",
    "03-disabled-provider": "[providers.serper]\nenabled = false\n",
    "04-one-enabled": "[providers.serper]\nenabled = true\n",
    "05-quoted-flavour": '[providers."exa:free"]\nenabled = true\n',
    "06-unquoted-flavour": "[providers.exa:free]\nenabled = true\n",
    "07-unknown-provider": "[providers.serpr]\nenabled = true\n",
    "08-renamed": "[providers.exa_free]\nenabled = true\n",
    "09-searxng-no-url": "[providers.searxng]\nenabled = true\n",
    "10-searxng-url": '[providers.searxng]\nenabled = true\nurl = "http://searx.internal:8080"\n',
    "11-algolia-partial": '[providers.algolia]\nenabled = true\napp_id = "A"\n',
    "12-algolia-full": '[providers.algolia]\nenabled = true\napp_id = "A"\nindex = "i"\n',
    "13-default-not-enabled": '[providers.serper]\nenabled = true\ndefault_provider = "linkup"\n',
    "14-default-single": "[providers.serper]\nenabled = true\n",
    "15-permitted-narrow": 'permitted_providers = ["serper"]\n[providers.serper]\nenabled = true\n[providers.linkup]\nenabled = true\n',
    "16-permitted-empty": 'permitted_providers = []\n[providers.serper]\nenabled = true\n',
    "17-permitted-wildcard": 'permitted_providers = ["*", "kagi"]\n[providers.serper]\nenabled = true\n',
    "18-permitted-dup": 'permitted_providers = ["serper", "serper"]\n[providers.serper]\nenabled = true\n',
    "19-permitted-unknown": 'permitted_providers = ["kagi"]\n[providers.serper]\nenabled = true\n',
    "20-permitted-jina": 'permitted_providers = ["serper", "jina"]\n[providers.serper]\nenabled = true\n',
    "21-search-fb-unknown": '[providers.serper]\nenabled = true\n[search]\nfallback = ["kagi"]\n',
    "22-search-fb-disabled": '[providers.serper]\nenabled = true\n[search]\nfallback = ["linkup"]\n',
    "23-search-free-paid": '[providers.serper]\nenabled = true\n[search]\nfree_fallback = ["tavily"]\n',
    "24-fetch-extractor-bad": '[fetch]\nextractor = "readability"\n',
    "25-fetch-fb-dup": '[fetch]\nfallback = ["crawl4ai", "crawl4ai"]\n',
    "26-fetch-fb-paid-mid": '[fetch]\nfallback = ["scrappa", "crawl4ai"]\n',
    "27-fetch-primary-bad": '[fetch]\nprimary = "kagi"\n',
    "28-fetch-primary-paid": '[fetch]\nprimary = "scrappa"\nfallback = ["crawl4ai", "scrappa"]\n',
    "29-typo-top": "notakey = 1\n",
    "30-typo-policy": "[policy]\nmax_snipet_chars = 50\n",
    "31-typo-fetch": "[fetch]\nmax_text_charts = 100\n",
    "32-typo-logging": '[logging]\nlevl = "DEBUG"\n',
    "33-typo-dashboard": "[dashboard]\nenabledd = true\n",
    "34-typo-provider": "[providers.serper]\nenabledd = true\n",
    "35-removed-key": '[providers.serper]\nenabled = true\n[fetch]\nmax_age_seconds = 1\n',
    "36-knowledge": '[providers.serper]\nenabled = true\n[knowledge]\nenabled = true\n',
    "37-lax-int-str": '[policy]\nmax_snippet_chars = "400"\n',
    "38-lax-bool-yes": '[logging]\nlog_content = "yes"\n',
    "39-lax-float-exp": '[fetch]\ntimeout_seconds = "1e2"\n',
    "40-lax-bool-two": "[logging]\nlog_content = 2\n",
    "41-agent-missing": "[providers.serper]\nenabled = true\n[agent]\nenabled = true\n",
    "42-bad-level": '[logging]\nlevel = "LOUD"\n',
    "43-all-providers": _all_providers_block(),
    "44-empty-providers-table": "[providers]\n",
    "45-default-empty-string": '[providers.serper]\nenabled = true\ndefault_provider = ""\n',
    "46-default-in-ladder": '[providers.serper]\nenabled = true\n[providers.linkup]\nenabled = true\ndefault_provider = "serper"\n[search]\nfallback = ["serper", "linkup"]\n',
    "47-int-from-float": "[policy]\nmax_snippet_chars = 500.0\n",
    "48-bool-for-int": "[policy]\nmax_snippet_chars = true\n",
    "49-doc-example": _doc_example,
}


CONFIG_CASES.update(
    {
        "60-array-of-tables": "[[providers]]\nenabled = true\n",
        "61-permitted-string": 'permitted_providers = "*"\n[providers.serper]\nenabled = true\n',
        "62-fallback-bare-string": '[providers.serper]\nenabled = true\n[search]\nfallback = "serper"\n',
        "63-bool-string-upper": '[providers.serper]\nenabled = "TRUE"\n',
        "64-int-string-frac": '[policy]\nmax_snippet_chars = "1.5"\n',
        "65-fetch-fb-two-free": '[providers.serper]\nenabled = true\n[fetch]\nfallback = ["jina", "crawl4ai"]\n',
        "66-fetch-fb-two-paid": '[providers.serper]\nenabled = true\n[fetch]\nfallback = ["linkup", "scrappa"]\n',
        "67-free-fb-disabled": '[providers.serper]\nenabled = true\n[search]\nfree_fallback = ["exa:free"]\n',
        "68-agent-empty-base": '[providers.serper]\nenabled = true\n[agent]\nenabled = true\nbase_url = ""\nmodel = ""\n',
        "69-default-top": 'default_provider = "linkup"\n[providers.linkup]\nenabled = true\n[providers.serper]\nenabled = true\n',
        "70-level-lower": '[logging]\nlevel = "debug"\n',
        "71-max-cost-zero": "[providers.serper]\nenabled = true\n[agent]\nenabled = true\nmax_cost_usd = 0\n",
        "72-output-type-bad": '[providers.linkup]\nenabled = true\noutput_type = "nope"\n',
        "73-url-int": "[providers.serper]\nenabled = true\nurl = 5\n",
        "74-two-free-flavours": '[providers."exa:free"]\nenabled = true\n[providers."parallel:free"]\nenabled = true\n',
        "75-permitted-all": 'permitted_providers = ["algolia","anysearch","deepseek","exa","exa:free","freeserp","linkup","parallel","parallel:free","querit","scrappa","search1api","searxng","serpapi","serper","serper2","tavily","tinyfish","jina"]\n[providers.serper]\nenabled = true\n',
        "76-negative": "[providers.serper]\nenabled = true\n[policy]\nmax_result_text_chars = -1\n",
        "77-cost-per-1k-str": '[providers.serper]\nenabled = true\ncost_per_1k = "6"\n',
        "78-depth-int": "[providers.linkup]\nenabled = true\ndepth = 5\n",
        "79-fetch-fb-empty": "[fetch]\nfallback = []\n",
        "80-depth-bad": '[providers.linkup]\nenabled = true\ndepth = "deepest"\n',
        "81-fetch-enabled-no-library": '[fetch]\nenabled = true\nextractor = "stdlib"\n',
        "82-agent-paid-default": 'default_provider = "tavily"\n[providers.tavily]\nenabled = true\n[agent]\nenabled = true\nbase_url = "http://model.internal:8000/v1"\nmodel = "small"\n',
    }
)


def write_config(area: str) -> None:
    directory = CORPUS / area
    directory.mkdir(parents=True, exist_ok=True)
    for name, body in CONFIG_CASES.items():
        (directory / (name + ".toml")).write_text(body)
    for index, (role, body) in enumerate(_role_blocks):
        (directory / f"9{index}-role-{role}.toml").write_text(body)


# {2 sanitize: the file *is* the text (raw bytes; UTF-8 when it can be)}

SANITIZE_CASES: dict[str, bytes] = {
    "01-empty": b"",
    "02-plain": b"a plain query about mercury",
    "03-endoftext": b"a<|endoftext|>b",
    "04-chatml": b"[INST] hi [/INST] <|im_start|>user",
    "05-two-tokens": b"<|im_end|><|im_end|>",
    "06-already-escaped": "a<\u200b|endoftext|>b".encode(),
    "07-only-zwsp": "\u200b\u200b".encode(),
    "08-wide-chars": "caf\u00e9 \U0001f600 r\u00e9sum\u00e9".encode(),
    "09-lone-continuation": b"\x80abc<|endoftext|>",
    "10-angle-no-token": b"a < | endoftext | > b",
    "11-controls": b"tab\there\nnewline",
    "12-nested": b"<<|x|>|> <|prompt|>",
}


def write_sanitize(area: str) -> None:
    directory = CORPUS / area
    directory.mkdir(parents=True, exist_ok=True)
    for name, body in SANITIZE_CASES.items():
        (directory / (name + ".txt")).write_bytes(body)


def spec_json(spec: dict[str, Any]) -> str:
    return json.dumps(spec, indent=2, ensure_ascii=True) + "\n"


def write_specs(area: str, cases: dict[str, dict[str, Any]]) -> None:
    directory = CORPUS / area
    directory.mkdir(parents=True, exist_ok=True)
    for name, spec in cases.items():
        (directory / (name + ".json")).write_text(spec_json(spec))


# {3 fetch: URL shape, windowing, image sniffing, caps}

FETCH_CASES: dict[str, dict[str, Any]] = {
    "01-url-plain": {"op": "url", "url": "https://example.com/a?b=1#c"},
    "02-url-uppercase-scheme": {"op": "url", "url": "HTTPS://Example.COM/Path"},
    "03-url-bare-host": {"op": "url", "url": "https://example.com"},
    "04-url-no-scheme": {"op": "url", "url": "example.com/a"},
    "05-url-ftp": {"op": "url", "url": "ftp://example.com/a"},
    "06-url-credentials": {"op": "url", "url": "http://user:pass@example.com/"},
    "07-url-port-zero": {"op": "url", "url": "http://example.com:0/"},
    "08-url-port-range": {"op": "url", "url": "http://example.com:99999/"},
    "09-url-port-word": {"op": "url", "url": "http://example.com:notaport/"},
    "10-url-no-host": {"op": "url", "url": "http://"},
    "11-url-ipv6": {"op": "url", "url": "http://[::1]:8080/x"},
    "12-url-ipv6-broken": {"op": "url", "url": "http://[::1/x"},
    "13-url-ipv6-zone": {"op": "url", "url": "http://[fe80::1%eth0]/"},
    "14-url-space-padded": {"op": "url", "url": "  https://example.com/  "},
    "15-window-head": {"op": "window", "text": "hello world", "offset": 0, "max_chars": 5},
    "16-window-middle": {"op": "window", "text": "hello world", "offset": 4, "max_chars": 5},
    "17-window-exact": {"op": "window", "text": "hello", "offset": 0, "max_chars": 5},
    "18-window-past-end": {"op": "window", "text": "hello", "offset": 7, "max_chars": 5},
    "19-window-zero": {"op": "window", "text": "hello", "offset": 0, "max_chars": 0},
    "20-window-unicode": {"op": "window", "text": "caf\u00e9 \U0001f600 caf\u00e9", "offset": 4, "max_chars": 3},
    "21-sniff-png": {"op": "sniff", "hex": "89504e470d0a1a0a0000000d49484452"},
    "22-sniff-jpeg": {"op": "sniff", "hex": "ffd8ffe000104a464946"},
    "23-sniff-gif": {"op": "sniff", "hex": "4749463839612c0000"},
    "24-sniff-webp": {"op": "sniff", "hex": "524946462c00000057454250564c58"},
    "25-sniff-pdf": {"op": "sniff", "hex": "255044462d312e34"},
    "26-sniff-truncated": {"op": "sniff", "hex": "89504e"},
    "27-sniff-empty": {"op": "sniff", "hex": ""},
    "28-cap-default": {"op": "cap", "default": 4000, "max_chars": None},
    "29-cap-requested": {"op": "cap", "default": 4000, "max_chars": 100},
    "30-cap-zero": {"op": "cap", "default": 4000, "max_chars": 0},
    "31-cap-uncapped": {"op": "cap", "default": 4000, "max_chars": 2147483647},
}

# {4 jsondoc: render, structure, select, path grammar, media}

JSONDOC_CASES: dict[str, dict[str, Any]] = {
    "01-render-object": {
        "op": "render",
        "body": '{"items": [{"name": "one", "score": 1.5}, {"name": "two", "score": null}], "count": 2}',
    },
    "02-render-array": {"op": "render", "body": "[1, 2, 3]"},
    "03-render-invalid": {"op": "render", "body": "not json at all"},
    "04-render-empty": {"op": "render", "body": ""},
    "05-render-nested": {
        "op": "render",
        "body": '{"a": {"b": {"c": [true, false, {"d": "deep"}]}}}',
    },
    "06-structure-shapes": {
        "op": "structure",
        "body": '{"rows": [{"id": 1, "ok": true}, {"id": 2, "ok": false}], "meta": {"n": 2}}',
    },
    "07-structure-invalid": {"op": "structure", "body": "{oops"},
    "08-select-subtree": {
        "op": "select",
        "body": '{"items": [{"name": "one"}, {"name": "two"}]}',
        "path": "$.items[*].name",
        "max_chars": 2000,
    },
    "09-select-budget": {
        "op": "select",
        "body": '{"items": [{"name": "aaaaaaaaaa"}, {"name": "bbbbbbbbbb"}]}',
        "path": "$.items[*]",
        "max_chars": 40,
    },
    "10-select-bad-path": {
        "op": "select",
        "body": '{"a": 1}',
        "path": "$.a[",
        "max_chars": 100,
    },
    "11-select-quoted-key": {
        "op": "select",
        "body": '{"odd key": {"x": 1}}',
        "path": '$."odd key".x',
        "max_chars": 100,
    },
    "12-select-bounds": {
        "op": "select",
        "body": '{"xs": [1, 2, 3, 4, 5]}',
        "path": "$.xs[1:3]",
        "max_chars": 100,
    },
    "13-parse-path-full": {"op": "parse-path", "path": "$.a[2].b[*][1:3]"},
    "14-parse-path-bad": {"op": "parse-path", "path": "a.b"},
    "15-parse-path-root": {"op": "parse-path", "path": "$"},
    "16-parse-path-every-bad": {"op": "parse-path", "path": "$[*][*].a"},
    "17-child-name": {"op": "child-path", "parent": "$.rows", "key": "name"},
    "18-child-ordinal": {"op": "child-path", "parent": "$.rows", "key": 3},
    "19-media-types": {"op": "media", "type": "application/json"},
    "20-media-vendor": {"op": "media", "type": "application/vnd.api+json"},
    "21-media-html": {"op": "media", "type": "text/html"},
    "22-sniffs-object": {"op": "sniffs-json", "body": "  {\"a\": 1}"},
    "23-sniffs-prose": {"op": "sniffs-json", "body": "<html><body>hi"},
}


# {5 tabledoc: media, delimiter sniffing, rendering}

TABLEDOC_CASES: dict[str, dict[str, Any]] = {
    "01-csv-basic": {"op": "render", "media": "text/csv", "body": "name,score\none,1\ntwo,2\n"},
    "02-tsv": {"op": "render", "media": "text/tab-separated-values", "body": "name\tscore\none\t1\n"},
    "03-csv-semicolon": {"op": "render", "media": "text/csv", "body": "name;score\none;1\ntwo;2\n"},
    "04-csv-quoted": {"op": "render", "media": "text/csv", "body": 'name,note\n"one, two","say ""hi"""\n'},
    "05-csv-ragged": {"op": "render", "media": "text/csv", "body": "a,b,c\n1,2\n3,4,5,6\n"},
    "06-csv-empty": {"op": "render", "media": "text/csv", "body": ""},
    "07-csv-header-only": {"op": "render", "media": "text/csv", "body": "a,b\n"},
    "08-media-text": {"op": "render", "media": "text/plain", "body": "a,b\n1,2\n"},
}

# {6 router: the decisions, over frozen tables}

ROUTER_CASES: dict[str, dict[str, Any]] = {
    "01-search-paid-default": {
        "table": {
            "providers": ["serper", "linkup", "exa:free"],
            "default": "serper",
            "permitted": None,
            "fallback": ["linkup", "exa:free"],
            "free_fallback": [],
            "free": ["exa:free", "freeserp", "parallel:free", "anysearch"],
            "free_order": ["exa:free", "parallel:free", "freeserp", "anysearch"],
            "effective": ["serper", "linkup", "exa:free"],
        },
        "calls": [
            {"fn": "resolve_search"},
            {"fn": "resolve_search", "requested": "linkup"},
            {"fn": "resolve_search", "requested": "kagi"},
            {"fn": "resolve_search", "mode": "free"},
            {"fn": "is_permitted", "name": "exa:free"},
            {"fn": "unnamed_walks_free"},
            {"fn": "free_candidates"},
            {"fn": "free_walk"},
        ],
    },
    "02-search-permitted-narrow": {
        "table": {
            "providers": ["serper", "linkup"],
            "default": "serper",
            "permitted": ["linkup"],
            "fallback": ["linkup"],
            "free_fallback": [],
            "free": ["exa:free", "freeserp", "parallel:free", "anysearch"],
            "free_order": ["exa:free", "parallel:free", "freeserp", "anysearch"],
            "effective": ["linkup"],
        },
        "calls": [
            {"fn": "resolve_search"},
            {"fn": "resolve_search", "requested": "serper"},
            {"fn": "is_permitted", "name": "serper"},
            {"fn": "unnamed_walks_free"},
            {"fn": "free_candidates"},
        ],
    },
    "03-search-rungs-and-sentences": {
        "table": {
            "providers": ["serper", "linkup", "tavily", "exa:free"],
            "default": "serper",
            "permitted": ["serper", "linkup", "exa:free"],
            "fallback": ["linkup", "tavily", "exa:free"],
            "free_fallback": ["exa:free"],
            "free": ["exa:free", "freeserp", "parallel:free", "anysearch"],
            "free_order": ["exa:free", "parallel:free", "freeserp", "anysearch"],
            "effective": ["serper", "linkup", "exa:free"],
        },
        "calls": [
            {"fn": "fallback_rungs", "ladder": ["linkup", "tavily", "exa:free"], "tried": "serper", "gated": ["tavily"]},
            {"fn": "fallback_rungs", "ladder": ["serper", "linkup"], "tried": "serper", "gated": []},
            {
                "fn": "fallback_served_notice",
                "tried": "serper",
                "original_reason": "serper: upstream timed out",
                "fallback": "linkup",
                "notice": None,
            },
            {
                "fn": "fallback_served_notice",
                "tried": "serper",
                "original_reason": "serper: rate limited",
                "fallback": "linkup",
                "notice": "linkup: partial results",
            },
            {"fn": "fallback_exhausted_note", "failed": ["serper", "linkup"], "mode": None},
            {"fn": "fallback_exhausted_note", "failed": ["exa:free"], "mode": "free"},
            {"fn": "retry_advice", "quota": False},
            {"fn": "retry_advice", "quota": True},
        ],
    },
    "04-search-all-free": {
        "table": {
            "providers": ["exa:free", "parallel:free", "freeserp"],
            "default": None,
            "permitted": None,
            "fallback": [],
            "free_fallback": ["parallel:free", "exa:free"],
            "free": ["exa:free", "freeserp", "parallel:free", "anysearch"],
            "free_order": ["exa:free", "parallel:free", "freeserp", "anysearch"],
            "effective": ["exa:free", "parallel:free", "freeserp"],
        },
        "calls": [
            {"fn": "unnamed_walks_free"},
            {"fn": "free_walk"},
            {"fn": "resolve_search"},
        ],
    },
    "05-fetch-local": {
        "table": {"built": ["jina", "scrappa"], "primary": None},
        "calls": [
            {"fn": "fetch_walk"},
            {"fn": "origin"},
            {"fn": "provider_names"},
            {"fn": "choose_names"},
            {"fn": "choose_instead"},
            {"fn": "empty_notice", "walked": False},
            {"fn": "empty_notice", "walked": True},
            {"fn": "refetched_notice", "reason": "the page needs javascript", "fallback": "jina"},
            {"fn": "not_enabled", "requested": "crawl4ai"},
            {"fn": "resolve_fetch", "requested": None},
            {"fn": "resolve_fetch", "requested": "jina"},
            {"fn": "resolve_fetch", "requested": "nope"},
        ],
    },
    "06-fetch-primary": {
        "table": {"built": ["jina", "scrappa"], "primary": "jina"},
        "calls": [
            {"fn": "fetch_walk"},
            {"fn": "origin"},
            {"fn": "choose_instead"},
            {"fn": "resolve_fetch", "requested": None},
        ],
    },
}


# {7 model: decode/accept verdicts and the re-encoded wire object}

MODEL_CASES: dict[str, dict[str, Any]] = {
    "01-model-result": {
        "cases": [
            {"model": "result", "body": {"title": "One", "url": "https://e.com/1", "snippet": "first hit"}},
            {"model": "result", "body": {"url": "https://e.com/1", "snippet": "no title"}},
            {
                "model": "result",
                "body": {"title": "Two", "url": "https://e.com/2", "text": "a page extract", "text_truncated": True},
            },
            {"model": "result", "body": {"title": "X", "url": "https://e.com", "extra": 1}},
            {"model": "result", "body": {"title": "S", "url": "https://e.com", "score": "0.5"}},
            {"model": "result", "body": {"title": "N", "url": "https://e.com", "snippet": None}},
            {
                "model": "result",
                "body": {"title": "caf\u00e9 \U0001f600 <|endoftext|>", "url": "https://e.com/3", "score": 0.25},
            },
        ]
    },
    "02-model-search-response": {
        "cases": [
            {"model": "search_response", "body": {"query": "q", "provider": "serper", "results": []}},
            {
                "model": "search_response",
                "body": {
                    "query": "q",
                    "provider": "linkup",
                    "results": [{"title": "T", "url": "https://e.com"}],
                    "notice": "linkup: partial results",
                },
            },
            {"model": "search_response", "body": {"query": "q", "provider": "serper"}},
        ]
    },
    "03-model-fetch-response": {
        "cases": [
            {"model": "fetch_response", "body": {"url": "https://e.com/", "requested_url": "https://e.com"}},
            {
                "model": "fetch_response",
                "body": {
                    "url": "https://e.com/",
                    "requested_url": "https://e.com",
                    "title": "Page",
                    "text": "body text",
                    "content_type": "text/html",
                    "status_code": 200,
                    "truncated": True,
                    "total_chars": 90000,
                    "matches": [{"offset": 10, "text": "body"}],
                    "image": {"byte_count": 4, "base64": "aGVsbG8="},
                },
            },
            {"model": "fetch_response", "body": {"url": "https://e.com/", "requested_url": "https://e.com", "status_code": "200"}},
            {"model": "fetch_match", "body": {"offset": 3, "text": "span"}},
            {"model": "fetch_image", "body": {"byte_count": 2, "base64": "aGk="}},
        ]
    },
    "04-model-requests": {
        "cases": [
            {"model": "search_request", "body": {"query": "weather in paris", "max_results": 10, "recency": "week"}},
            {"model": "search_request", "body": {"query": "hi", "max_results": 21}},
            {"model": "search_request", "body": {"query": "h"}},
            {"model": "search_request", "body": {"query": "ok query", "mode": "free", "safe_search": True}},
            {"model": "fetch_request", "body": {"url": "https://example.com/page"}},
            {"model": "fetch_request", "body": {"url": "http://a.b"}},
            {"model": "answer_request", "body": {"query": "why is the sky blue", "depth": "report", "extra_queries": ["sky rayleigh"]}},
            {"model": "answer_request", "body": {"query": "why", "depth": "essay"}},
        ]
    },
    "05-model-answer-and-registry": {
        "cases": [
            {
                "model": "answer_response",
                "body": {
                    "query": "q",
                    "answer": "prose",
                    "sources": [{"title": "T", "url": "https://e.com", "provider": "exa:free"}],
                    "model": "small",
                    "depth": "brief",
                    "searches": 1,
                    "fetched": 0,
                },
            },
            {"model": "answer_source", "body": {"title": "T", "url": "https://e.com", "provider": "exa"}},
            {"model": "answer_source", "body": {"title": "T", "url": "https://e.com"}},
            {"model": "search_query", "body": {"query": "hello world"}},
            {
                "model": "search_query",
                "body": {"query": "hello", "max_results": 3, "include_domains": ["example.com"], "recency": "day"},
            },
            {
                "model": "provider_result",
                "body": {"provider": "exa", "results": [{"title": "T", "url": "https://e.com"}], "cost_usd": 0.0025},
            },
        ]
    },
}


# {8 engine: the search walk over scripted providers}

_ENGINE_RESULT = {
    "ok": {"title": "Hit", "url": "https://e.com/1", "snippet": "first hit"},
    "ok2": {"title": "Second", "url": "https://e.com/2", "snippet": "another hit"},
}

ENGINE_CASES: dict[str, dict[str, Any]] = {
    "01-default-walk": {
        "config": {
            "providers": {"serper": {"enabled": True}, "linkup": {"enabled": True}},
            "default_provider": "serper",
            "search": {"fallback": ["linkup"]},
        },
        "providers": [
            {"name": "serper", "kind": "failure", "message": "upstream timed out", "retryable": True},
            {"name": "linkup", "results": [_ENGINE_RESULT["ok"]]},
        ],
        "calls": [{"query": "weather in paris"}],
    },
    "02-named-terminal": {
        "config": {
            "providers": {"serper": {"enabled": True}, "linkup": {"enabled": True}},
            "default_provider": "serper",
            "search": {"fallback": ["linkup"]},
        },
        "providers": [
            {"name": "serper", "kind": "failure", "message": "upstream timed out", "retryable": True},
            {"name": "linkup", "results": [_ENGINE_RESULT["ok"]]},
        ],
        "calls": [{"query": "weather in paris", "provider": "serper"}],
    },
    "03-quota-and-notice": {
        "config": {
            "providers": {"tavily": {"enabled": True}, "linkup": {"enabled": True}},
            "default_provider": "tavily",
            "search": {"fallback": ["linkup"]},
        },
        "providers": [
            {"name": "tavily", "kind": "quota", "message": "quota exhausted"},
            {"name": "linkup", "results": [_ENGINE_RESULT["ok"]], "notice": "linkup: partial results"},
        ],
        "calls": [{"query": "quotation of the day"}],
    },
    "04-free-mode-paid-default": {
        "config": {
            "providers": {"exa": {"enabled": True}, "exa:free": {"enabled": True}},
            "default_provider": "exa",
        },
        "providers": [
            {"name": "exa", "results": [_ENGINE_RESULT["ok"]], "cost": 2.5},
            {"name": "exa:free", "results": [_ENGINE_RESULT["ok2"]]},
        ],
        "calls": [{"query": "mercury retrograde", "mode": "free"}],
    },
    "05-all-free-unnamed": {
        "config": {
            "providers": {"exa:free": {"enabled": True}, "parallel:free": {"enabled": True}},
            "search": {"free_fallback": ["exa:free", "parallel:free"]},
        },
        "providers": [
            {"name": "exa:free", "kind": "quota", "message": "quota exhausted"},
            {"name": "parallel:free", "results": [_ENGINE_RESULT["ok2"]]},
        ],
        "calls": [{"query": "free things to do in vienna"}],
    },
    "06-health-repeat": {
        "config": {
            "providers": {"serper": {"enabled": True}, "exa:free": {"enabled": True}},
            "default_provider": "serper",
            "search": {"fallback": ["exa:free"]},
        },
        "providers": [
            {"name": "serper", "kind": "failure", "message": "bad gateway", "retryable": True},
            {"name": "exa:free", "results": [_ENGINE_RESULT["ok"]]},
        ],
        "calls": [{"query": "first call"}, {"query": "second call"}],
    },
    "07-refused-unknown-name": {
        "config": {
            "providers": {"serper": {"enabled": True}},
            "default_provider": "serper",
        },
        "providers": [{"name": "serper", "results": [_ENGINE_RESULT["ok"]]}],
        "calls": [{"query": "unconfigured", "provider": "kagi"}],
    },
    "08-zero-results": {
        "config": {
            "providers": {"serper": {"enabled": True}},
            "default_provider": "serper",
        },
        "providers": [{"name": "serper", "results": []}],
        "calls": [{"query": "xkcdqzj name nobody searches"}],
    },
}


def main() -> None:
    write_config("config")
    write_sanitize("sanitize")
    write_specs("fetch", FETCH_CASES)
    write_specs("jsondoc", JSONDOC_CASES)
    write_specs("tabledoc", TABLEDOC_CASES)
    write_specs("router", ROUTER_CASES)
    write_specs("model", MODEL_CASES)
    write_specs("engine", ENGINE_CASES)
    total = sum(1 for path in CORPUS.rglob("*") if path.is_file())
    print(f"corpus written: {total} inputs under {CORPUS}")


if __name__ == "__main__":
    main()
