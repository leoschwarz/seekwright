(** Execution around the routing decisions: dispatch one query, dispatch one page.

    Both engines ask {!Router} which name serves and in what order, call it,
    record the outcome, and turn a provider failure into a sentence a model can
    act on. Nothing here raises: failure is a returned value.

    [~clock] is monotonic seconds (every [ms] field and the health board's
    cooldowns); [~now] is UTC wall seconds and stamps [retrieved_at]. *)

type log = Log.log

(** {1 The search engine} *)

module Search : sig
  type error =
    | Refused of string  (** nothing billed; the caller can act (REST 400) *)
    | Failed of string  (** a provider failed, or the walk behind it did (502) *)

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
  (** [create config providers ~clock ~now ()]. [providers] is kept in dispatch
      order: it decides the zero-results notice's "other enabled providers" list
      and the routing table's provider set. [?health] absent is a fresh board;
      the server passes the shared one so the engine and the health monitor agree
      on who is up. *)

  val providers : t -> Config.name list
  (** The registry's names, in dispatch order. *)

  val resolve :
    t -> ?mode:Router.search_mode -> Config.name option -> (Config.name, string) result
  (** Which name would serve, or {!Router}'s refusal verbatim. Pure: no dispatch
      and no logging. *)

  val search :
    t ->
    ?provider:Config.name ->
    ?mode:Router.search_mode ->
    ?run:string ->
    ?step:int ->
    Model.search_query ->
    (Model.search_response, error) result
  (** Dispatch one query, recording it on the board and the journal. A named
      provider is terminal; an unnamed one takes [default_provider] and walks
      [search.fallback] when that fails, or the free set when no default is
      configured and every reachable name is free. [~mode:Free] is served only by
      names that cannot bill and never escalates. [~run]/[~step] tie one
      retrieval step to its journal line. *)
end

(** {1 The fetch engine} *)

module Fetch : sig
  type image = Seekwright_wire.Page.image = {
    media_type : string
  ;  (** the type the body's own bytes agreed with, not the server's header *)
    body : string
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
    | Default  (** this fetcher's configured [fetch.max_text_chars] *)
    | Limit of int
    | Uncapped

  type error =
    | Refused of string  (** nothing billed; the caller can act (REST 400) *)
    | Failed of string  (** a page could not be produced (502) *)

  type fetch_error =
    | Provider of Provider.error
    | Url_blocked of string  (** a guardrail refused the URL as written (400) *)
    | Redirect_blocked of string  (** …with a request already in flight (502) *)
    | Fetch_blocked of string  (** any other policy refusal mid-flight *)
  (** Only [Url_blocked], refused before any request went out, becomes
      {!Refused}; the others become {!Failed}. *)

  type fetcher = {
    name : Config.name
  ; cost_per_1k : float option  (** [None] is "no price to record", not "free" *)
  ; fetch :
      url:string -> offset:int -> max_chars:cap -> (page, fetch_error) result
  ; aclose : unit -> unit
  }

  module Cache : sig
    type t = {
      preflight : string -> (string, fetch_error) result
          (** The URL guardrails, run before any lookup even with a warm entry.
              The answer is the validated URL the entry keys on; the refusal is
              what a live fetch of that URL would have reported. *)
    ; read :
        rung:Config.name ->
        url:string ->
        offset:int ->
        max_chars:cap ->
        dispatch:(offset:int -> max_chars:cap -> (page, fetch_error) result) ->
        (page * bool, fetch_error) result
          (** One entry's window, or the dispatch that fills it. [url] is the
              [preflight]'s answer. The [bool] is whether the call was
              dispatch-free: a warm entry is, and so is a cold fill led by a
              concurrent call. *)
    }
  end

  module Readers : sig
    type selection = int * string
    (** A span's offset into the full rendering, and its text. Offsets index the
        whole page, not the window this call returns. *)

    type t = {
      parse_path : string -> (unit, string) result
          (** [jsondoc]'s grammar: an unexpressible [path] is refused before
              anything is fetched. *)
    ; render_schema : string -> string option
          (** [None]: this text is not a rendering whose shape can be read. *)
    ; select_paths :
        text:string -> path:string -> max_chars:int -> selection list * int
    ; select_passages :
        text:string -> query:string -> max_chars:int -> selection list * int
    }
    (** The readers [fetch] selects with. Each selector answers spans plus the
        number of matching sections the budget cut. *)
  end

  type t

  val create
    :  Config.t ->
    fetcher ->
    readers:Readers.t ->
    ?cache:Cache.t ->
    ?usage:Usage.t ->
    ?log:log ->
    ?fallbacks:fetcher list ->
    clock:(unit -> float) ->
    now:(unit -> float) ->
    unit ->
    (t, string) result
  (** [create config fetcher ~readers ~clock ~now ()]. [fetcher] is the local
      reader; [fetch.primary] may select one of [~fallbacks] instead. [Error] is
      [fetch.primary] naming a fallback this deployment did not build. *)

  val resolve : t -> Config.name option -> (fetcher option, string) result
  (** Route one page: [None] is the local read, a name is that fallback. Unknown,
      unbuilt and unpermitted names all refuse with the names this server did
      build. *)

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
  (** Fetch one page. [~auto_fallback] overrides [fetch.auto_fallback] for this
      call. [~structure], [~path], [~query] and [~offset] are one axis — a shape
      read, a drill, passages, or a continuation — and combining them is refused
      before dispatch. *)
end
