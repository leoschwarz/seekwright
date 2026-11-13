"""The Python half of every corpus projection.

``../../test/differential/projection.ml`` is the OCaml half; this module is its
line-for-line twin, written against the read-only ``src/seekwright`` tree. The
golden file is what makes the two agree: this side produces the pinned
``--- oracle`` section, the port is then run over the same corpus input, and a
mismatch either becomes a documented explicit divergence or fails the suite.

Two rules every projection follows, shared with the OCaml half through
``test/differential/README.md``:

- the projection of one case is a list of single-line ASCII strings; free text
  goes through :func:`esc` (``json.dumps``'s escape), never into a line raw;
- no clock, no environment: values a golden would have to re-read from the
  machine (``retrieved_at``, ``ms``) are left out of the projection.

Run through ``gen_goldens.py``, not directly: that script pins the corpus
paths, clears the key environment, and writes the golden files.
"""

from __future__ import annotations

import asyncio
import json
import pathlib
import sys
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parents[2]
if str(ROOT / "src") not in sys.path:
    sys.path.insert(0, str(ROOT / "src"))

from pydantic import ValidationError

from seekwright import engine as engine_module
from seekwright import fetcher, jsondoc, models, router, sanitize, tabledoc
from seekwright.config import Config, ProviderConfig, SearchConfig, load_config
from seekwright.providers.base import ProviderError, QuotaExhausted, SearchProvider

# {1 The canonical rendering (mirror of test/differential/canon.ml)}


def esc(text: str) -> str:
    """``json.dumps(ensure_ascii=True)`` of a string, minus the quotes.

    This is exactly ``Canon.escape_text``: named escapes, ``\\uXXXX`` lowercase
    for everything else non-ASCII, surrogate pairs above the BMP.
    """
    return json.dumps(text, ensure_ascii=True)[1:-1]


def to_hex(data: bytes) -> str:
    return data.hex()


def of_hex(text: str) -> bytes:
    return bytes.fromhex(text)


def float_repr(value: float) -> str:
    """``Canon.float_repr``: ``%.17g`` with a ``.0`` when that hid the point."""
    digits = f"{value:.17g}"
    return digits + ".0" if "." not in digits and "e" not in digits and "E" not in digits else digits


def canon_json(value: Any) -> str:
    """The compact, key-sorted rendering the model area pins."""
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return float_repr(value)
    if isinstance(value, str):
        return '"' + esc(value) + '"'
    if isinstance(value, list):
        return "[" + ",".join(canon_json(item) for item in value) + "]"
    members = sorted((str(k), canon_json(v)) for k, v in value.items())
    return "{" + ",".join(f'"{esc(k)}":{v}' for k, v in members) + "}"


def flag(value: bool) -> str:
    return "true" if value else "false"


def opt_value(value: str | None) -> str:
    return "-" if value is None else esc(value)


def list_value(value: list[str] | None) -> str:
    return "-" if value is None else ",".join(value)


def opt_number(value: float | None) -> str:
    return "-" if value is None else f"{value:.6f}"


def maybe(spec: dict[str, Any], key: str) -> Any:
    return spec.get(key)


def want_string(spec: dict[str, Any], key: str) -> str:
    return spec[key]


def want_int(spec: dict[str, Any], key: str) -> int:
    return spec[key]


def want_bool(spec: dict[str, Any], key: str) -> bool:
    return spec[key]


def want_strings(spec: dict[str, Any], key: str) -> list[str]:
    return spec[key]


def maybe_strings(spec: dict[str, Any], key: str) -> list[str] | None:
    value = spec.get(key)
    return None if value is None else list(value)


def maybe_string(spec: dict[str, Any], key: str) -> str | None:
    return spec.get(key)


def maybe_objects(spec: dict[str, Any], key: str) -> list[dict[str, Any]] | None:
    value = spec.get(key)
    return None if value is None else list(value)


# {1 config (mirror of Projection.config)}

_KEYLESS_HINT = "A config that needs no API key:"


def _one_line(text: str) -> str:
    return "".join(" " if ch in "\n\r\t" else ch for ch in text)


