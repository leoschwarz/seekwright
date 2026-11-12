(** Execution around the routing decisions: dispatch one query, dispatch one page.

    Port of [src/seekwright/engine.py]. Both engines ask {!Router} *which* name
    serves and in what order, call it, record the outcome on the health board and
    the journal, and turn a provider failure into a sentence a model can act on.
    The decisions themselves live in [lib/router.ml] and are not repeated here —
    this module's job is the walk, the logging, the counting, and the notices
    that describe a {i result} rather than a route.

    {1 Failure is a returned value}

    Python raises [SearchRefused] / [SearchFailed] and [FetchRefused] /
    [FetchFailed]; the split matters because the REST projection reports a
    refusal as 400 and a failure as 502, and a refusal means {i nothing was
    billed}. This module returns it as a variant with the same two cases, per
    engine. Like P4's [Provider] contract — where [raise ProviderError] became an
    [Error] channel — nothing in here raises, so a fallback walk is one
    control-flow shape rather than [try] around a call boundary.

    {1 The clocks}

    Two, both injected, because a library with no [unix] dependency has no clock
    of its own: [~clock] is monotonic seconds ([time.monotonic()]) and feeds every
    [ms] field and the health board's cooldowns; [~now] is UTC wall seconds and
    feeds only [retrieved_at] and the journal's day buckets. A test hands in a
    counter and asserts an exact [ms] instead of a range, which is what lets
    [search.ok]'s field set be pinned line for line.

    {1 The log}

    The same sink type {!Usage} and {!Health} take, so P8 hands one function to
    all three. The Python code carries a {i bound} [Logger] through a call —
    [bind(provider=…, qlen=…, qhash=…)] once, then [.bind(…).info(event)] per
    event — and the shape of those bound fields {i is} the operator-facing
    contract ([AGENTS.md]: a message is a constant dotted event name, values go
    through [bind]). So the bound fields are threaded as a list, and every event
    here emits base fields then event fields, which is loguru's merge order.

    {1 What is not here yet}

    The disk page cache ([pagecache.py], P6): {!Fetch} takes the {!Readers} seam
    — [jsondoc]/[tabledoc]/[select_passages], also P6 — because a page read that
    may select a subtree or a passage needs them, and Python's {i no-cache} path
    ([self.cache is None]) is the path this port serves today: every read
    dispatches, so the [cached] flag on [fetch.ok] is always [false] and every
    journal line is priced. Adding the cache is a change to {!Fetch.read_page},
    which is where the flag is decided. *)

(** {1 Shared types} *)

type log = Log.log
(** The sink type is {!Log}'s, aliased here so the four modules that take one
    name the same type — style review M1. *)

(** {1 The search engine} *)

