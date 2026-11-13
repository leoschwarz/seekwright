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
        # Whitespace is transport here too: a CRLF checkout, a tab indent and a
        # bare `enabled=true` are the same table, and a TOML file written by a
        # Windows editor is a deployment this project has to accept.
        "83-crlf-and-tabs": '[providers.serper]\r\n\tenabled = true\r\n[policy]\r\n\tmax_snippet_chars = 250\r\n',
        "84-whitespace-around-dot": "[ providers . serper ]\nenabled = true\n",
        # Integers at the edge of an OCaml [int] and past it: the port must
        # refuse an overflow as a value it cannot hold, never raise through the
        # config loader, and the number spellings a TOML file may legally use
        # (underscores, hex, a leading plus) have to read as the same integer.
        "85-int-int63-max": "[policy]\nmax_snippet_chars = 4611686018427387903\n",
        "86-int-past-int63": "[policy]\nmax_snippet_chars = 4611686018427387904\n",
        "87-int-huge": "[policy]\nmax_snippet_chars = 1180591620717411303424\n",
        "88-int-underscores": "[policy]\nmax_snippet_chars = 1_000\n",
        "89-int-hex": "[policy]\nmax_snippet_chars = 0x10\n",
        "90-int-plus": "[policy]\nmax_snippet_chars = +100\n",
        "91-int-negative-zero": "[policy]\nmax_snippet_chars = -0\n",
        "92-int-leading-zero": "[policy]\nmax_snippet_chars = 0100\n",
        "93-float-nan": "[fetch]\ntimeout_seconds = nan\n",
        "94-float-inf": "[fetch]\ntimeout_seconds = inf\n",
        "95-datetime-value": "[logging]\nlog_content = 1979-05-27\n",
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
    "13-printable-unicode": "caf\u00e9 \u2014 \u65e5\u672c\u8a9e \U0001f600".encode(),
    "14-zwsp-inside-token": "a<|\u200bendoftext|>b".encode(),
    "15-unterminated-angle": b"a<|endoftext",
    "16-fullwidth-bars": "a<\uff5cendoftext\uff5c>b".encode(),
    "17-token-newline": b"a<|end\noftext|>b",
    "18-long-token-name": b"<|" + b"a" * 80 + b"|>",
    "19-token-max-name": b"<|" + b"a" * 64 + b"|>",
    "20-token-at-end": b"abc<|im_end|>",
    "21-nonprintable-c0": b"a\x01b\x7f",
    "22-malformed-mid": b"caf\xe2abc<|x|>",
    "23-malformed-overlong": b"\xc0\xaf<|x|>",
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
    "32-window-offset-one": {"op": "window", "text": "hello world", "offset": 1, "max_chars": 5},
    "33-window-offset-at-end": {"op": "window", "text": "hello world", "offset": 11, "max_chars": 5},
    "34-window-offset-past-end-one": {"op": "window", "text": "hello world", "offset": 12, "max_chars": 5},
    "35-window-paragraph-break": {
        "op": "window",
        "text": "alpha beta gamma\n\ndelta epsilon zeta",
        "offset": 0,
        "max_chars": 20,
    },
    "36-window-paragraph-back-half": {
        "op": "window",
        "text": "alpha beta gamma delta epsilon\n\nzeta",
        "offset": 0,
        "max_chars": 40,
    },
    "37-window-unicode-boundary": {"op": "window", "text": "caf\u00e9 \U0001f600 na\u00efve", "offset": 5, "max_chars": 2},
    "38-window-emoji-mid": {"op": "window", "text": "\U0001f600\U0001f600", "offset": 1, "max_chars": 1},
    "39-window-newlines-only": {"op": "window", "text": "\n\n\n", "offset": 0, "max_chars": 2},
    "40-window-whitespace": {"op": "window", "text": "  a  b  ", "offset": 2, "max_chars": 3},
    "41-window-shorter-than-cap": {"op": "window", "text": "hi", "offset": 0, "max_chars": 100},
    "42-window-max-one": {"op": "window", "text": "hello", "offset": 2, "max_chars": 1},
    "43-window-offset-negative": {"op": "window", "text": "hello world", "offset": -1, "max_chars": 5},
    "44-window-cap-negative": {"op": "window", "text": "hello world", "offset": 0, "max_chars": -3},
}