def _cut_at(marker: str, text: str) -> str:
    at = text.find(marker)
    return text if at < 0 else text[:at]


def config_refusal(message: str) -> list[str]:
    if message.startswith("seekwright: invalid TOML in "):
        return ["PARSE-ERR"]
    sentence = message
    prefix = "seekwright: invalid config in "
    if sentence.startswith(prefix):
        rest = sentence[len(prefix) :]
        colon = rest.find(":")
        if colon >= 0 and colon + 2 <= len(rest):
            sentence = rest[colon + 2 :]
    sentence = _cut_at(_KEYLESS_HINT, sentence)
    collapsed = " ".join(part for part in _one_line(sentence).split(" ") if part)
    return ["ERR " + esc(collapsed)]


def _provider_line(name: str, entry: ProviderConfig) -> str:
    return " ".join(
        [
            "provider",
            name,
            "enabled=" + flag(entry.enabled),
            "cost=" + opt_number(entry.cost_per_1k),
            "depth=" + entry.depth,
            "output=" + entry.output_type,
            "mode=" + entry.mode,
            "url=" + opt_value(entry.url),
            "cooldown=" + opt_number(entry.free_cooldown_seconds),
            "app=" + opt_value(entry.app_id),
            "index=" + opt_value(entry.index),
            "title_attr=" + opt_value(entry.title_attr),
            "url_attr=" + opt_value(entry.url_attr),
            "snippet_attr=" + opt_value(entry.snippet_attr),
        ]
    )


def config_lines(c: Config) -> list[str]:
    lines = [
        "default=" + opt_value(c.default_provider),
        "permitted=" + list_value(c.permitted_providers),
        "providers_defaulted=" + flag(c.providers_defaulted),
        "enabled=" + ",".join(c.enabled_providers()),
        "effective=" + ",".join(c.effective_providers()),
        "free_only=" + flag(c.default_route_is_free_only()),
        "missing_keys=" + ",".join(c.missing_api_keys()),
        "missing_agent=" + ",".join(c.missing_agent_settings()),
        ",".join(
            [
                "policy",
                str(c.policy.max_snippet_chars),
                str(c.policy.max_result_text_chars),
                f"{c.policy.provider_timeout_seconds:.6f}",
            ]
        ),
        ",".join(
            [
                "fetch",
                flag(c.fetch.enabled),
                c.fetch.extractor,
                f"{c.fetch.timeout_seconds:.6f}",
                str(c.fetch.max_download_bytes),
                str(c.fetch.max_text_chars),
                str(c.fetch.min_text_chars),
                str(c.fetch.max_match_chars),
                str(c.fetch.max_redirects),
                flag(c.fetch.allow_private_addresses),
                flag(c.fetch.allow_images),
                esc(c.fetch.user_agent),
                list_value(c.fetch.fallback),
                flag(c.fetch.auto_fallback),
                c.fetch.primary,
                opt_number(c.fetch.cost_per_1k),
                opt_value(c.fetch.crawl4ai_url),
                opt_value(c.fetch.crawl4ai_token),
                f"{c.fetch.crawl4ai_timeout_seconds:.6f}",
                opt_value(c.fetch.cache_dir),
                str(c.fetch.cache_max_bytes),
                str(c.fetch.cache_max_entry_bytes),
                f"{c.fetch.cache_ttl_seconds:.6f}",
            ]
        ),
        ",".join(
            [
                "search",
                list_value(c.search.fallback),
                list_value(c.search.free_fallback),
                f"{c.search.health_interval_seconds:.6f}",
                str(c.search.health_failure_threshold),
                f"{c.search.health_cooldown_seconds:.6f}",
            ]
        ),
        ",".join(
            [
                "agent",
                flag(c.agent.enabled),
                opt_value(c.agent.base_url),
                opt_value(c.agent.model),
                f"{c.agent.timeout_seconds:.6f}",
                f"{c.agent.model_timeout_seconds:.6f}",
                str(c.agent.max_material_chars),
                str(c.agent.max_output_tokens_brief),
                str(c.agent.max_output_tokens_report),
                opt_number(c.agent.max_cost_usd),
                opt_number(c.agent.cost_per_1k_in),
                opt_number(c.agent.cost_per_1k_out),
            ]
        ),
        ",".join(
            [
                "logging",
                str(c.logging.level),
                str(c.logging.format),
                str(c.logging.library_level),
                flag(c.logging.access_log),
                flag(c.logging.log_queries),
                flag(c.logging.log_content),
            ]
        ),
        ",".join(["dashboard", flag(c.dashboard.enabled), opt_value(c.dashboard.history_path)]),
    ]
    lines += [_provider_line(name, entry) for name, entry in sorted(c.providers.items())]
    return lines


