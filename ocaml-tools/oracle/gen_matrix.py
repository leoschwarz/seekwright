"""Write the four parity-matrix tables under test/differential/matrix/.

The TSVs are the F0.1 manifest: one row per provider, config key, behaviour and
surface item, each naming its consumer on both sides and the verification that
backs the parity claim. This generator is kept so a wave can regenerate a
table mechanically rather than hand-tuning columns; the TSVs themselves are
committed data, read by test_differential_matrix at every runtest.

Run: python3 ocaml-tools/oracle/gen_matrix.py
"""
import pathlib
from collections.abc import Sequence

ROOT = pathlib.Path(__file__).resolve().parents[2]
MATRIX = ROOT / "test" / "differential" / "matrix"

POLICY_TIMEOUT = "policy.provider_timeout_seconds"

PROVIDERS_HEADER = [
    "provider", "oracle_adapter", "port_adapter", "port_state", "kind",
    "endpoint", "auth", "cost_per_1k_default", "timeout", "constraints",
    "result_field", "quota_class", "live_status", "verification",
]

UNTESTED = "untested-in-repo"
PROVIDERS = [
    ("algolia", "providers/algolia.py", "-", "not-ported", "serp",
     "{app_id}-dsn.algolia.net/1/indexes/{index}/query", "x-algolia-application-id+x-algolia-api-key",
     "0.50", POLICY_TIMEOUT, "domains:query-filters;recency:none;ignored-constraints-notice",
     "snippet", "keyed-free-tier", "keyed-live-fixture", "pending-F4"),
    ("anysearch", "providers/anysearch.py", "providers/anysearch.ml", "ported", "serp",
     "api.anysearch.com", "none", "0.0", POLICY_TIMEOUT,
     "country+language:query-fold;domains:none;ignored-constraints-notice",
     "snippet", "keyless", "keyless-live", "unit(test_anysearch scripted transport)"),
    ("deepseek", "providers/deepseek.py", "-", "not-ported", "serp+summary",
     "api.deepseek.com", "Authorization:Bearer", "0.75", POLICY_TIMEOUT,
     "domains:site-fold;recency:none;ignored-constraints-notice",
     "snippet", "keyed-billed", UNTESTED, "pending-F4"),
    ("exa", "providers/exa_mcp.py", "-", "not-ported", "content",
     "mcp.exa.ai (streamable MCP, web_search_exa)", "Authorization:Bearer", "7.00", POLICY_TIMEOUT,
     "domains:MCP-filter;recency:native;free-tier-first ladder;ignored-constraints-notice",
     "text", "keyed-billed-free-first", "keyed-live", "pending-F4"),
    ("exa:free", "providers/exa_mcp.py", "-", "not-ported", "content",
     "mcp.exa.ai (streamable MCP, anonymous)", "none", "-", POLICY_TIMEOUT,
     "domains:MCP-filter;recency:native;no ladder (cannot bill)",
     "text", "keyless-free", "keyless-live", "pending-F4"),
    ("freeserp", "providers/freeserp.py", "providers/freeserp.ml", "ported", "serp",
     "freeserp.ai", "none", "0.0", POLICY_TIMEOUT,
     "country+language:native;recency:native;ignored-constraints-notice",
     "snippet", "keyless", "keyless-live", "unit(test_freeserp scripted transport)"),
    ("linkup", "providers/linkup.py", "-", "not-ported", "answer-or-serp(per depth)",
     "api.linkup.so", "Authorization:Bearer", "6.00", POLICY_TIMEOUT,
     "domains:native;recency:native;ignored-constraints-notice",
     "snippet-or-answer", "keyed-billed", "keyed-live", "pending-F4"),
    ("parallel", "providers/parallel.py", "-", "not-ported", "content",
     "api.parallel.ai", "x-api-key", "1.00", POLICY_TIMEOUT,
     "domains:native;recency:native;safe_search:native;depth preset picks price",
     "text", "keyed-billed", "keyed-live", "pending-F4"),
    ("parallel:free", "providers/parallel.py", "-", "not-ported", "content",
     "search.parallel.ai (anonymous)", "none", "-", POLICY_TIMEOUT,
     "domains:native;recency:native;no ladder (cannot bill)",
     "text", "keyless-free", "keyless-live", "pending-F4"),
    ("querit", "providers/querit.py", "-", "not-ported", "serp",
     "api.querit.ai", "Authorization:Bearer", "0.0", POLICY_TIMEOUT,
     "country+language:native;recency:native;ignored-constraints-notice",
     "snippet", "keyed-free-tier", UNTESTED, "pending-F4"),
    ("scrappa", "providers/scrappa.py", "-", "not-ported", "serp",
     "scrappa.co", "x-api-key", "0.30", POLICY_TIMEOUT,
     "domains:site-fold;recency:native",
     "snippet", "keyed-billed", "keyed-live", "pending-F4"),
    ("search1api", "providers/search1api.py", "-", "not-ported", "serp",
     "api.search1api.com", "Authorization:Bearer", "0.76", POLICY_TIMEOUT,
     "country+language:native;recency:native;ignored-constraints-notice",
     "snippet", "keyed-free-tier", UNTESTED, "pending-F4"),
    ("searxng", "providers/searxng.py", "-", "not-ported", "serp",
     "operator url (config url, no default)", "none", "0.0", POLICY_TIMEOUT,
     "domains:site-fold;recency:native;safe_search:native;title/url/snippet attrs configure the parser",
     "snippet", "self-hosted-free", "local-live-fixture", "pending-F4"),
    ("serpapi", "providers/serpapi.py", "-", "not-ported", "serp",
     "serpapi.com", "api_key request param", "0.0", POLICY_TIMEOUT,
     "domains:site-fold;country+language:native;safe_search:native",
     "snippet", "keyed-free-tier", UNTESTED, "pending-F4"),
    ("serper", "providers/serper.py", "-", "not-ported", "serp",
     "google.serper.dev", "X-API-KEY", "1.00", POLICY_TIMEOUT,
     "domains:site-fold;country+language:native;recency:native(tbs)",
     "snippet", "keyed-billed", "keyed-live", "pending-F4"),
    ("tavily", "providers/tavily.py", "-", "not-ported", "content+answer",
     "api.tavily.com/search", "Authorization:Bearer", "8.00", POLICY_TIMEOUT,
     "domains:native;recency:native(time_range);country:enum-map-else-omit-notice;depth pinned basic",
     "text", "keyed-free-tier-then-metered", "keyed-live", "pending-F4"),
    ("tinyfish", "providers/tinyfish.py", "-", "not-ported", "serp",
     "api.search.tinyfish.ai", "X-API-Key", "0.0", POLICY_TIMEOUT,
     "country+language:native;recency:native;ignored-constraints-notice",
     "snippet", "keyed-free", "keyed-live-free", "pending-F4"),
]

