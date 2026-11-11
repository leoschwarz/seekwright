(** The routing decisions: which provider answers, in what order, and what is said.

    This module decides; the engine executes (P5). A caller hands it a routing
    [table] — the deployment's routing facts as plain strings and lists — plus
    the request, and it answers with a name, an ordered plan of rungs, or the
    sentence that refuses. Same inputs, same outputs: no I/O, no clock, no
    state, and it names **no** other module, which is the seam the Python
    [src/seekwright/router.py] documents and the reason a rewrite in another
    language implements it 1:1 with the engines as its clients. The table
    fields are that future wire contract; serialising one is deliberately not
    defined yet.

    The guard is machine-checked twice: the library stanza in [lib/dune]
    declares no [libraries], so this module could not reach [Mcp_caps] even by
    accident — the compile refuses it — and the [ocamldep] diff in [test/dune]
    pins what it depends on inside the library, so it cannot lean on a later
    seekwright module either (the port of [tests/test_router.py]'s stdlib-only
    case).

    What belongs here is *which*, *in what order*, and the routing-facing
    sentences that explain an outcome: refusals, substitution notices,
    exhaustion notes, retry menus. Dispatch, the health board, usage and
    logging stay in the engine, and so does any notice that is about a result
    rather than a route — the zero-results diagnostic in the search engine is
    the example. The free-name constants stay in the config module (P3), the
    frozen vocabulary the validators read; they arrive here as table fields
    rather than as an import. *)

(** A provider name: [backend] or [backend:flavour] ([exa], [exa:free]). Plain
    [string] on purpose — the routing core is what a compiled rewrite
    reproduces, and a name is what its table is made of. *)
type name = string

(** A routing refusal decided before any dispatch; the payload is the
    model-facing sentence.

    The engine translates it into its own refused exception — the search and
    fetch refusals — because the REST projection reports those as 400: nothing
    was billed, and the caller can act on the sentence. *)
exception Route_refused of string

(** Why a ladder entry is or is not a candidate, decided before any dispatch. *)
type rung_status =
  | Skip  (** tried already, or enabled-but-unbuilt: silent *)
  | Unpermitted
  | Open  (** health breaker open *)
  | Candidate

(** One ladder entry with its status, in ladder order. *)
type rung = { name : name; status : rung_status }

val show_rung_status : rung_status -> string
(** [show_rung_status s] is the lowercase word Python's [RungStatus] value
    carries. Nothing on the wire prints a status today — the engine branches on
    identity — so this exists for logs and for test failure output. *)

(** The search routing facts of one deployment, read off live engine state.

    [providers] is what was *built*, [effective] is what may be *dispatched*
    (enabled ∩ permitted), and the two are not the same: a deployment can
    enable a name it could not build. The free-set questions read [effective],
    so a permission set that removes every free name empties the free walk
    rather than leaving it something to serve.

    [free] is a set in the Python table (a [frozenset]): [free_providers] there,
    so it carries no duplicates and a sentence renders it sorted.

    A [table] is a value: copying it or comparing two built from the same facts
    is meaningful, which is what lets a caller hand the same facts to two calls. *)
type search_table = {
  providers : name list;  (** built adapters, dispatch order (dict order) *)
  default : name option;  (** config default_provider *)
  permitted : name list option;  (** [None] = permissive *)
  fallback : name list;  (** [search] fallback *)
  free_fallback : name list;  (** [search] free_fallback; empty reads as unset *)
  free : name list;  (** config.FREE_PROVIDERS: names that cannot bill *)
  free_order : name list;  (** config.FREE_PROVIDER_ORDER *)
  effective : name list;  (** enabled ∩ permitted (config.effective_providers) *)
}

(** The fetch routing facts: what was built, and which name leads.

    [primary] is [None] when the local reader leads, which is the shape the
    sentences need: "read the page locally" and "local fetch" are what a caller
    is offered when nothing remote leads the route. *)
type fetch_table = {
  built : name list;  (** built fallback names, ladder order *)
  primary : name option;  (** [None] = the local http reader leads *)
}

(** What [search(mode="free")] declares. Python's [Literal["free"]] has one
  inhabitant, so the OCaml port makes it a variant rather than a string: a
  mode the router has never heard of becomes unrepresentable instead of a
  runtime comparison. *)
type search_mode = Free

val is_permitted : search_table -> name -> bool
(** [is_permitted table name] is whether [name] may be dispatched to at all.
    Unset is permissive. *)

val unnamed_walks_free : search_table -> bool
(** Whether an unnamed search is served by the free walk, not the default.

    True only where the substitution cannot spend: no default configured *and*
    every reachable name free. A single enabled provider never reaches it —
    config gives that one the default.

    Both halves read [effective], never [providers]: "every *enabled* provider
    is free" is the rule, so a deployment that enabled a name it could not
    build still refuses. *)

val free_candidates : search_table -> name list
(** The names a free walk considers, before any filter.

    [search.free_fallback] when the operator set one — their order — else
    [FREE_PROVIDER_ORDER]. An empty [free_fallback] reads as unset. *)