def config(path: str) -> list[str]:
    try:
        loaded = load_config(path)
    except SystemExit as exc:
        return config_refusal(str(exc))
    return config_lines(loaded)


# {1 sanitize (mirror of Projection.sanitize)}


def _remove_zwsp(text: str) -> str:
    return text.replace("\u200b", "")


def sanitize_case(text: str) -> list[str]:
    escaped, count = sanitize.sanitize_text(text)
    again, extra = sanitize.sanitize_text(escaped)
    return [
        "count=" + str(count),
        "out=" + to_hex(escaped.encode("utf-8")),
        "idempotent=" + flag(again == escaped and extra == 0),
        "reversible=" + flag(_remove_zwsp(escaped) == text),
    ]


# {1 fetch (mirror of Projection.fetch)}


def _fetch_url(spec: dict[str, Any]) -> list[str]:
    try:
        return ["url= " + esc(fetcher.validate_url(spec["url"]))]
    except fetcher.UrlBlocked as blocked:
        return ["url-refused= " + esc(blocked.message)]


def _fetch_window(spec: dict[str, Any]) -> list[str]:
    window, more = fetcher.window_text(spec["text"], offset=spec["offset"], max_chars=spec["max_chars"])
    return ["window= " + esc(window), "more=" + flag(more)]


def _fetch_sniff(spec: dict[str, Any]) -> list[str]:
    return ["image= " + opt_value(fetcher.sniff_image_type(of_hex(spec["hex"])))]


def _fetch_cap(spec: dict[str, Any]) -> list[str]:
    cap = fetcher.resolved_cap(spec["default"], spec.get("max_chars"))
    return ["cap=" + ("uncapped" if cap == fetcher.UNCAPPED else str(cap))]


FETCH_OPS = {
    "url": _fetch_url,
    "window": _fetch_window,
    "sniff": _fetch_sniff,
    "cap": _fetch_cap,
}


# {1 jsondoc and tabledoc (mirror of Projection's op tables)}


def _reprint_steps(steps: list[Any]) -> str:
    out = []
    for step in steps:
        if isinstance(step, jsondoc.Key):
            out.append("." + step.name)
        elif isinstance(step, jsondoc.Position):
            out.append(f"[{step.ordinal}]")
        elif isinstance(step, jsondoc.Every):
            out.append("[*]")
        elif isinstance(step, jsondoc.Bounds):
            start = "" if step.start is None else str(step.start)
            stop = "" if step.stop is None else str(step.stop)
            out.append(f"[{start}:{stop}]")
    return "".join(out)


def _json_render(spec: dict[str, Any]) -> list[str]:
    return ["render= " + opt_value(jsondoc.render_json(spec["body"]))]


def _json_structure(spec: dict[str, Any]) -> list[str]:
    rendered = jsondoc.render_json(spec["body"])
    if rendered is None:
        return ["render= -"]
    return ["render= " + esc(rendered), "schema= " + opt_value(jsondoc.render_schema(rendered))]


def _json_select(spec: dict[str, Any]) -> list[str]:
    rendered = jsondoc.render_json(spec["body"])
    if rendered is None:
        return ["render= -"]
    try:
        spans, dropped = jsondoc.select_paths(rendered, spec["path"], max_chars=spec["max_chars"])
    except jsondoc.PathSyntax as bad:
        return ["path-refused= " + esc(str(bad))]
    return [
        "select= " + "|".join(f"{offset}:{esc(text)}" for offset, text in spans),
        "dropped=" + str(dropped),
    ]


