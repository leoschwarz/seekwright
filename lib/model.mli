(** Wire models: the shapes that cross into a caller's context window.

    Port of [src/seekwright/models.py]. Two rules hold at this boundary, on
    every encoder:

    - an unset field is omitted rather than serialised as [null]; and
    - the fields in {!Sanitize.text_fields} are escaped on serialisation.

    Decoders mirror pydantic's validation for the shapes the REST bodies carry:
    required fields are required, [null] means absent only where the Python
    field is optional, an unknown key is refused on a wire model and ignored on
    the two plain models, and the request constraints are checked.
    [search_query] and [provider_result] are plain pydantic models in Python:
    their encoders keep nulls and defaults, and they exist for round-trip tests
    and diagnostics rather than for a caller. *)

type recency = Day | Week | Month | Year
type depth = Brief | Report
type mode = Free
(** [mode] is the [search] tool's [Literal["free"]]; [Free] is its only value. *)

type search_query = {
  query : string;
  max_results : int;
  include_domains : string list;
  exclude_domains : string list;
  country : string option;
  language : string option;
  recency : recency option;
  safe_search : bool option;
}
(** A normalised search request, as it reaches a provider adapter. The
    [safe_search] option is the tri-state: [Some true] filters, [Some false]
    asks not to, [None] sends nothing -- unknown, not unfiltered. *)

type result = {
  title : string;
  url : string;
  snippet : string option;
  text : string option;
  text_truncated : bool option;
  published_date : string option;
  score : float option;
}
(** One search hit. A provider fills [snippet] or [text], never both;
    [text_truncated] is an option because a [false] would otherwise serialise
    on every result. *)

type search_response = {
  query : string;
  provider : string;
  results : result list;
  answer : string option;
  retrieved_at : string option;
  notice : string option;
}
(** The shape returned by the [search] tool. *)

type fetch_match = { offset : int; text : string }
(** One contiguous matching span of a fetched page. [offset] indexes the page's
    full extracted text. *)

type fetch_image = { byte_count : int; base64 : string }
(** One image resource, carried as bytes. The media type is the parent
    response's [content_type]; [base64] is deliberately never escaped. *)

type fetch_response = {
  url : string;
  requested_url : string;
  title : string option;
  text : string option;
  content_type : string option;
  status_code : int option;
  retrieved_at : string option;
  truncated : bool;
  total_chars : int option;
  offset : int option;
  matches : fetch_match list option;
  image : fetch_image option;
  notice : string option;
}
(** The shape returned by the [fetch] tool. [text] and [matches] are
    alternatives; [truncated] is a plain [bool] because [false] is a report, not
    an absence. *)

type search_request = {
  query : string;
  provider : string option;
  mode : mode option;
  max_results : int;
  include_domains : string list option;
  exclude_domains : string list option;
  recency : recency option;
  language : string option;
  safe_search : bool option;
}
(** The [search] tool's parameter set, as a REST body spells it. [provider] is a
    plain string, not a vocabulary: which names a deployment serves is config,
    a key and a permission set. Omitting it stays absent. *)

type fetch_request = {
  url : string;
  offset : int option;
  query : string option;
  path : string option;
  structure : bool;
  provider : string option;
}
(** The [fetch] tool's parameter set. Omitting [provider] *is* the local read. *)

type answer_request = {
  query : string;
  extra_queries : string list option;
  depth : depth option;
  provider : string option;
  include_domains : string list option;
  exclude_domains : string list option;
  recency : recency option;
  language : string option;
  safe_search : bool option;
}
(** The [answer] tool's parameter set. [depth = None] means the plan applies the
    tool's default, exactly as [Some Brief] does. *)

type answer_source = {
  source_title : string;
  source_url : string;
  source_provider : string;
}
(** One result the prose actually cited, built by the server from what it
    retrieved. The field names carry a [source_] prefix because OCaml records
    share one field namespace. *)

type answer_response = {
  query : string;
  answer : string;
  sources : answer_source list;
  model : string;
  depth : depth;
  searches : int;
  fetched : int;
  retrieved_at : string option;
  truncated : bool option;
  notice : string option;
}
(** The shape returned by the [answer] tool. *)

type provider_result = {
  provider : string;
  results : result list;
  answer : string option;
  cost_usd : float option;
  notice : string option;
}
(** What a provider adapter returns, before response metadata is added. *)

val result_to_yojson : result -> Yojson.Safe.t
val search_response_to_yojson : search_response -> Yojson.Safe.t
val fetch_match_to_yojson : fetch_match -> Yojson.Safe.t
val fetch_image_to_yojson : fetch_image -> Yojson.Safe.t
val fetch_response_to_yojson : fetch_response -> Yojson.Safe.t
val search_request_to_yojson : search_request -> Yojson.Safe.t
val fetch_request_to_yojson : fetch_request -> Yojson.Safe.t
val answer_source_to_yojson : answer_source -> Yojson.Safe.t
val answer_request_to_yojson : answer_request -> Yojson.Safe.t
val answer_response_to_yojson : answer_response -> Yojson.Safe.t
val search_query_to_yojson : search_query -> Yojson.Safe.t
val provider_result_to_yojson : provider_result -> Yojson.Safe.t
(** Encoders. The wire-model encoders drop unset fields and escape text; the
    two plain-model encoders keep nulls and defaults, as pydantic's
    [model_dump] does. *)

val result_of_yojson : Yojson.Safe.t -> (result, string) Stdlib.result
val search_response_of_yojson : Yojson.Safe.t -> (search_response, string) Stdlib.result
val fetch_match_of_yojson : Yojson.Safe.t -> (fetch_match, string) Stdlib.result
val fetch_image_of_yojson : Yojson.Safe.t -> (fetch_image, string) Stdlib.result
val fetch_response_of_yojson : Yojson.Safe.t -> (fetch_response, string) Stdlib.result
val search_query_of_yojson : Yojson.Safe.t -> (search_query, string) Stdlib.result
val search_request_of_yojson : Yojson.Safe.t -> (search_request, string) Stdlib.result
val fetch_request_of_yojson : Yojson.Safe.t -> (fetch_request, string) Stdlib.result
val answer_request_of_yojson : Yojson.Safe.t -> (answer_request, string) Stdlib.result
val answer_source_of_yojson : Yojson.Safe.t -> (answer_source, string) Stdlib.result
val answer_response_of_yojson : Yojson.Safe.t -> (answer_response, string) Stdlib.result
val provider_result_of_yojson :
  Yojson.Safe.t -> (provider_result, string) Stdlib.result
(** Decoders. A wire model refuses an unknown key; [search_query] and
    [provider_result] ignore one. *)

val sanitize_result : result -> result * int
val sanitize_results : result list -> result list * int
val sanitize_search_response : search_response -> search_response * int
val sanitize_fetch_match : fetch_match -> fetch_match * int
val sanitize_fetch_response : fetch_response -> fetch_response * int
val sanitize_answer_source : answer_source -> answer_source * int
val sanitize_answer_response : answer_response -> answer_response * int
val sanitize_provider_result : provider_result -> provider_result * int
(** The engine's pass: escape every text-bearing field and return the escaped
    value with the number of literals escaped -- the count the engine logs,
    never the content. *)
