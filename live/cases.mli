(** The live harness's case inventory: the selector vocabulary, what each case
    needs before it can run, what class of spend it is, and the exact searches
    (query, filters, width) a provider case issues.

    Port of the case table the Python live suite spells as one test function per
    adapter ([tests/live/test_live.py], read-only). Two differences, both
    deliberate:

    - a case is data here, not a test function, so one executable can accept
      exactly one of them by name and skip the ones this build cannot run yet;
      the assertions themselves are ported per adapter in {!Checks}, never one
      generic "the call returned something";
    - a name is not "configured" because a key happens to be in the environment.
      The selector is mandatory, so a billed name is reached only by naming it on
      an invocation whose gate variable is set — never by an "all providers"
      sweep, which this vocabulary cannot express.

    The module is pure: it reads the environment and the provider registry, and
    it dials nothing. The running half is {!Runner}, so a hermetic suite can pin
    the whole inventory without a socket. *)

module Config = Seekwright.Config
module Model = Seekwright.Model

(** One fetch case. [Local] and [Metadata] are the two the local reader answers
    today; the three third-party fallbacks plus the keyless Jina reader are
    named now so the F6 wave inherits a working selector rather than a second
    vocabulary. *)
type fetch_case =
  | Local
  | Metadata
  | Jina
  | Scrappa
  | Tavily
  | Linkup

(** What one invocation selects: exactly one of these, never a set. *)
type selector =
  | Provider of Config.name
  | Fetch of fetch_case
  | Agent of Model.depth

(** One search a provider case issues. Mirrors the Python test's
    [SearchQuery]: the normalised request a provider adapter receives, so a
    filter the adapter folds natively is exercised live rather than only in a
    fixture. *)
type query_spec = {
  query : string;
  max_results : int;
  include_domains : string list;
  exclude_domains : string list;
  country : string option;
  recency : Model.recency option;
}

(** A labelled step: the Python suite's separate live assertions, kept as
    separate calls because that is what they check (a plain search and a
    domain-constrained one are different wire shapes). *)
type step = { label : string; spec : query_spec }

(** How a case is paid for. [Unbilled] is a case that cannot bill: a keyless
    provider, a zero-priced one, or the local reader. [Billed] is everything
    else. The class is the [--list] column and the header line; the figure rides
    beside it where the inventory has one (a fetch fallback's price is the
    vendor page's, not this tree's). *)
type cost_class = Unbilled | Billed

(** Whether this build carries what the case needs. [Deferred wave] names the
    phase in [plans/ocaml-finalisation.md] that lands the adapter: a selected
    but deferred case skips with that wave, which is what makes the harness
    ready for F5 and F6 rather than only for today's build. *)
type build_status = Runnable | Deferred of string

(** Every selector, sorted: the seventeen provider names in
    {!Config.known_providers} order, then the six fetch cases, then the two
    agent depths. *)
val all : selector list

(** [name selector] is the spelling an invocation passes, e.g. ["exa:free"],
    ["fetch:local"], ["agent:report"]. *)
val name : selector -> string

(** [parse spelling] maps one command-line token to a selector. A provider name
    is tried first, so the [backend:flavour] form ([exa:free]) is a provider and
    not a namespace; then ["fetch:<case>"] and ["agent:brief"|"agent:report"].
    ["all"], ["*"] and the empty string are refused: the harness has no
    all-providers mode on purpose. *)
val parse : string -> (selector, string) result

(** The searches a provider case issues, in order. Empty for a name outside the
    frozen seventeen; every name inside it has at least one step, and a billed
    name's step count is what its cost line counts. *)
val provider_steps : Config.name -> step list

(** The provider entry the harness builds for a case: the defaults, plus the
    config-derived value the name cannot run without ([searxng]'s instance from
    [SEEKWRIGHT_SEARXNG_URL], [algolia]'s public [app_id] and [index] from
    [SEEKWRIGHT_ALGOLIA_APP_ID]/[SEEKWRIGHT_ALGOLIA_INDEX] — the same live-test
    fixture names the Python suite uses). [Error sentence] is a skip reason
    naming the variable, never echoing a value. *)
val provider_config : Config.name -> (Config.provider_config, string) result

val build_status : selector -> build_status

val cost_class : selector -> cost_class

(** The spend sentence: the class, the price and width where the inventory has
    them, and the free-twice cases spelled out ([exa]'s free tier first; a
    keyed name the vendor charges nothing for). No secret, no URL query. *)
val cost_prose : selector -> string

(** The environment variables the case needs, by name only — a key is never
    read here, and never printed anywhere. [["nothing"]] when the case needs no
    credential. *)
val needs : selector -> string list

(** Where the case dials, as [scheme://host] or a phrase for a destination only
    config can supply. Host only: a base URL's path is not printed either. *)
val route : selector -> string

(** The credential line: the variable name, or a keyless sentence. *)
val credential : selector -> string

(** How many provider/model calls one run spends, for the cost line: a search
    per step, one page for [fetch:metadata] (refused before it is sent), one
    model call per agent depth. *)
val call_count : selector -> int

(** Whether this port has a recorded OCaml live run of the case. A provider
    reads the registry row's [ocaml_live_tested] — the one field [--check]
    discloses from, so the harness and the diagnosis cannot disagree. The fetch
    and agent cases have no registry row, so they read the explicit list below,
    which a change appends to only when it records that run in
    [plans/seekwright-ocaml-port.md]. *)
val live_status : selector -> [ `Tested | `Untested ]

(** The usage text, shared by [--help] and the misuse refusal. *)
val usage : string

(** The selector spellings whose OCaml live run is recorded for a case with no
    registry row (fetch and agent). Empty on this branch: F4.3 lands the runner,
    and the first recorded runs retire entries from here in the change that
    records them. *)
val recorded_non_provider_runs : string list