# {4 jsondoc: render, structure, select, path grammar, media}


def _nested_object(depth: int) -> str:
    """[depth] levels of [{"a": ...}], the deepest document the render must walk."""

    return '{"a": ' * depth + "1" + "}" * depth


def _wide_object(count: int) -> str:
    return "{" + ", ".join(f'"k{i}": {i}' for i in range(count)) + "}"


def _wide_array(count: int) -> str:
    return "[" + ", ".join(str(i) for i in range(count)) + "]"


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
    # Depth and width are the two shapes a caller's `path` has to survive: the
    # render is a worklist walk, so a 50-level document arrives as one line per
    # level and a wide one as one line per member, never as a recursion that
    # could overflow on a stranger's page.
    "24-render-deep-50": {"op": "render", "body": _nested_object(50)},
    "25-structure-deep-50": {"op": "structure", "body": _nested_object(50)},
    "26-render-wide-object-40": {"op": "render", "body": _wide_object(40)},
    "27-render-wide-array-40": {"op": "render", "body": _wide_array(40)},
    # A duplicate key is where the two JSON readers part company: Python keeps
    # the last value under the first position, and a tree that keeps both would
    # print the column twice. Pinned rather than fixed, because neither answer
    # is the file's -- the file says both.
    "28-render-duplicate-keys": {"op": "render", "body": '{"a": 1, "b": 2, "a": 3}'},
    "29-structure-duplicate-keys": {"op": "structure", "body": '{"a": 1, "b": 2, "a": 3}'},
    # Numbers: the largest OCaml [int] and one past it, an arbitrary-precision
    # magnitude, and the floats whose Python repr is the one the render writes.
    "30-render-int-int63-max": {"op": "render", "body": '{"n": 4611686018427387903}'},
    "31-render-int-past-int63": {"op": "render", "body": '{"n": 4611686018427387904}'},
    "32-render-int-huge": {"op": "render", "body": '{"n": 123456789012345678901234567890}'},
    "33-render-int-int63-min": {"op": "render", "body": '{"n": -4611686018427387904}'},
    "34-render-floats": {
        "op": "render",
        "body": '{"a": 0.1, "b": 1.0, "c": -0.0, "d": 1e-7, "e": 1.5e300, "f": 3.141592653589793}',
    },
    "35-render-float-extremes": {
        "op": "render",
        "body": '{"inf": 1e309, "ninf": -1e309, "tiny": 5e-324, "sub": 2.2250738585072014e-308}',
    },
    # Whitespace is transport, not content: any mix of it between tokens is the
    # same document, and a body made only of it is no document at all.
    "36-render-whitespace-variants": {"op": "render", "body": '{\n\t"a" :\r\n [ 1 ,\t2 ]\n }'},
    "37-render-whitespace-only": {"op": "render", "body": " \n\t\r\n "},
    "38-render-bom": {"op": "render", "body": '\ufeff{"a": 1}'},
    "39-render-trailing-garbage": {"op": "render", "body": '{"a": 1} x'},
    "40-render-jsonl": {"op": "render", "body": '{"a": 1}\n{"b": 2}'},
    "41-render-scalar-string": {"op": "render", "body": '"hi"'},
    "42-render-scalar-null": {"op": "render", "body": "null"},
    "43-select-empty-array": {"op": "select", "body": '{"xs": []}', "path": "$.xs[*]", "max_chars": 100},
    "44-select-negative-index": {"op": "select", "body": '{"xs": [1, 2, 3]}', "path": "$.xs[-1]", "max_chars": 100},
    "45-select-unicode-key": {
        "op": "select",
        "body": '{"caf\u00e9": {"\u65e5": 1}}',
        "path": '$."caf\u00e9"."\u65e5"',
        "max_chars": 100,
    },
    "46-parse-path-quoted-escape": {"op": "parse-path", "path": '$."a\\"b"'},
    "47-child-path-empty-name": {"op": "child-path", "parent": "$.rows", "key": ""},
    "48-child-path-dot-and-space": {"op": "child-path", "parent": "$.rows", "key": "a.b c"},
    "49-sniffs-whitespace-only": {"op": "sniffs-json", "body": " \n\t "},
    "50-sniffs-bom": {"op": "sniffs-json", "body": '\ufeff{}'},
    "51-select-budget-zero": {"op": "select", "body": '{"xs": [1, 2, 3]}', "path": "$.xs[*]", "max_chars": 0},
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
    "09-csv-crlf": {"op": "render", "media": "text/csv", "body": "a,b\r\n1,2\r\n"},
    "10-csv-blank-lines": {"op": "render", "media": "text/csv", "body": "a,b\n\n1,2\n\n"},
    "11-csv-whitespace-cells": {"op": "render", "media": "text/csv", "body": " a , b \n 1 , 2 \n"},
    "12-csv-wide": {
        "op": "render",
        "media": "text/csv",
        "body": ",".join(f"c{i}" for i in range(20)) + "\n" + ",".join(str(i) for i in range(20)) + "\n",
    },
    "13-csv-semicolon-with-commas": {"op": "render", "media": "text/csv", "body": "a;b\n1,5;2,5\n"},
    "14-csv-quoted-multiline": {"op": "render", "media": "text/csv", "body": 'a,b\n"one\ntwo",3\n'},
    "15-csv-bom": {"op": "render", "media": "text/csv", "body": "\ufeffa,b\n1,2\n"},
    "16-csv-single-column": {"op": "render", "media": "text/csv", "body": "a\n1\n2\n"},
    "17-csv-trailing-delimiter": {"op": "render", "media": "text/csv", "body": "a,b,\n1,2,\n"},
    "18-csv-unicode-cells": {"op": "render", "media": "text/csv", "body": "name,note\ncaf\u00e9,\u65e5\u672c\u8a9e\n"},
}

