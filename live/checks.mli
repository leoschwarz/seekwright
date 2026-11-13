(** The live assertions, ported per adapter.

    Port of the assertion bodies in [tests/live/test_live.py], one function per
    case rather than one generic "the call returned something". The Python suite
    asserts the shape each backend documents — a SERP backend fills [snippet]
    and never [text], a content backend the reverse, an answer backend answers,
    a domain filter constrains the URLs — and those are the checks here.

    Pure: a check is a value over the response the runner already has, so the
    entire assertion table is exercised hermetically against synthetic
    responses in [test/live/test_live_cases.ml], and a live run spends a vendor
    call only to produce the response those checks read. *)

module Model = Seekwright.Model

(** One assertion: what it checked, and the sentence to print when it failed.
    [None] is a pass, so a runner can count failures without a second record. *)
type check = { label : string; failure : string option }

val passing : string -> check
(** [passing label] is a check that held with nothing to add. *)

val expect : string -> bool -> string -> check
(** [expect label condition sentence] holds when [condition] does; the sentence
    is what the run prints when it does not, and it states the observed fact,
    never the request (a check sentence can reach a terminal but not a log). *)

(** [provider_step ~name ~step response] is the ported assertion set for one
    step of a provider case, [step] being the zero-based index into
    {!Cases.provider_steps}. It always names the provider first: a response that
    names a different provider is an unexpected call, whether the route
    substituted or the adapter reported the wrong name. A [name]/[step] pair
    with no ported assertion fails loudly rather than passing vacuously — which
    is what keeps a new name from arriving with a generic check. *)
val provider_step : name:string -> step:int -> Model.search_response -> check list

val verify_fetch : Cases.fetch_case -> Model.fetch_response -> check list
(** The shape assertions for a readable fetch case ([Local] today; the three
    third-party fallbacks and Jina join it with F6.1). The cloud-metadata case
    is asserted on the error channel by the runner, because what it proves is a
    refusal, not a page. *)

val verify_agent :
  depth:Model.depth -> model:string -> Model.answer_response -> check list
(** The agent cases' contract: prose, the operator's model, the requested depth,
    a brief call's single search, and — as in Python — citations or the notice
    that says the prose is uncited. Asserting a citation would make the check
    the model's mood rather than the server's contract. *)

val quota_limited : string -> bool
(** Whether a failed live call was refused by quota or a rate limit.

    The engine keeps the provider failure's {!Provider.error_kind} private and
    reports [Failed] with the rendered sentence; the quota branch is the one
    that appends its fixed "Do not retry immediately." advice. A rate-limited
    run therefore reports inconclusive, not pass and not fail: it proves nothing
    about the parser, which is the same distinction the plan records. *)

val failed_count : check list -> int
(** How many checks in the list did not hold. *)

val summary : check list -> string
(** The one-line result a run prints: the pass count, or "n of m checks
    failed". *)