def _json_parse_path(spec: dict[str, Any]) -> list[str]:
    try:
        return ["steps= " + _reprint_steps(jsondoc.parse_path(spec["path"]))]
    except jsondoc.PathSyntax as bad:
        return ["path-refused= " + esc(str(bad))]


def _json_child_path(spec: dict[str, Any]) -> list[str]:
    return ["child= " + esc(jsondoc.child_path(spec["parent"], spec["key"]))]


def _json_media(spec: dict[str, Any]) -> list[str]:
    kind = spec["type"]
    return [
        "json= " + flag(jsondoc.is_json_media(kind)),
        "json-document= " + flag(jsondoc.is_json_document_media(kind)),
    ]


def _json_sniffs(spec: dict[str, Any]) -> list[str]:
    return ["sniffs= " + flag(jsondoc.sniffs_json(spec["body"].encode("utf-8")))]


JSONDOC_OPS = {
    "render": _json_render,
    "structure": _json_structure,
    "select": _json_select,
    "parse-path": _json_parse_path,
    "child-path": _json_child_path,
    "media": _json_media,
    "sniffs-json": _json_sniffs,
}


def _table_render(spec: dict[str, Any]) -> list[str]:
    kind, body = spec["media"], spec["body"]
    delimiter = tabledoc.table_delimiter(kind, body)
    return [
        "delimiter= " + esc(delimiter),
        "table= " + flag(tabledoc.is_table_media(kind)),
        "render= " + opt_value(tabledoc.render_table(body, delimiter=delimiter)),
    ]


TABLEDOC_OPS = {"render": _table_render}


def _op_lines(table: dict[str, Any], area: str, spec: dict[str, Any]) -> list[str]:
    try:
        return table[spec["op"]](spec)
    except KeyError:
        raise SystemExit("the {} corpus has no op {!r}".format(area, spec.get("op")))


# {1 router (mirror of Projection.router)}


def _search_table(spec: dict[str, Any]) -> router.SearchTable:
    table = spec["table"]
    permitted = maybe_strings(table, "permitted")
    return router.SearchTable(
        providers=tuple(want_strings(table, "providers")),
        default=maybe_string(table, "default"),
        permitted=None if permitted is None else tuple(permitted),
        fallback=tuple(want_strings(table, "fallback")),
        free_fallback=tuple(want_strings(table, "free_fallback")),
        free=frozenset(want_strings(table, "free")),
        free_order=tuple(want_strings(table, "free_order")),
        effective=tuple(want_strings(table, "effective")),
    )


def _fetch_table(spec: dict[str, Any]) -> router.FetchTable:
    table = spec["table"]
    return router.FetchTable(built=tuple(want_strings(table, "built")), primary=maybe_string(table, "primary"))


def _refused(message: str) -> str:
    return "refused= " + esc(message)


def _router_call(table: router.SearchTable, call: dict[str, Any]) -> list[str]:
    name = call["fn"]
    try:
        if name == "resolve_search":
            mode = "free" if call.get("mode") is not None else None
            return ["resolve_search= " + opt_value(router.resolve_search(table, call.get("requested"), mode))]
        if name == "is_permitted":
            return ["is_permitted= " + flag(table.is_permitted(call["name"]))]
        if name == "unnamed_walks_free":
            return ["unnamed_walks_free= " + flag(router.unnamed_walks_free(table))]
        if name == "free_candidates":
            return ["free_candidates= " + ",".join(router.free_candidates(table))]
        if name == "free_walk":
            return ["free_walk= " + ",".join(router.free_walk(table))]
        if name == "fallback_rungs":
            rungs = router.fallback_rungs(table, call["ladder"], call["tried"], frozenset(call["gated"]))
            return ["rungs= " + ",".join(f"{r.name}/{r.status.value}" for r in rungs)]
        if name == "fallback_served_notice":
            return [
                "notice= "
                + esc(
                    router.fallback_served_notice(
                        tried=call["tried"],
                        original_reason=call["original_reason"],
                        fallback=call["fallback"],
                        notice=call.get("notice"),
                    )
                )
            ]
        if name == "fallback_exhausted_note":
            mode = "free" if call.get("mode") is not None else None
            return ["note= " + esc(router.fallback_exhausted_note(call["failed"], mode))]
        if name == "retry_advice":
            return ["advice= " + esc(router.retry_advice(quota=call["quota"]))]
    except router.RouteRefused as refusal:
        return [f"{name} {_refused(str(refusal))}"]
    raise SystemExit(f"router corpus has no fn {name!r}")