CONFIG_HEADER = [
    "path", "oracle_consumer", "port_consumer", "status", "verification",
]

# status: honoured | transitional (parsed on both sides, the port has not wired
# it yet — the consumer column names what will) | refused (the port refuses the
# value the oracle accepts, pinned as an explicit divergence) |
# declined (permanently uvicorn-only; kept parse-compatible, see the row note)
CONFIG_FIELDS = [
    ("default_provider", "config.py:Config.default_provider -> router/engine", "engine.ml:router table", "honoured", "differential-golden(config)"),
    ("permitted_providers", "config.py:Config.permitted_providers -> router", "engine.ml:permitted set; router.ml:is_permitted", "honoured", "differential-golden(config,router)"),
    ("providers.*.enabled", "config.py:ProviderConfig.enabled", "config.ml:provider_config.enabled -> factory", "honoured", "differential-golden(config)"),
    ("providers.*.cost_per_1k", "config.py:ProviderConfig.cost_per_1k (--check --live reporting)", "factory/factory.ml:probes; usage.ml:journal; engine notice prose", "honoured", "unit(test_grant_wiring)"),
    ("providers.*.depth", "config.py:ProviderConfig.depth (linkup/parallel adapters)", "config.ml:parsed; adapter wave F4", "transitional", "differential-golden(config)"),
    ("providers.*.output_type", "config.py:ProviderConfig.output_type (parallel presets)", "config.ml:parsed; adapter wave F4", "transitional", "differential-golden(config)"),
    ("providers.*.mode", "config.py:ProviderConfig.mode (parallel presets)", "config.ml:parsed; adapter wave F4", "transitional", "differential-golden(config)"),
    ("providers.*.url", "config.py:ProviderConfig.url (searxng required)", "config.ml:parsed + startup rule; adapter wave F4", "transitional", "differential-golden(config)"),
    ("providers.*.app_id", "config.py:ProviderConfig.app_id (algolia required)", "config.ml:parsed; health.ml:probe gate; adapter wave F4", "transitional", "differential-golden(config)"),
    ("providers.*.index", "config.py:ProviderConfig.index (algolia required)", "config.ml:parsed; health.ml:probe gate; adapter wave F4", "transitional", "differential-golden(config)"),
    ("providers.*.title_attr", "config.py:ProviderConfig.title_attr (searxng parser)", "config.ml:parsed; adapter wave F4", "transitional", "differential-golden(config)"),
    ("providers.*.url_attr", "config.py:ProviderConfig.url_attr (searxng parser)", "config.ml:parsed; adapter wave F4", "transitional", "differential-golden(config)"),
    ("providers.*.snippet_attr", "config.py:ProviderConfig.snippet_attr (searxng parser)", "config.ml:parsed; adapter wave F4", "transitional", "differential-golden(config)"),
    ("providers.*.free_cooldown_seconds", "config.py:ProviderConfig.free_cooldown_seconds (TieredExaProvider)", "config.ml:parsed; adapter wave F4 (no tiered adapter yet)", "transitional", "differential-golden(config)"),
    ("policy.max_snippet_chars", "config.py:PolicyConfig -> providers.base.truncate_snippet", "engine.ml:Search capping", "honoured", "unit(test_engine); differential-golden(engine)"),
    ("policy.max_result_text_chars", "config.py:PolicyConfig -> providers.base.truncate_text", "engine.ml:Search capping", "honoured", "unit(test_engine)"),
    ("policy.provider_timeout_seconds", "config.py:PolicyConfig -> factory grant", "factory/factory.ml:grant_of_operation timeout", "honoured", "loopback-integration(test_grant_timeouts)"),
    ("fetch.enabled", "config.py:FetchConfig.enabled", "factory/factory.ml:fetch stack build", "honoured", "unit(test_fetch_engine)"),
    ("fetch.extractor", "config.py:FetchConfig.extractor (trafilatura default)", "config.ml:default stdlib; refuses trafilatura", "refused", "explicit-divergence(goldens config/49 + extractor default)"),
    ("fetch.timeout_seconds", "config.py:FetchConfig.timeout_seconds", "factory/factory.ml:fetch grant", "honoured", "loopback-integration(test_fetch_http)"),
    ("fetch.max_download_bytes", "config.py:FetchConfig", "fetch/fetcher.ml:body bound", "honoured", "unit(test_fetch)"),
    ("fetch.max_text_chars", "config.py:FetchConfig", "fetch/fetcher.ml + extractors", "honoured", "unit(test_fetch)"),
    ("fetch.min_text_chars", "config.py:FetchConfig", "fetch/extractors/stdlib.ml; engine.ml", "honoured", "unit(test_fetch)"),
    ("fetch.max_match_chars", "config.py:FetchConfig", "engine.ml:query windows; jsondoc/select budgets", "honoured", "unit(test_engine); differential-golden(jsondoc)"),
    ("fetch.max_redirects", "config.py:FetchConfig", "fetch/fetcher.ml:chain bound", "honoured", "loopback-integration(test_fetch_http)"),
    ("fetch.allow_private_addresses", "config.py:FetchConfig -> fetcher.resolve_public", "config.ml:parsed; SSRF guard F-schedule (fetch finding)", "transitional", "differential-golden(fetch url)"),
    ("fetch.allow_images", "config.py:FetchConfig", "fetch/fetcher.ml:sniff + carry; factory grant", "honoured", "unit(test_fetch)"),
    ("fetch.user_agent", "config.py:FetchConfig", "fetch/fetcher.ml:header; factory grant", "honoured", "unit(test_fetch_http)"),
    ("fetch.fallback", "config.py:FetchConfig -> KNOWN_FALLBACKS validation", "config.ml:validated names; fetch-fallback wave F6", "transitional", "differential-golden(config)"),
    ("fetch.auto_fallback", "config.py:FetchConfig", "engine.ml:Fetch walk", "honoured", "unit(test_fetch_engine)"),
    ("fetch.primary", "config.py:FetchConfig -> resolve_fetch", "engine.ml/router.ml:fetch table", "honoured", "differential-golden(router fetch)"),
    ("fetch.cost_per_1k", "config.py:FetchConfig (reporting only)", "config.ml:parsed; F6 fallbacks", "transitional", "differential-golden(config)"),
    ("fetch.crawl4ai_url", "config.py:FetchConfig -> Crawl4aiFetcher", "config.ml:parsed; F6 fallback wave", "transitional", "differential-golden(config)"),
    ("fetch.crawl4ai_token", "config.py:FetchConfig -> Crawl4aiFetcher", "config.ml:parsed; F6 fallback wave", "transitional", "differential-golden(config)"),
    ("fetch.crawl4ai_timeout_seconds", "config.py:FetchConfig -> Crawl4aiFetcher", "config.ml:parsed; F6 fallback wave", "transitional", "differential-golden(config)"),
    ("fetch.cache_dir", "config.py:FetchConfig -> pagecache", "config.ml:parsed; F7 page cache (engine.mli: not on the served path yet)", "transitional", "differential-golden(config)"),
    ("fetch.cache_max_bytes", "config.py:FetchConfig -> pagecache", "config.ml:parsed; F7 page cache", "transitional", "differential-golden(config)"),
    ("fetch.cache_max_entry_bytes", "config.py:FetchConfig -> pagecache", "config.ml:parsed; F7 page cache", "transitional", "differential-golden(config)"),
    ("fetch.cache_ttl_seconds", "config.py:FetchConfig -> pagecache", "config.ml:parsed; F7 page cache", "transitional", "differential-golden(config)"),
    ("search.fallback", "config.py:SearchConfig -> fallback_rungs", "engine.ml:Search ladder; router.ml:fallback_rungs", "honoured", "differential-golden(router,engine)"),
    ("search.free_fallback", "config.py:SearchConfig -> free walk", "engine.ml; router.ml:free_walk", "honoured", "differential-golden(router,engine)"),
    ("search.health_interval_seconds", "config.py:SearchConfig -> HealthMonitor", "server.ml:monitor; health.ml", "honoured", "unit(test_health_monitor)"),
    ("search.health_failure_threshold", "config.py:SearchConfig -> HealthBoard", "health.ml", "honoured", "unit(test_health); differential-golden(engine)"),
    ("search.health_cooldown_seconds", "config.py:SearchConfig -> HealthBoard", "health.ml", "honoured", "unit(test_health); differential-golden(engine)"),
    ("agent.enabled", "config.py:AgentConfig (off by default)", "server.ml:tool registration; agent.ml", "honoured", "unit(test_agent, test_p8_server)"),
    ("agent.base_url", "config.py:AgentConfig", "agent.ml:model client grant", "honoured", "unit(test_agent)"),
    ("agent.model", "config.py:AgentConfig", "agent.ml", "honoured", "unit(test_agent)"),
    ("agent.timeout_seconds", "config.py:AgentConfig", "factory/factory.ml:answer grant", "honoured", "loopback-integration(test_grant_timeouts)"),
    ("agent.model_timeout_seconds", "config.py:AgentConfig", "factory/factory.ml + agent.ml", "honoured", "loopback-integration(test_grant_timeouts)"),
    ("agent.max_material_chars", "config.py:AgentConfig", "agent.ml:material cap", "honoured", "unit(test_agent)"),
    ("agent.max_output_tokens_brief", "config.py:AgentConfig", "agent.ml:one model call", "honoured", "unit(test_agent)"),
    ("agent.max_output_tokens_report", "config.py:AgentConfig", "agent.ml:one model call", "honoured", "unit(test_agent)"),
    ("agent.max_cost_usd", "config.py:AgentConfig (per-call ceiling)", "agent.ml:ceiling over usage totals", "honoured", "unit(test_agent)"),
    ("agent.cost_per_1k_in", "config.py:AgentConfig (reporting)", "agent.ml/usage.ml:cost prose", "honoured", "unit(test_agent)"),
    ("agent.cost_per_1k_out", "config.py:AgentConfig (reporting)", "agent.ml/usage.ml:cost prose", "honoured", "unit(test_agent)"),
    ("logging.level", "config.py:LoggingConfig -> logs.py", "log.ml:stderr setup", "honoured", "unit(test_log)"),
    ("logging.format", "config.py:LoggingConfig (text|json)", "log.ml:renderer choice", "honoured", "unit(test_log)"),
    ("logging.library_level", "config.py:LoggingConfig -> uvicorn loggers", "config.ml:parsed; uvicorn-specific, port decision open", "declined", "differential-golden(config)"),
    ("logging.access_log", "config.py:LoggingConfig -> uvicorn access log", "config.ml:parsed; uvicorn-specific, port decision open", "declined", "differential-golden(config)"),
    ("logging.log_queries", "config.py:LoggingConfig -> engine binds", "engine.ml:bind gating", "honoured", "unit(test_engine); differential-golden(engine events)"),
    ("logging.log_content", "config.py:LoggingConfig -> search.result/answer, fetch.content", "engine.ml:content events", "honoured", "unit(test_engine)"),
    ("dashboard.enabled", "config.py:DashboardConfig -> server routes", "server.ml:route registration; dashboard_html.ml", "honoured", "unit(test_p8_server)"),
    ("dashboard.history_path", "config.py:DashboardConfig -> UsageRecorder journal", "usage.ml:journal; factory/factory.ml:startup read", "honoured", "unit(test_usage)"),
]