# {5b text: the codepoint walk and the repr pass, over raw bytes in hex}

# The hex spelling is the point of this area: a malformed sequence has to reach
# both projections as the bytes it is, not as whatever the corpus file's own
# decode did to it.
TEXT_CASES: dict[str, dict[str, Any]] = {
    "01-count-empty": {"op": "count", "hex": ""},
    "02-count-ascii": {"op": "count", "hex": b"a plain query".hex()},
    "03-count-latin1": {"op": "count", "hex": "caf\u00e9 r\u00e9sum\u00e9".encode().hex()},
    "04-count-emoji": {"op": "count", "hex": "\U0001f600\U0001f600".encode().hex()},
    "05-count-combining": {"op": "count", "hex": "e\u0301e\u0301".encode().hex()},
    "06-count-lone-continuation": {"op": "count", "hex": b"\x80abc".hex()},
    "07-count-truncated-two-byte": {"op": "count", "hex": b"caf\xc3".hex()},
    "08-count-truncated-three-byte": {"op": "count", "hex": b"\xe2\x80".hex()},
    "09-count-truncated-four-byte": {"op": "count", "hex": b"\xf0\x9f\x98".hex()},
    "10-count-lead-then-ascii": {"op": "count", "hex": b"\xe2abc".hex()},
    "11-count-overlong": {"op": "count", "hex": b"\xc0\xaf".hex()},
    "12-count-surrogate": {"op": "count", "hex": b"\xed\xa0\x80".hex()},
    "13-count-five-byte-lead": {"op": "count", "hex": b"\xf8\x88\x80\x80\x80".hex()},
    "14-take-zero": {"op": "take", "hex": b"hello".hex(), "limit": 0},
    "15-take-ascii-mid": {"op": "take", "hex": b"hello world".hex(), "limit": 5},
    "16-take-latin1": {"op": "take", "hex": "caf\u00e9".encode().hex(), "limit": 3},
    "17-take-emoji": {"op": "take", "hex": "\U0001f600x".encode().hex(), "limit": 1},
    "18-take-past-end": {"op": "take", "hex": b"hi".hex(), "limit": 50},
    "19-take-combining": {"op": "take", "hex": "e\u0301x".encode().hex(), "limit": 1},
    "20-strip-unicode-space": {"op": "strip", "hex": "\u00a0\u2003x\u3000\u2028".encode().hex()},
    "21-strip-ascii": {"op": "strip", "hex": b"  a b\t\n".hex()},
    "22-strip-nel": {"op": "strip", "hex": "\u0085x\u0085".encode().hex()},
    "23-strip-no-space": {"op": "strip", "hex": "caf\u00e9".encode().hex()},
    "24-lstrip-unicode-space": {"op": "lstrip", "hex": "\u2003 x ".encode().hex()},
    "25-rstrip-unicode-space": {"op": "rstrip", "hex": " x \u2003".encode().hex()},
    "26-words-unicode-space": {"op": "words", "hex": "a\u00a0b\u2003c".encode().hex()},
    "27-words-tabs": {"op": "words", "hex": b"  a\tb\n\nc  ".hex()},
    "28-words-only-space": {"op": "words", "hex": b" \t\n".hex()},
    "29-words-zwsp": {"op": "words", "hex": "a\u200bb".encode().hex()},
    "30-lines-lf": {"op": "lines", "hex": b"a\nb\n".hex()},
    "31-lines-trailing-break": {"op": "lines", "hex": b"a\n\n".hex()},
    "32-lines-crlf": {"op": "lines", "hex": b"a\r\nb".hex()},
    "33-lines-lone-cr": {"op": "lines", "hex": b"a\rb".hex()},
    "34-lines-unicode-separators": {"op": "lines", "hex": "a\u2028b\u0085c\u000bd".encode().hex()},
    "35-slices-ascii": {"op": "slices", "hex": b"abc".hex()},
    "36-slices-emoji": {"op": "slices", "hex": "\U0001f600x".encode().hex()},
    "37-slices-combining": {"op": "slices", "hex": "e\u0301".encode().hex()},
    "38-repr-ascii": {"op": "repr", "hex": b"plain text".hex()},
    "39-repr-single-quote": {"op": "repr", "hex": b"it's".hex()},
    "40-repr-both-quotes": {"op": "repr", "hex": b"it's a \"quote\"".hex()},
    "41-repr-controls": {"op": "repr", "hex": b"a\tb\nc\rd\x00e\x7f".hex()},
    "42-repr-non-ascii": {"op": "repr", "hex": "caf\u00e9 \u2014 \u65e5\u672c\u8a9e".encode().hex()},
    "43-repr-nbsp": {"op": "repr", "hex": "a\u00a0b".encode().hex()},
    "44-repr-zwsp": {"op": "repr", "hex": "a\u200bb".encode().hex()},
    "45-repr-backslash": {"op": "repr", "hex": b"a\\b".hex()},
    "46-roundtrip-valid": {"op": "roundtrip", "hex": "caf\u00e9 \U0001f600".encode().hex()},
    "47-roundtrip-invalid": {"op": "roundtrip", "hex": b"\xe2abc".hex()},
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
    # A five-rung ladder is where the ordering rules stop being obvious: the
    # default that the walk already tried is not a rung, a gated name keeps its
    # place but is skipped, and the exhaustion sentence has to name the names it
    # actually attempted rather than the ladder it was given.
    "07-search-deep-ladder": {
        "table": {
            "providers": ["serper", "linkup", "tavily", "exa:free", "freeserp"],
            "default": "serper",
            "permitted": None,
            "fallback": ["linkup", "tavily", "exa:free", "freeserp", "serper"],
            "free_fallback": ["freeserp", "exa:free"],
            "free": ["exa:free", "freeserp", "parallel:free", "anysearch"],
            "free_order": ["exa:free", "parallel:free", "freeserp", "anysearch"],
            "effective": ["serper", "linkup", "tavily", "exa:free", "freeserp"],
        },
        "calls": [
            {
                "fn": "fallback_rungs",
                "ladder": ["linkup", "tavily", "exa:free", "freeserp", "serper"],
                "tried": "serper",
                "gated": [],
            },
            {
                "fn": "fallback_rungs",
                "ladder": ["linkup", "tavily", "exa:free", "freeserp", "serper"],
                "tried": "serper",
                "gated": ["tavily", "freeserp"],
            },
            {"fn": "free_walk"},
            {
                "fn": "fallback_exhausted_note",
                "failed": ["serper", "linkup", "tavily", "exa:free", "freeserp"],
                "mode": None,
            },
            {"fn": "resolve_search", "mode": "free"},
            {"fn": "unnamed_walks_free"},
        ],
    },
    # The request name is free text a model wrote, so a refusal quotes it back:
    # the sentence has to survive a combining mark, an emoji and a zero-width
    # space without turning into bytes or breaking the line.
    "08-search-unicode-request": {
        "table": {
            "providers": ["serper", "exa:free"],
            "default": "serper",
            "permitted": None,
            "fallback": [],
            "free_fallback": [],
            "free": ["exa:free", "freeserp", "parallel:free", "anysearch"],
            "free_order": ["exa:free", "parallel:free", "freeserp", "anysearch"],
            "effective": ["serper", "exa:free"],
        },
        "calls": [
            {"fn": "resolve_search", "requested": "caf\u00e9"},
            {"fn": "resolve_search", "requested": "exa\U0001f600"},
            {"fn": "resolve_search", "requested": "serper\u200b"},
            {"fn": "is_permitted", "name": "caf\u00e9"},
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
    "05-model-answer-and-registry": {        "cases": [
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
    # Extremes: the bounds a calling model can name, the largest integers the two
    # decoders hold, and the numeric spellings that are one value to an integer
    # field and another to a float one.
    "06-model-extremes": {
        "cases": [
            {"model": "search_request", "body": {"query": "q", "max_results": 0}},
            {"model": "search_request", "body": {"query": "q", "max_results": 1}},
            {"model": "search_request", "body": {"query": "q", "max_results": 20}},
            {"model": "search_request", "body": {"query": "q", "max_results": 21}},
            {"model": "search_request", "body": {"query": "q", "max_results": -1}},
            {"model": "search_request", "body": {"query": "q", "max_results": 2.0}},
            {"model": "search_request", "body": {"query": "q", "max_results": 2.5}},
            # 2**70: an integer JSON can carry and an OCaml [int] cannot.
            {"model": "search_request", "body_text": '{"query": "q", "max_results": 1180591620717411303424}'},
            {"model": "search_request", "body_text": '{"query": "q", "max_results": 4611686018427387904}'},
            {"model": "fetch_request", "body": {"url": "https://example.com/", "offset": -1}},
            {"model": "fetch_request", "body": {"url": "https://example.com/", "offset": 0}},
            {"model": "fetch_request", "body_text": '{"url": "https://example.com/", "offset": 1180591620717411303424}'},
            {"model": "result", "body": {"title": "T", "url": "https://e.com", "score": 5e-324}},
            {"model": "result", "body": {"title": "T", "url": "https://e.com", "score": 1e308}},
            {"model": "result", "body": {"title": "T", "url": "https://e.com", "score": -1.5}},
            {"model": "result", "body": {"title": "", "url": "https://e.com", "snippet": ""}},
        ]
    },
    # A duplicate key has no single value: Python's object model keeps the last
    # one under the first position, and a JSON tree that keeps both lets each
    # lookup resolve the first. The body arrives as text precisely so neither
    # projection is handed the already-collapsed object.
    "07-model-duplicate-keys": {
        "cases": [
            {"model": "result", "body_text": '{"url": "https://e.com/1", "url": "https://e.com/2", "title": "t"}'},
            {"model": "search_request", "body_text": '{"query": "first", "query": "second"}'},
            {"model": "fetch_request", "body_text": '{"url": "https://example.com/a", "url": "https://example.com/b"}'},
            {"model": "result", "body_text": '{"title": "a", "title": "b", "url": "https://e.com", "score": 0.5, "score": 0.75}'},
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
    # A four-rung ladder that ends in a hit: the attempt record is the whole
    # claim, because the answer alone cannot say how many vendors were spent.
    "09-deep-ladder": {
        "config": {
            "providers": {
                "serper": {"enabled": True},
                "linkup": {"enabled": True},
                "tavily": {"enabled": True},
                "exa:free": {"enabled": True},
                "freeserp": {"enabled": True},
            },
            "default_provider": "serper",
            "search": {"fallback": ["linkup", "tavily", "exa:free", "freeserp"]},
        },
        "providers": [
            {"name": "serper", "kind": "failure", "message": "upstream timed out", "retryable": True},
            {"name": "linkup", "kind": "failure", "message": "bad gateway", "retryable": True},
            {"name": "tavily", "kind": "failure", "message": "connection reset", "retryable": True},
            {"name": "exa:free", "kind": "quota", "message": "quota exhausted"},
            {"name": "freeserp", "results": [_ENGINE_RESULT["ok2"]]},
        ],
        "calls": [{"query": "deep ladder"}],
    },
    "10-ladder-exhausted": {
        "config": {
            "providers": {"serper": {"enabled": True}, "linkup": {"enabled": True}, "exa:free": {"enabled": True}},
            "default_provider": "serper",
            "search": {"fallback": ["linkup", "exa:free"]},
        },
        "providers": [
            {"name": "serper", "kind": "failure", "message": "upstream timed out", "retryable": True},
            {"name": "linkup", "kind": "quota", "message": "quota exhausted"},
            {"name": "exa:free", "kind": "failure", "message": "service unavailable", "retryable": False},
        ],
        "calls": [{"query": "nothing will answer"}],
    },
    # Non-ASCII reaches the engine twice: in the query the caller wrote and in
    # the page text a provider returned. Both leave through the sanitize and
    # escape boundary, so this case is what catches a byte-wise truncation or a
    # raw special-token literal on the response path.
    "11-unicode-query-and-results": {
        "config": {
            "providers": {"serper": {"enabled": True}},
            "default_provider": "serper",
        },
        "providers": [
            {
                "name": "serper",
                "results": [
                    {
                        "title": "caf\u00e9 na\u00efve \u65e5\u672c\u8a9e \U0001f600",
                        "url": "https://e.com/unicode",
                        "snippet": "a r\u00e9sum\u00e9 <|endoftext|> and \u200b a zero-width space",
                    }
                ],
            }
        ],
        "calls": [{"query": "caf\u00e9 \U0001f600 <|endoftext|>", "max_results": 1}],
    },
}


def main() -> None:
    write_config("config")
    write_sanitize("sanitize")
    write_specs("fetch", FETCH_CASES)
    write_specs("jsondoc", JSONDOC_CASES)
    write_specs("tabledoc", TABLEDOC_CASES)
    write_specs("text", TEXT_CASES)
    write_specs("router", ROUTER_CASES)
    write_specs("model", MODEL_CASES)
    write_specs("engine", ENGINE_CASES)
    total = sum(1 for path in CORPUS.rglob("*") if path.is_file())
    print(f"corpus written: {total} inputs under {CORPUS}")


if __name__ == "__main__":
    main()