module Search : sig
  type error =
    | Refused of string  (** nothing billed; the caller can act (REST 400) *)
    | Failed of string  (** a provider failed, or the walk behind it did (502) *)
  (** [SearchRefused] / [SearchFailed]. *)

  type t

  val create
    :  Config.t ->
    ?health:Health.t ->
    ?usage:Usage.t ->
    ?log:log ->
    (Config.name * Provider.t) list ->
    clock:(unit -> float) ->
    now:(unit -> float) ->
    unit ->
    t
  (** [create config providers ~clock ~now ()]. The registry is an association
      list in dispatch order, where Python holds a dict: its order decides the
      zero-results notice's "other enabled providers" list and the routing
      table's [providers] field, so it is kept, not sorted.

      [?health] absent is a fresh board, as in Python's tests and [--check]; the
      server passes the shared one so the engine and the health monitor agree on
      who is up. That board's cooldowns read [~clock]. *)

  val providers : t -> Config.name list
  (** The registry's names, in dispatch order. Python reaches for
      [engine.providers] from tests and [--check]; this is the same read. *)

  val resolve :
    t -> ?mode:Router.search_mode -> Config.name option -> (Config.name, string) result
  (** Which name would serve, or the refusal. Pure: no dispatch, no logging. The
      sentence is {!Router}'s verbatim — [Engine] only translates
      [Router.Route_refused] into its own failure channel. *)

  val search :
    t ->
    ?provider:Config.name ->
    ?mode:Router.search_mode ->
    ?run:string ->
    ?step:int ->
    Model.search_query ->
    (Model.search_response, error) result
  (** Dispatch one query, recording it on the board and the journal.

      A named provider is terminal. An unnamed search takes [default_provider]
      and walks [search.fallback] when that fails; where no default is
      configured and every reachable name is free it walks the free set instead.
      [~mode:Free] is served only by providers that cannot bill and fails rather
      than escalating. [~run]/[~step] tag one retrieval step of an [answer] call
      so the journal can tie results to citations. *)
end

(** {1 The fetch engine} *)

module Fetch : sig
  (* Equated aliases for [Seekwright_wire.Page]: this interface and
     [Fetcher.fetched_page] name the same record, so nothing between the two has
     to copy it and a field cannot be added on one side only (style review M5). *)
  type image = Seekwright_wire.Page.image = {
    media_type : string
  ;  (** the type the body's own bytes agreed with, not the server's header *)
    body : string  (** the bytes, whole *)
  }

  type page = Seekwright_wire.Page.page = {
    url : string  (** where the fetch landed, after any redirects *)
  ; title : string option
  ; text : string
  ; content_type : string option
  ; status_code : int
  ; truncated : bool
  ; total_chars : int  (** the whole extraction, not this window *)
  ; path_addressable : bool  (** [text] is a structure this build rendered *)
  ; image : image option
  }

  type cap =
    | Default  (** this fetcher's own configured [fetch.max_text_chars] *)
    | Limit of int
    | Uncapped
  (** [max_chars], including Python's [UNCAPPED] sentinel and its [None]. A
      sentinel integer would let an [Uncapped] reach a window computation as a
      number, so the port makes it a constructor. *)

  type error =
    | Refused of string  (** nothing billed; the caller can act (REST 400) *)
    | Failed of string  (** a page could not be produced (502) *)
  (** [FetchRefused] / [FetchFailed]. *)

  type fetch_error =
    | Provider of Provider.error  (** a fetch provider's own failure *)
    | Url_blocked of string  (** a guardrail refused the URL as written (400) *)
    | Redirect_blocked of string  (** …with a request already in flight (502) *)
    | Fetch_blocked of string  (** any other policy refusal mid-flight *)
  (** What a {!fetcher} reports, where Python raises the [ProviderError]
      subclasses. This is how the engine reads the three [isinstance] arms it
      needs: a [FetchBlocked] is levelled [fetch.blocked] rather than
      [fetch.failed], is never offered the ladder as a choice, and is not
      retryable; and only [UrlBlocked] — refused before any request went out —
      becomes {!Refused}. [Redirect_blocked] is a sibling of [Url_blocked] and
      not its parent, for exactly that reason. *)

  type fetcher = {
    name : Config.name
  ; cost_per_1k : float option  (** [None] is "no price to record", not "free" *)
  ; fetch :
      url:string -> offset:int -> max_chars:cap -> (page, fetch_error) result
  ; aclose : unit -> unit
  }
  (** [fetcher.ContentFetcher], as a record rather than a module type: the ladder
      holds several of them at runtime and reads a field off the {i object} that
      served ([_fallback_cost_usd]), which is what a value gives and a module
      does not. *)

  module Readers : sig
    type selection = int * string
    (** One span of a selection: its [offset] into the {i full} rendering and its
        [text]. Python returns the same pair, and the offsets are what a caller
        uses to continue a read, so they index the whole page rather than the
        window this call returns. *)

    type t = {
      parse_path : string -> (unit, string) result
          (** [jsondoc]'s grammar: a [path] it cannot express is refused before
              anything is fetched, let alone a fallback credit spent. *)
    ; render_schema : string -> string option
          (** [None]: this text is not a rendering whose shape can be read. *)
    ; select_paths :
        text:string -> path:string -> max_chars:int -> selection list * int
    ; select_passages :
        text:string -> query:string -> max_chars:int -> selection list * int
    }
    (** The document readers the fetch path selects with. They arrive as a
        parameter because they are P6 ([jsondoc], [tabledoc],
        [extractors.base]); the route logic around them is here now, and a suite
        drives it with stubs. Both selectors answer spans plus the count of
        matching sections the budget cut, which is what the two budget notices
        report. *)
  end

  type t

  val create
    :  Config.t ->
    fetcher ->
    readers:Readers.t ->
    ?usage:Usage.t ->
    ?log:log ->
    ?fallbacks:fetcher list ->
    clock:(unit -> float) ->
    now:(unit -> float) ->
    unit ->
    (t, string) result
  (** [create config fetcher ~readers ~clock ~now ()], the local reader as the
      primary route and the built fallbacks behind it. [~readers] is mandatory
      rather than defaulted: a fetch that can address a [path] and a [structure]
      is a fetch with the document readers wired in, and a stub is what the suite
      hands it. The [Error] sentence is Python's [ValueError] from the
      constructor: [fetch.primary] names a fallback this deployment did not
      build, and falling back to the local reader instead would dial from this
      server's own IP against the operator's config. *)

  val resolve : t -> Config.name option -> (fetcher option, string) result
  (** Route one page: [None] is the local read, a name is that fallback. The
      three cases Python collapses — unknown to the registry, in the registry but
      never built for want of a key or url, excluded by the permission set — all
      refuse with the names this server {i did} build. The object comes back
      rather than its name because the object, not the name, is what the call is
      priced from. *)

  val fetch :
    t ->
    ?offset:int ->
    ?query:string ->
    ?path:string ->
    ?structure:bool ->
    ?provider:Config.name ->
    ?auto_fallback:bool ->
    ?run:string ->
    ?step:int ->
    string ->
    (Model.fetch_response, error) result
  (** Fetch one page, walking the ladder only where the route asked for the
      walk. [~auto_fallback] overrides [fetch.auto_fallback] for this call —
      that is how the [answer] plan keeps the walk. [~structure] reads a JSON or
      CSV page's shape instead of its values; [~path] addresses one part of it;
      [~query] returns matching passages. The four are one axis: combining them
      is a refusal, before anything is dispatched. *)
end