BEHAVIOURS_HEADER = [
    "behaviour", "oracle", "oracle_suite", "port", "port_suite", "status", "verification",
]

BEHAVIOURS = [
    ("routing decisions: resolve, permit, free walk, rungs, refusal sentences",
     "router.py", "tests/test_router.py", "lib/router.ml", "test_router.ml + corpus/router",
     "ported", "unit; differential-golden"),
    ("stdlib-only routing core (no seekwright imports)", "router.py imports", "tests/test_router.py", "lib/router.ml", "test/dune ocamldep rule", "ported", "unit(build-time)"),
    ("config parsing, defaults, validation, refusal sentences",
     "config.py", "tests/test_config.py", "lib/config.ml", "test_config.ml + test/differential/corpus/config",
     "ported", "unit; differential-golden"),
    ("special-token escaping (reversible, idempotent, byte-level)",
     "sanitize.py", "tests/test_sanitize.py", "lib/sanitize.ml", "test_sanitize.ml + corpus/sanitize",
     "ported", "unit; differential-golden"),
    ("wire models: unset dropped, TEXT_FIELDS escaped, provider-boundary nulls kept",
     "models.py WireModel", "tests/test_models.py", "lib/model.ml", "test_model.ml + corpus/model",
     "ported", "unit; differential-golden; explicit-divergence(coercion)"),
    ("search engine walk: ladder, health gate, notices, caps, events",
     "engine.py SearchEngine", "tests/test_engine.py", "lib/engine.ml", "test_engine.ml + corpus/engine",
     "ported", "unit; differential-golden"),
    ("fetch URL guardrails, windowing, caps, image sniffing",
     "fetcher.py", "tests/fetch/", "lib/fetch/fetcher.ml", "test_fetch.ml + corpus/fetch",
     "ported", "unit; differential-golden"),
    ("JSON document rendering, schema view, path selection",
     "jsondoc.py", "tests/fetch/test_jsondoc.py", "lib/fetch/jsondoc.ml", "test_jsondoc.ml + corpus/jsondoc",
     "ported", "unit; differential-golden"),
    ("CSV/TSV table rendering over the same line grammar",
     "tabledoc.py", "tests/fetch/test_tabledoc.py", "lib/fetch/tabledoc.ml", "test_tabledoc.ml + corpus/tabledoc",
     "ported", "unit; differential-golden"),
    ("provider contract: errors, ignored_constraints, cost_for",
     "providers/base.py", "tests/providers/test_provider_contract.py", "lib/provider.ml", "test_provider_contract.ml",
     "ported", "unit"),
    ("two scripted adapter parity (anysearch, freeserp)",
     "providers/anysearch.py, providers/freeserp.py", "tests/providers/test_anysearch.py, tests/providers/test_freeserp.py",
     "lib/providers/anysearch.ml, lib/providers/freeserp.ml", "test_anysearch.ml, test_freeserp.ml",
     "ported", "unit(scripted transport); keyless-live"),
    ("the other fifteen adapters", "providers/", "tests/providers/, tests/live/test_live.py", "(none)", "(none)",
     "not-ported", "pending-F4"),
    ("health board + monitor", "health.py", "tests/test_health.py", "lib/health.ml", "test_health.ml, test_health_monitor.ml",
     "ported", "unit"),
    ("usage journal and in-memory totals", "usage.py", "tests/test_usage.py", "lib/usage.ml", "test_usage.ml",
     "ported", "unit"),
    ("agent mode: fixed plan, one model call, validated citations, ceiling",
     "agent.py", "tests/test_agent.py", "lib/agent.ml", "test_agent.ml",
     "ported", "unit"),
    ("MCP server: three tools, stdio+HTTP transports, route guards",
     "server.py", "tests/test_server.py, tests/features/", "lib/server.ml", "test_server.ml, test_p8_server.ml, test_http_transport.ml",
     "ported", "unit; loopback-integration; official-conformance(test/conformance)"),
    ("REST projection + CLI verbs + --check", "server.py routes, cli.py", "tests/repo/test_surface.py, tests/features/", "(pending: F-series server surface)", "test_p8_surface.ml covers what is wired",
     "partial", "unit"),
    ("logging discipline (event names, binds, no tracebacks, stderr only)",
     "logs.py", "tests/test_logs.py", "lib/log.ml", "test_log.ml",
     "ported", "unit"),
    ("page cache", "(none — deliberately absent)", "n/a", "(parsed config only)", "n/a",
     "not-ported", "pending-F7"),
    ("extraction backends", "extractors/ (trafilatura, stdlib)", "tests/fetch/", "lib/fetch/extractors/stdlib.ml only", "test_fetch.ml, corpus/config extractor refusals",
     "partial", "explicit-divergence(trafilatura refused on the port)"),
    ("transport security (Host allowlist, /healthz outside it, origin checks)",
     "server.py _transport_security", "tests/test_server.py", "lib/server.ml + mcp-kit", "test_http_transport.ml, conformance transcript",
     "ported", "loopback-integration; official-conformance"),
]