def _fetch_router_call(table: router.FetchTable, call: dict[str, Any]) -> list[str]:
    name = call["fn"]
    if name == "fetch_walk":
        return ["fetch_walk= " + ",".join(router.fetch_walk(table))]
    if name == "origin":
        return ["origin= " + esc(router.origin(table))]
    if name == "provider_names":
        return ["provider_names= " + esc(router.provider_names(table))]
    if name == "choose_names":
        return ["choose_names= " + esc(router.choose_names(table))]
    if name == "choose_instead":
        return ["choose_instead= " + esc(router.choose_instead(table))]
    if name == "empty_notice":
        return ["empty_notice= " + esc(router.empty_notice(table, walked=call["walked"]))]
    if name == "refetched_notice":
        return [
            "refetched= "
            + esc(router.refetched_notice(table, reason=call["reason"], fallback_name=call["fallback"]))
        ]
    if name == "not_enabled":
        return ["not_enabled= " + esc(router.not_enabled(table, call["requested"]))]
    if name == "resolve_fetch":
        try:
            resolved = router.resolve_fetch(table, call.get("requested"))
        except router.RouteRefused as refusal:
            return ["resolve_fetch " + _refused(str(refusal))]
        return ["resolve_fetch= " + ("local" if resolved is None else resolved)]
    raise SystemExit(f"fetch router corpus has no fn {name!r}")


def router_case(spec_text: str) -> list[str]:
    spec = json.loads(spec_text)
    calls = spec["calls"]
    if isinstance(spec.get("table"), dict) and "providers" in spec["table"]:
        table = _search_table(spec)
        return [line for call in calls for line in _router_call(table, call)]
    table = _fetch_table(spec)
    return [line for call in calls for line in _fetch_router_call(table, call)]


# {1 model (mirror of Projection.model)}

_MODEL_CLASSES: dict[str, type[models.BaseModel]] = {
    "result": models.Result,
    "search_response": models.SearchResponse,
    "fetch_response": models.FetchResponse,
    "fetch_match": models.FetchMatch,
    "fetch_image": models.FetchImage,
    "search_request": models.SearchRequest,
    "fetch_request": models.FetchRequest,
    "answer_request": models.AnswerRequest,
    "answer_response": models.AnswerResponse,
    "answer_source": models.AnswerSource,
    "search_query": models.SearchQuery,
    "provider_result": models.ProviderResult,
}


def _wire_dump(model: Any) -> dict[str, Any]:
    """The wire object the port's encoder would write.

    For the agent-facing ``WireModel`` shapes, ``_drop_absent`` already runs at
    ``model_dump`` time: it drops absent fields and escapes ``TEXT_FIELDS``.
    ``SearchQuery`` and ``ProviderResult`` sit at the *provider* boundary, not
    the wire boundary, and pydantic serialises them with their nulls — which is
    what the port's encoders for those two records do too.
    """
    return model.model_dump()


def model_case(spec_text: str) -> list[str]:
    spec = json.loads(spec_text)
    lines: list[str] = []
    for case in spec["cases"]:
        cls = _MODEL_CLASSES[case["model"]]
        try:
            validated = cls.model_validate(case["body"])
        except ValidationError:
            lines.append("verdict= reject")
            continue
        lines.append("verdict= accept")
        lines.append("wire= " + canon_json(_wire_dump(validated)))
    return lines


# {1 engine (mirror of Projection.engine)}


