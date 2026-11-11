(** Agent mode: the [answer] tool's engine — a fixed retrieval plan feeding
    exactly one model call, with server-validated citations.

    Port of [src/seekwright/agent.py], under the contract in
    [docs/reference/agent-mode.md]. One rule carries the whole design: **the
    model never drives retrieval**. The server decides what to retrieve — the
    caller's question plus at most two extra queries, five results each, and up
    to three pages for [depth = "report"] — and the model writes prose over that
    material. A loop in which the model asks for another search would make the
    per-call cost the model's decision; a fixed plan costs a bounded amount by
    arithmetic, so there is exactly one model call per [answer] and no loop
    anywhere in this module.

    The retrieval steps run through the same {!Engine.Search} and
    {!Engine.Fetch} the [search] and [fetch] tools use — the plan's page reads
    pass [~auto_fallback:true] because no caller stands between the steps to act
    on a refusal — so the provider ladder, the health board, the SSRF guardrails
    and the journal lines behave as they do for a plain call. The model client
    is one POST to an OpenAI-compatible [/chat/completions] on the shared HTTP
    seam ({!Provider.Net.t}, the same record the adapters dial through, backed
    in a running server by a [Mcp_caps.Authority.Net] grant scoped to the model
    endpoint): no SDK, no tokenizer — the endpoint reports [usage].

    The model, the system prompt, the temperature and the token budgets are the
    server's, never tool parameters; [answer] takes only the question, the
    extra queries, the depth, a provider pin and the [search]-shaped filters.
    Citations are the server's too: the prose's [[n]] markers are validated
    against what was retrieved, and only the prose is the model's.

    Failure is a returned value, as in the rest of the port: [answer] answers
    [Error message] where Python raises [AgentFailed], and the message is
    written for the model. Every path — failures included — writes the one
    [answer] journal line first, so the retrieval spend a call already incurred
    has a line to sit beside. *)

(** {1 The plan's constants}

    The plan's width, as constants rather than config: these counts bound the
    per-call cost, and the tool schema is frozen at import so nothing
    config-derived could reach it anyway. *)

val results_per_query : int
(** [max_results] on every retrieval step: 5. *)

val pages_per_report : int
(** Pages a [report] reads at most: 3. *)

val temperature : float
(** The server's, never the caller's: 0.2. *)

val answer_system_prompt : string
(** The system prompt, verbatim from the Python tree's
    [src/seekwright/resources/answer_system.txt] (trailing newline included,
    as [prompts.ANSWER_SYSTEM_PROMPT] reads it). *)

(** {1 The engine} *)

type t
(** Run the fixed plan, make the one model call, validate what it cited. Borrows
    the process's search engine, fetch engine, HTTP seam and usage recorder. *)

val create :
  Config.t ->
  net:Provider.Net.t ->
  Engine.Search.t ->
  ?fetch_engine:Engine.Fetch.t ->
  ?usage:Usage.t ->
  ?log:Engine.log ->
  clock:(unit -> float) ->
  now:(unit -> float) ->
  unit ->
  t
(** [create config ~net engine ~clock ~now ()]. [~clock] is monotonic seconds
    ([time.monotonic()]) and feeds the [ms] fields, the whole-call timeout and
    the ceiling's bookkeeping; [~now] is UTC wall seconds and stamps only
    [retrieved_at].

    [?fetch_engine] absent is [[fetch] enabled = false]: a [report] is still
    served from snippets alone, with a notice saying no pages could be read.
    [?usage] absent means nothing is journalled; the spend ceiling then reads
    0.0, as Python's does with no recorder. *)

val answer :
  t ->
  query:string ->
  ?extra_queries:string list ->
  ?depth:Model.depth ->
  ?provider:Config.name ->
  ?include_domains:string list ->
  ?exclude_domains:string list ->
  ?recency:Model.recency ->
  ?language:string ->
  ?safe_search:bool ->
  unit ->
  (Model.answer_response, string) result
(** Answer one question: fixed plan, one model call, validated citations.

    [depth = None] means [brief], the tool's default. [provider] pins retrieval
    exactly as [search] does — that provider or an error, and an unpermitted
    pin fails before any model call, because the retrieval *is* the search
    path. The whole call is bounded by [[agent] timeout_seconds]; a call that
    exceeds it answers [Error] naming the phase it reached, and a retrieval
    walk with nothing usable to ground on fails without any model call. *)