SURFACE_HEADER = [
    "item", "kind", "oracle", "port", "status", "verification",
]

SURFACE = [
    ("search tool", "mcp-tool", "server.py:search", "lib/server.ml", "honoured", "official-conformance; unit(test_server)"),
    ("fetch tool", "mcp-tool", "server.py:fetch", "lib/server.ml", "honoured", "official-conformance; unit(test_server)"),
    ("answer tool", "mcp-tool", "server.py:answer", "lib/server.ml (off by default, like the oracle)", "honoured", "unit(test_agent, test_p8_server)"),
    ("POST /api/v1/search", "rest-route", "server.py", "lib/server.ml", "honoured", "unit(test_p8_server)"),
    ("POST /api/v1/fetch", "rest-route", "server.py", "lib/server.ml", "honoured", "unit(test_p8_server)"),
    ("POST /api/v1/answer", "rest-route", "server.py (404 while agent off)", "lib/server.ml", "honoured", "unit(test_p8_server)"),
    ("GET /healthz", "operational-path", "server.py", "lib/server.ml", "honoured", "unit(test_p8_server); loopback-integration(test_http_transport)"),
    ("GET /dashboard", "operational-path", "server.py + dashboard.py", "lib/server.ml + dashboard_html.ml", "honoured", "unit(test_p8_server)"),
    ("seekwright search|fetch|answer (client verbs)", "cli", "cli.py argv[0] dispatch", "(pending F-series)", "not-ported", "pending"),
    ("seekwright --check", "cli", "cli.py", "bin/main.ml + factory probes", "honoured", "unit(test_boot)"),
    ("seekwright --http", "cli", "cli.py", "bin/main.ml", "honoured", "loopback-integration(test_http_transport)"),
    ("stdio JSON-RPC session (blessed transcript)", "transport", "server.py stdio", "bin/main.ml + bin/smoke.jsonl", "honoured", "official-conformance(bin/smoke.expected)"),
    ("--host/--port/--path/--allowed-host and friends (ten flags)", "cli-flags", "cli.py", "bin/main.ml (wired set pinned by test_p8_surface.ml)", "partial", "unit(test_p8_surface)"),
    ("seventeen provider names", "config-vocabulary", "config.py KNOWN_PROVIDERS", "config.ml known_providers; cross-checked by test_differential_matrix", "honoured", "differential-golden(config); unit(matrix)"),
    ("log events search.ok/failed/attempt/gate + content events", "journal", "engine.py binds", "engine.ml event list", "honoured", "differential-golden(engine events)"),
    ("usage journal fields", "journal", "usage.py", "usage.ml", "honoured", "unit(test_usage)"),
]


def write(name: str, header: list[str], rows: Sequence[Sequence[str]]) -> None:
    MATRIX.mkdir(parents=True, exist_ok=True)
    lines = ["\t".join(header)]
    for row in rows:
        assert len(row) == len(header), name
        assert all(cell.strip() for cell in row), (name, row)
        lines.append("\t".join(row))
    (MATRIX / name).write_text("\n".join(lines) + "\n")
    print(f"{name}: {len(rows)} rows")


write("providers.tsv", PROVIDERS_HEADER, PROVIDERS)
write("config-fields.tsv", CONFIG_HEADER, CONFIG_FIELDS)
write("behaviours.tsv", BEHAVIOURS_HEADER, BEHAVIOURS)
write("surface.tsv", SURFACE_HEADER, SURFACE)