class _StubProvider:
    """The scripted provider: the position ``StubProvider`` holds in tests/test_engine.py."""

    def __init__(self, spec: dict[str, Any], attempts: list[str]) -> None:
        self.name = spec["name"]
        self.cost_per_1k = float(spec.get("cost", 0.0))
        self._attempts = attempts
        self._fail: ProviderError | None = None
        if spec.get("kind") == "failure":
            self._fail = ProviderError(self.name, spec["message"], retryable=spec["retryable"])
        elif spec.get("kind") == "quota":
            self._fail = QuotaExhausted(self.name, spec["message"])
        self._results = [models.Result.model_validate(body) for body in spec.get("results", [])]
        self._answer = spec.get("answer")
        self._notice = spec.get("notice")

    async def search(self, q: models.SearchQuery) -> models.ProviderResult:
        self._attempts.append(self.name)
        if self._fail is not None:
            raise self._fail
        return models.ProviderResult(
            provider=self.name,
            results=self._results,
            answer=self._answer,
            cost_usd=None,
            notice=self._notice,
        )

    async def aclose(self) -> None:
        return None


def _engine_config(spec: dict[str, Any]) -> Config:
    section = spec["config"]
    providers = {
        name: ProviderConfig(
            enabled=entry["enabled"],
            cost_per_1k=entry.get("cost_per_1k"),
            depth=entry.get("depth", "standard"),
            mode=entry.get("mode", "fast"),
            url=entry.get("url"),
        )
        for name, entry in section.get("providers", {}).items()
    }
    search = section.get("search")
    return Config(
        providers=providers,
        default_provider=section.get("default_provider"),
        permitted_providers=section.get("permitted_providers"),
        search=SearchConfig(
            fallback=(search or {}).get("fallback", []), free_fallback=(search or {}).get("free_fallback", [])
        ),
    )


def _engine_call(eng: engine_module.SearchEngine, call: dict[str, Any], attempts: list[str], events: list[str]) -> list[str]:
    query = models.SearchQuery(
        query=call["query"],
        max_results=call.get("max_results", 5),
        include_domains=call.get("include_domains", []),
        exclude_domains=call.get("exclude_domains", []),
        country=call.get("country"),
        language=call.get("language"),
        recency=call.get("recency"),
        safe_search=call.get("safe_search"),
    )
    try:
        response = asyncio.run(
            eng.search(query, provider=call.get("provider"), mode=("free" if call.get("mode") is not None else None))
        )
    except engine_module.SearchRefused as refused:
        return ["attempt " + name for name in attempts] + [
            "events= " + ",".join(events),
            "verdict= refused",
            "message= " + esc(str(refused)),
        ]
    except engine_module.SearchFailed as failed:
        return ["attempt " + name for name in attempts] + [
            "events= " + ",".join(events),
            "verdict= failed",
            "message= " + esc(str(failed)),
        ]
    return ["attempt " + name for name in attempts] + [
        "events= " + ",".join(events),
        "verdict= ok",
        "provider= " + response.provider,
        "results=" + str(len(response.results)),
        "titles=" + ",".join(esc(result.title) for result in response.results),
        "notice=" + opt_value(response.notice),
    ]


def engine_case(spec_text: str) -> list[str]:
    spec = json.loads(spec_text)
    config = _engine_config(spec)
    events: list[str] = []
    attempts: list[str] = []
    providers: dict[str, SearchProvider] = {
        entry["name"]: _StubProvider(entry, attempts) for entry in spec["providers"]
    }
    eng = engine_module.SearchEngine(config, providers)

    from loguru import logger

    sink_id = logger.add(
        lambda message: events.append(message.record["message"]),
        filter=lambda record: record["module"] == "engine",
    )
    try:
        lines: list[str] = []
        for call in spec["calls"]:
            attempts.clear()
            events.clear()
            lines += _engine_call(eng, call, attempts, events)
        return lines
    finally:
        logger.remove(sink_id)


# {1 The area table (mirror of Projection.areas)}

AREAS: dict[str, Any] = {
    "config": config,
    "sanitize": sanitize_case,
    "fetch": lambda text: _op_lines(FETCH_OPS, "fetch", json.loads(text)),
    "jsondoc": lambda text: _op_lines(JSONDOC_OPS, "jsondoc", json.loads(text)),
    "tabledoc": lambda text: _op_lines(TABLEDOC_OPS, "tabledoc", json.loads(text)),
    "router": router_case,
    "model": model_case,
    "engine": engine_case,
}