val free_walk : search_table -> name list
(** The fallbacks the free routes walk, in order, every one of them free.

    Serves both [mode=Free] and an unnamed all-free search: one walk, so the
    two routes cannot drift apart.

    Drops a fallback that is unbuilt or unpermitted. The free-set check is
    redundant with config validation on purpose: "never dispatch outside the
    free set" is this mode's whole promise, so it is a condition in the code. *)

val resolve_search : search_table -> ?mode:search_mode -> name option -> name
(** Pick the provider to call, or raise [Route_refused] explaining why the
    request cannot be served.

    Nothing is inferred from the query. A named provider is terminal; an
    unnamed search takes [default] and may be walked by the free route.
    [~mode:Free] resolves to the first fallback of the free walk and never
    consults [default]: a paid default must not leak into a mode whose promise
    is a ceiling of zero.

    The allow-list is enforced after the enabled check and before the name is
    returned, so an unpermitted [default] is refused rather than silently
    served by the ladder configured behind it. *)

val fallback_rungs : search_table -> ladder:name list -> tried:name -> gated:name list -> rung list
(** One [rung] per ladder entry, in ladder order, before any dispatch.

    [ladder] is the caller's argument, not the table's field, because the two
    free routes pass their own: [mode=Free] and an unnamed all-free search walk
    [free_walk], which cannot contain a paid name. Statuses fall out in one
    order on purpose: tried/unbuilt before unpermitted before open, so the
    silent skip cannot steal the log line a permitted-but-gated name deserves.

    [gated] is the set whose breaker is open at walk time rather than a live
    board: a walk only writes the board for names it has attempted, and each
    name appears at most once, so nothing ahead of the walk can change under
    it. *)

val fallback_served_notice : tried:name -> original_reason:string -> fallback:name -> notice:string option -> string
(** The substitution sentence, with the fallback's own notice beside it.

    A [notice] that is the empty string reads as [None]: Python's condition is
    truthiness, and a sentence ending in "; " is not a sentence. *)

val fallback_exhausted_note : failed:name list -> mode:search_mode option -> string
(** What the failure sentence adds when every fallback lost.

    The failed names are what the caller could not see being tried; [mode]
    adds the sentence saying why nothing paid was tried, because the model
    cannot see the walk. *)

val retry_advice : quota:bool -> string
(** Quota means retrying now is pointless; anything else may pass with time. *)

val fetch_walk : fetch_table -> name list
(** The ladder the unnamed route walks: the built names minus the primary.

    The primary is out because the route already tried it; walking it twice
    would bill the same name twice. *)

val origin : fetch_table -> string
(** The unnamed route's first attempt, as a sentence names it. *)

val provider_names : fetch_table -> string
(** The providers this server built, in ladder order.

    Built names, not configured ones: a caller can only be told to name
    something this server can serve. The [--check] rows are the other read —
    they come from [fetch.fallback], because that is where *why a configured
    name was not built* is reported. *)

val choose_names : fetch_table -> string
(** The names the withheld walk leaves over: the walk, never the primary. *)

val choose_instead : fetch_table -> string
(** The failed read's recovery: the names to name, and one retry on one of them.

    The half of the deal the withheld walk pays for: the caller is handed the
    choice rather than having it taken. Its wording follows the search's
    zero-results recovery, and it says nothing about *why* a name is missing —
    that stays [--check]'s report.

    With nothing left to walk there is no list, so this returns the empty
    string: a choice with no names in it is not a choice. The menu is the
    walk, never the primary — the route that just failed is not to offer. *)

val not_enabled : fetch_table -> name -> string
(** The refusal sentence: the name it cannot serve, and the names it can.

    It states what *is* available, never *why* the named one is not: [seekwright
    --check] prints one row per configured name with what it is missing, and
    deployment inventory has no place in a model-facing sentence. The closing
    clause offers what omitting [provider] means — the local read while the
    primary is the local reader, else the operator's chosen route. With nothing
    configured the middle clause says so rather than print an empty list. *)

val empty_notice : fetch_table -> walked:bool -> string
(** What a nearly-empty page reports, and what it offers in place of the walk.

    With the walk off the caller gets the choice and the diagnosis: a page that
    extracts to nothing needs a browser, not a second read by the same reader —
    model-facing text over MCP, not only a JSON key. With the walk on the
    ladder already ran and said which name served, and with nothing configured
    there is no name to hand over; both keep the shorter sentence. *)

val refetched_notice : fetch_table -> reason:string -> fallback:name -> string
(** The served-by-a-fallback sentence for a page, naming what failed first. *)

val resolve_fetch : fetch_table -> name option -> name option
(** Route this page: [None] is the local read, a name is that provider.

    Three cases collapse into one refusal, the way [resolve_search] collapses
    its own: a name unknown to the fetch registry, one the registry has but
    this deployment never built for want of a key or URL, and one the
    permission set excluded. All three are refused before anything is
    dispatched, so nothing is billed and the sentence names what this server
    did build. A search-set name like [serper] is the first case. *)
