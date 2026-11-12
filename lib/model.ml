(* Wire models: the shapes that cross into a caller's context window.

   The Python oracle is [src/seekwright/models.py]. Two boundary rules travel
   with the shapes rather than with any one response:

   - an absent field is dropped rather than serialised as [null]; and
   - the fields in [Sanitize.text_fields] are escaped on serialisation, so no
     path that builds a response -- an engine, a future tool, a cache layer --
     can leak a special-token literal to a caller's tokenizer.

   [search_query] and [provider_result] are the two records that are *not* wire
   shapes in Python (plain pydantic models); their encoders below mirror
   pydantic's default [model_dump], nulls included, and exist for round-trip
   tests and diagnostics rather than for a caller.

   The log-only private attributes [Result._uncapped_chars] and
   [ProviderResult._reported_cost_usd] are deliberately absent: they never
   reach the wire, and OCaml has no field-level privacy to hide them behind.
   P5 adds them to whatever record owns the measurement. *)

module Utf8 = Seekwright_text.Utf8

let ( let* ) = Result.bind

type recency = Day | Week | Month | Year
type depth = Brief | Report
type mode = Free

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

type result = {
  title : string;
  url : string;
  snippet : string option;
  text : string option;
  text_truncated : bool option;
  published_date : string option;
  score : float option;
}

type search_response = {
  query : string;
  provider : string;
  results : result list;
  answer : string option;
  retrieved_at : string option;
  notice : string option;
}

type fetch_match = { offset : int; text : string }

type fetch_image = { byte_count : int; base64 : string }

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

type fetch_request = {
  url : string;
  offset : int option;
  query : string option;
  path : string option;
  structure : bool;
  provider : string option;
}

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

type answer_source = { source_title : string; source_url : string; source_provider : string }
(* The three names are prefixed because OCaml records share one field
   namespace; [title], [url] and [provider] already belong to the records
   above. *)

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

type provider_result = {
  provider : string;
  results : result list;
  answer : string option;
  cost_usd : float option;
  notice : string option;
}

(* {1 Small JSON helpers} *)

let json_kind (json : Yojson.Safe.t) = match json with
  | `Null -> "null"
  | `Bool _ -> "a boolean"
  | `Int _ -> "an integer"
  | `Intlit _ -> "an integer"
  | `Float _ -> "a number"
  | `String _ -> "a string"
  | `Assoc _ -> "an object"
  | `List _ -> "an array"

let type_error expected json =
  Printf.sprintf "expected %s, got %s" expected (json_kind json)

let as_assoc (json : Yojson.Safe.t) = match json with
  | `Assoc kvs -> Ok kvs
  | json -> Error (type_error "an object" json)

let find name kvs = List.assoc_opt name kvs

let reject_extra ~allowed kvs =
  match List.find_opt (fun (k, _) -> not (List.mem k allowed)) kvs with
  | None -> Ok ()
  | Some (k, _) -> Error (Printf.sprintf "extra field %S" k)

let req_string name kvs =
  match find name kvs with
  | Some (`String s) -> Ok s
  | None -> Error (Printf.sprintf "missing required field %S" name)
  | Some `Null -> Error (Printf.sprintf "field %S is not nullable" name)
  | Some json -> Error (type_error "a string" json)

let opt_string name kvs =
  match find name kvs with
  | None | Some `Null -> Ok None
  | Some (`String s) -> Ok (Some s)
  | Some json -> Error (type_error "a string" json)

let req_int name kvs =
  match find name kvs with
  | Some (`Int i) -> Ok i
  | Some (`Float f) when Float.is_integer f -> Ok (int_of_float f)
  | None -> Error (Printf.sprintf "missing required field %S" name)
  | Some `Null -> Error (Printf.sprintf "field %S is not nullable" name)
  | Some json -> Error (type_error "an integer" json)

let opt_int name kvs =
  match find name kvs with
  | None | Some `Null -> Ok None
  | Some (`Int i) -> Ok (Some i)
  | Some (`Float f) when Float.is_integer f -> Ok (Some (int_of_float f))
  | Some json -> Error (type_error "an integer" json)

let opt_float name kvs =
  match find name kvs with
  | None | Some `Null -> Ok None
  | Some (`Int i) -> Ok (Some (float_of_int i))
  | Some (`Float f) -> Ok (Some f)
  | Some json -> Error (type_error "a number" json)

let opt_bool name kvs =
  match find name kvs with
  | None | Some `Null -> Ok None
  | Some (`Bool b) -> Ok (Some b)
  | Some json -> Error (type_error "a boolean" json)

let decode_list f (json : Yojson.Safe.t) =
  match json with
  | `List items ->
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | item :: rest ->
            let* value = f item in
            loop (value :: acc) rest
      in
      loop [] items
  | json -> Error (type_error "an array" json)

let string_item (json : Yojson.Safe.t) =
  match json with
  | `String s -> Ok s
  | json -> Error (type_error "a string" json)

let opt_string_list name kvs =
  match find name kvs with
  | None | Some `Null -> Ok None
  | Some json ->
      let* items = decode_list string_item json in
      Ok (Some items)

(* A field with a non-optional default: absent means the default, and an
   explicit null is a type error, exactly as pydantic validates it. *)
let default_int name kvs default =
  match find name kvs with
  | None -> Ok default
  | Some (`Int i) -> Ok i
  | Some (`Float f) when Float.is_integer f -> Ok (int_of_float f)
  | Some `Null -> Error (Printf.sprintf "field %S is not nullable" name)
  | Some json -> Error (type_error "an integer" json)

let default_bool name kvs default =
  match find name kvs with
  | None -> Ok default
  | Some (`Bool b) -> Ok b
  | Some `Null -> Error (Printf.sprintf "field %S is not nullable" name)
  | Some json -> Error (type_error "a boolean" json)

let default_string_list name kvs default =
  match find name kvs with
  | None -> Ok default
  | Some `Null -> Error (Printf.sprintf "field %S is not nullable" name)
  | Some json -> decode_list string_item json

(* pydantic counts codepoints for min_length/max_length, so must this. *)

let check_length ~name ~min ~max value =
  let n = Utf8.count value in
  if n < min then
    Error (Printf.sprintf "field %S is shorter than %d characters" name min)
  else if n > max then
    Error (Printf.sprintf "field %S is longer than %d characters" name max)
  else Ok value

let check_max_items ~name ~max items =
  if List.length items > max then
    Error (Printf.sprintf "field %S has more than %d items" name max)
  else Ok items

let check_min_int ~name ~min value =
  if value < min then Error (Printf.sprintf "field %S is below %d" name min)
  else Ok value

let check_int_range ~name ~min ~max value =
  if value < min || value > max then
    Error (Printf.sprintf "field %S is outside %d..%d" name min max)
  else Ok value

let check_exact_length ~name ~expected value =
  if Utf8.count value <> expected then
    Error (Printf.sprintf "field %S must be exactly %d characters" name expected)
  else Ok value

(* {1 Variants} *)

let string_of_recency = function
  | Day -> "day"
  | Week -> "week"
  | Month -> "month"
  | Year -> "year"

let recency_of_yojson = function
  | `String "day" -> Ok Day
  | `String "week" -> Ok Week
  | `String "month" -> Ok Month
  | `String "year" -> Ok Year
  | json -> Error (type_error "one of day|week|month|year" json)

let string_of_depth = function Brief -> "brief" | Report -> "report"

let depth_of_yojson = function
  | `String "brief" -> Ok Brief
  | `String "report" -> Ok Report
  | json -> Error (type_error "one of brief|report" json)

let string_of_mode = function Free -> "free"

let mode_of_yojson = function
  | `String "free" -> Ok Free
  | json -> Error (type_error "\"free\"" json)

let opt_recency name kvs =
  match find name kvs with
  | None | Some `Null -> Ok None
  | Some json ->
      let* value = recency_of_yojson json in
      Ok (Some value)

let opt_depth name kvs =
  match find name kvs with
  | None | Some `Null -> Ok None
  | Some json ->
      let* value = depth_of_yojson json in
      Ok (Some value)

let opt_mode name kvs =
  match find name kvs with
  | None | Some `Null -> Ok None
  | Some json ->
      let* value = mode_of_yojson json in
      Ok (Some value)

(* {1 Serialisation: only set fields, escaped text} *)

let escaped text = fst (Sanitize.sanitize_text text)

let result_to_yojson (r : result) : Yojson.Safe.t =
  let fields =
    [ ("title", `String (escaped r.title)); ("url", `String r.url) ]
    @ (match r.snippet with
      | None -> []
      | Some s -> [ ("snippet", `String (escaped s)) ])
    @ (match r.text with
      | None -> []
      | Some s -> [ ("text", `String (escaped s)) ])
    @
    match r.text_truncated with
    | None -> []
    | Some b -> [ ("text_truncated", `Bool b) ]
  in
  let fields =
    fields
    @ (match r.published_date with
      | None -> []
      | Some s -> [ ("published_date", `String s) ])
    @ match r.score with None -> [] | Some f -> [ ("score", `Float f) ]
  in
  `Assoc fields

let search_response_to_yojson (r : search_response) : Yojson.Safe.t =
  `Assoc
    ([
       ("query", `String r.query);
       ("provider", `String r.provider);
       ("results", `List (List.map result_to_yojson r.results));
     ]
    @ (match r.answer with
      | None -> []
      | Some s -> [ ("answer", `String (escaped s)) ])
    @ (match r.retrieved_at with
      | None -> []
      | Some s -> [ ("retrieved_at", `String s) ])
    @ match r.notice with
    | None -> []
    | Some s -> [ ("notice", `String s) ])

let fetch_match_to_yojson (m : fetch_match) : Yojson.Safe.t =
  `Assoc
    [ ("offset", `Int m.offset); ("text", `String (escaped m.text)) ]

let fetch_image_to_yojson (i : fetch_image) : Yojson.Safe.t =
  (* base64 is not escaped: the alphabet holds no '<' and no '|', so no
     delimiter can be spelled, and an escape pass would corrupt the bytes. *)
  `Assoc
    [ ("byte_count", `Int i.byte_count); ("base64", `String i.base64) ]

let fetch_response_to_yojson (r : fetch_response) : Yojson.Safe.t =
  `Assoc
    ([
       ("url", `String r.url);
       ("requested_url", `String r.requested_url);
     ]
    @ (match r.title with
      | None -> []
      | Some s -> [ ("title", `String (escaped s)) ])
    @ (match r.text with
      | None -> []
      | Some s -> [ ("text", `String (escaped s)) ])
    @ (match r.content_type with
      | None -> []
      | Some s -> [ ("content_type", `String s) ])
    @ (match r.status_code with None -> [] | Some i -> [ ("status_code", `Int i) ])
    @ (match r.retrieved_at with
      | None -> []
      | Some s -> [ ("retrieved_at", `String s) ])
    @ [ ("truncated", `Bool r.truncated) ]
    @ (match r.total_chars with
      | None -> []
      | Some i -> [ ("total_chars", `Int i) ])
    @ (match r.offset with None -> [] | Some i -> [ ("offset", `Int i) ])
    @ (match r.matches with
      | None -> []
      | Some ms -> [ ("matches", `List (List.map fetch_match_to_yojson ms)) ])
    @ (match r.image with
      | None -> []
      | Some image -> [ ("image", fetch_image_to_yojson image) ])
    @ match r.notice with None -> [] | Some s -> [ ("notice", `String s) ])

let search_request_to_yojson (r : search_request) : Yojson.Safe.t =
  `Assoc
    ([ ("query", `String r.query) ]
    @ (match r.provider with
      | None -> []
      | Some s -> [ ("provider", `String s) ])
    @ (match r.mode with
      | None -> []
      | Some m -> [ ("mode", `String (string_of_mode m)) ])
    @ [ ("max_results", `Int r.max_results) ]
    @ (match r.include_domains with
      | None -> []
      | Some ds ->
          [ ("include_domains", `List (List.map (fun s -> `String s) ds)) ])
    @ (match r.exclude_domains with
      | None -> []
      | Some ds ->
          [ ("exclude_domains", `List (List.map (fun s -> `String s) ds)) ])
    @ (match r.recency with
      | None -> []
      | Some value -> [ ("recency", `String (string_of_recency value)) ])
    @ (match r.language with None -> [] | Some s -> [ ("language", `String s) ])
    @ match r.safe_search with
    | None -> []
    | Some b -> [ ("safe_search", `Bool b) ])

let fetch_request_to_yojson (r : fetch_request) : Yojson.Safe.t =
  `Assoc
    ([ ("url", `String r.url) ]
    @ (match r.offset with None -> [] | Some i -> [ ("offset", `Int i) ])
    @ (match r.query with None -> [] | Some s -> [ ("query", `String s) ])
    @ (match r.path with None -> [] | Some s -> [ ("path", `String s) ])
    @ [ ("structure", `Bool r.structure) ]
    @ match r.provider with None -> [] | Some s -> [ ("provider", `String s) ])

let answer_source_to_yojson (s : answer_source) : Yojson.Safe.t =
  `Assoc
    [
      ("title", `String (escaped s.source_title));
      ("url", `String s.source_url);
      ("provider", `String s.source_provider);
    ]

let answer_request_to_yojson (r : answer_request) : Yojson.Safe.t =
  `Assoc
    ([ ("query", `String r.query) ]
    @ (match r.extra_queries with
      | None -> []
      | Some qs ->
          [ ("extra_queries", `List (List.map (fun s -> `String s) qs)) ])
    @ (match r.depth with
      | None -> []
      | Some d -> [ ("depth", `String (string_of_depth d)) ])
    @ (match r.provider with None -> [] | Some s -> [ ("provider", `String s) ])
    @ (match r.include_domains with
      | None -> []
      | Some ds ->
          [ ("include_domains", `List (List.map (fun s -> `String s) ds)) ])
    @ (match r.exclude_domains with
      | None -> []
      | Some ds ->
          [ ("exclude_domains", `List (List.map (fun s -> `String s) ds)) ])
    @ (match r.recency with
      | None -> []
      | Some value -> [ ("recency", `String (string_of_recency value)) ])
    @ (match r.language with None -> [] | Some s -> [ ("language", `String s) ])
    @ match r.safe_search with
    | None -> []
    | Some b -> [ ("safe_search", `Bool b) ])

let answer_response_to_yojson (r : answer_response) : Yojson.Safe.t =
  `Assoc
    ([
       ("query", `String r.query);
       ("answer", `String (escaped r.answer));
       ("sources", `List (List.map answer_source_to_yojson r.sources));
       ("model", `String r.model);
       ("depth", `String (string_of_depth r.depth));
       ("searches", `Int r.searches);
       ("fetched", `Int r.fetched);
     ]
    @ (match r.retrieved_at with
      | None -> []
      | Some s -> [ ("retrieved_at", `String s) ])
    @ (match r.truncated with None -> [] | Some b -> [ ("truncated", `Bool b) ])
    @ match r.notice with None -> [] | Some s -> [ ("notice", `String s) ])

let search_query_to_yojson (q : search_query) : Yojson.Safe.t =
  (* Not a wire shape: pydantic's default dump, nulls and defaults included. *)
  let opt_string = function None -> `Null | Some s -> `String s in
  `Assoc
    [
      ("query", `String q.query);
      ("max_results", `Int q.max_results);
      ("include_domains", `List (List.map (fun s -> `String s) q.include_domains));
      ("exclude_domains", `List (List.map (fun s -> `String s) q.exclude_domains));
      ("country", opt_string q.country);
      ("language", opt_string q.language);
      ( "recency",
        match q.recency with
        | None -> `Null
        | Some value -> `String (string_of_recency value) );
      ("safe_search", match q.safe_search with None -> `Null | Some b -> `Bool b);
    ]

let provider_result_to_yojson (r : provider_result) : Yojson.Safe.t =
  (* Not a wire shape either. Results are WireModels and escape through their
     own encoder; [answer] stays as the adapter reported it, as in Python. *)
  `Assoc
    [
      ("provider", `String r.provider);
      ("results", `List (List.map result_to_yojson r.results));
      ("answer", match r.answer with None -> `Null | Some s -> `String s);
      ("cost_usd", match r.cost_usd with None -> `Null | Some f -> `Float f);
      ("notice", match r.notice with None -> `Null | Some s -> `String s);
    ]

(* {1 Deserialisation} *)

let result_allowed =
  [
    "title";
    "url";
    "snippet";
    "text";
    "text_truncated";
    "published_date";
    "score";
  ]

let result_of_yojson (json : Yojson.Safe.t) =
  let* kvs = as_assoc json in
  let* () = reject_extra ~allowed:result_allowed kvs in
  let* title = req_string "title" kvs in
  let* url = req_string "url" kvs in
  let* snippet = opt_string "snippet" kvs in
  let* text = opt_string "text" kvs in
  let* text_truncated = opt_bool "text_truncated" kvs in
  let* published_date = opt_string "published_date" kvs in
  let* score = opt_float "score" kvs in
  Ok { title; url; snippet; text; text_truncated; published_date; score }

let search_response_of_yojson (json : Yojson.Safe.t) =
  let* kvs = as_assoc json in
  let* () =
    reject_extra
      ~allowed:[ "query"; "provider"; "results"; "answer"; "retrieved_at"; "notice" ]
      kvs
  in
  let* query = req_string "query" kvs in
  let* provider = req_string "provider" kvs in
  let* results =
    match find "results" kvs with
    | None -> Error "missing required field \"results\""
    | Some `Null -> Error "field \"results\" is not nullable"
    | Some json -> decode_list result_of_yojson json
  in
  let* answer = opt_string "answer" kvs in
  let* retrieved_at = opt_string "retrieved_at" kvs in
  let* notice = opt_string "notice" kvs in
  Ok { query; provider; results; answer; retrieved_at; notice }

let fetch_match_of_yojson (json : Yojson.Safe.t) =
  let* kvs = as_assoc json in
  let* () = reject_extra ~allowed:[ "offset"; "text" ] kvs in
  let* offset = req_int "offset" kvs in
  let* text = req_string "text" kvs in
  Ok { offset; text }

let fetch_image_of_yojson (json : Yojson.Safe.t) =
  let* kvs = as_assoc json in
  let* () = reject_extra ~allowed:[ "byte_count"; "base64" ] kvs in
  let* byte_count = req_int "byte_count" kvs in
  let* base64 = req_string "base64" kvs in
  Ok { byte_count; base64 }

let fetch_response_allowed =
  [
    "url";
    "requested_url";
    "title";
    "text";
    "content_type";
    "status_code";
    "retrieved_at";
    "truncated";
    "total_chars";
    "offset";
    "matches";
    "image";
    "notice";
  ]

let fetch_response_of_yojson (json : Yojson.Safe.t) =
  let* kvs = as_assoc json in
  let* () = reject_extra ~allowed:fetch_response_allowed kvs in
  let* url = req_string "url" kvs in
  let* requested_url = req_string "requested_url" kvs in
  let* title = opt_string "title" kvs in
  let* text = opt_string "text" kvs in
  let* content_type = opt_string "content_type" kvs in
  let* status_code = opt_int "status_code" kvs in
  let* retrieved_at = opt_string "retrieved_at" kvs in
  let* truncated = default_bool "truncated" kvs false in
  let* total_chars = opt_int "total_chars" kvs in
  let* offset = opt_int "offset" kvs in
  let* matches =
    match find "matches" kvs with
    | None | Some `Null -> Ok None
    | Some json ->
        let* ms = decode_list fetch_match_of_yojson json in
        Ok (Some ms)
  in
  let* image =
    match find "image" kvs with
    | None | Some `Null -> Ok None
    | Some json ->
        let* image = fetch_image_of_yojson json in
        Ok (Some image)
  in
  let* notice = opt_string "notice" kvs in
  Ok
    {
      url;
      requested_url;
      title;
      text;
      content_type;
      status_code;
      retrieved_at;
      truncated;
      total_chars;
      offset;
      matches;
      image;
      notice;
    }

let search_query_of_yojson (json : Yojson.Safe.t) =
  (* Plain pydantic model: extra keys are ignored, not refused. *)
  let* kvs = as_assoc json in
  let* query = req_string "query" kvs in
  let* max_results = default_int "max_results" kvs 5 in
  let* include_domains = default_string_list "include_domains" kvs [] in
  let* exclude_domains = default_string_list "exclude_domains" kvs [] in
  let* country = opt_string "country" kvs in
  let* language = opt_string "language" kvs in
  let* recency = opt_recency "recency" kvs in
  let* safe_search = opt_bool "safe_search" kvs in
  Ok
    {
      query;
      max_results;
      include_domains;
      exclude_domains;
      country;
      language;
      recency;
      safe_search;
    }

let search_request_allowed =
  [
    "query";
    "provider";
    "mode";
    "max_results";
    "include_domains";
    "exclude_domains";
    "recency";
    "language";
    "safe_search";
  ]

let search_request_of_yojson (json : Yojson.Safe.t) =
  let* kvs = as_assoc json in
  let* () = reject_extra ~allowed:search_request_allowed kvs in
  let* query = req_string "query" kvs in
  let* query = check_length ~name:"query" ~min:2 ~max:400 query in
  let* provider = opt_string "provider" kvs in
  let* mode = opt_mode "mode" kvs in
  let* max_results = default_int "max_results" kvs 5 in
  let* max_results = check_int_range ~name:"max_results" ~min:1 ~max:20 max_results in
  let* include_domains = opt_string_list "include_domains" kvs in
  let* include_domains =
    match include_domains with
    | None -> Ok None
    | Some ds ->
        let* ds = check_max_items ~name:"include_domains" ~max:20 ds in
        Ok (Some ds)
  in
  let* exclude_domains = opt_string_list "exclude_domains" kvs in
  let* exclude_domains =
    match exclude_domains with
    | None -> Ok None
    | Some ds ->
        let* ds = check_max_items ~name:"exclude_domains" ~max:20 ds in
        Ok (Some ds)
  in
  let* recency = opt_recency "recency" kvs in
  let* language = opt_string "language" kvs in
  let* language =
    match language with
    | None -> Ok None
    | Some s ->
        let* s = check_exact_length ~name:"language" ~expected:2 s in
        Ok (Some s)
  in
  let* safe_search = opt_bool "safe_search" kvs in
  Ok
    {
      query;
      provider;
      mode;
      max_results;
      include_domains;
      exclude_domains;
      recency;
      language;
      safe_search;
    }

let fetch_request_allowed =
  [ "url"; "offset"; "query"; "path"; "structure"; "provider" ]

let fetch_request_of_yojson (json : Yojson.Safe.t) =
  let* kvs = as_assoc json in
  let* () = reject_extra ~allowed:fetch_request_allowed kvs in
  let* url = req_string "url" kvs in
  let* url = check_length ~name:"url" ~min:8 ~max:2048 url in
  let* offset = opt_int "offset" kvs in
  let* offset =
    match offset with
    | None -> Ok None
    | Some i ->
        let* i = check_min_int ~name:"offset" ~min:0 i in
        Ok (Some i)
  in
  let* query = opt_string "query" kvs in
  let* query =
    match query with
    | None -> Ok None
    | Some s ->
        let* s = check_length ~name:"query" ~min:2 ~max:400 s in
        Ok (Some s)
  in
  let* path = opt_string "path" kvs in
  let* path =
    match path with
    | None -> Ok None
    | Some s ->
        let* s = check_length ~name:"path" ~min:1 ~max:400 s in
        Ok (Some s)
  in
  let* structure = default_bool "structure" kvs false in
  let* provider = opt_string "provider" kvs in
  Ok { url; offset; query; path; structure; provider }

let answer_request_allowed =
  [
    "query";
    "extra_queries";
    "depth";
    "provider";
    "include_domains";
    "exclude_domains";
    "recency";
    "language";
    "safe_search";
  ]

let answer_request_of_yojson (json : Yojson.Safe.t) =
  let* kvs = as_assoc json in
  let* () = reject_extra ~allowed:answer_request_allowed kvs in
  let* query = req_string "query" kvs in
  let* query = check_length ~name:"query" ~min:2 ~max:400 query in
  let* extra_queries = opt_string_list "extra_queries" kvs in
  let* extra_queries =
    match extra_queries with
    | None -> Ok None
    | Some qs ->
        let* qs = check_max_items ~name:"extra_queries" ~max:2 qs in
        let rec check = function
          | [] -> Ok []
          | q :: rest ->
              let* q = check_length ~name:"extra_queries" ~min:2 ~max:400 q in
              let* rest = check rest in
              Ok (q :: rest)
        in
        let* qs = check qs in
        Ok (Some qs)
  in
  let* depth = opt_depth "depth" kvs in
  let* provider = opt_string "provider" kvs in
  let* include_domains = opt_string_list "include_domains" kvs in
  let* include_domains =
    match include_domains with
    | None -> Ok None
    | Some ds ->
        let* ds = check_max_items ~name:"include_domains" ~max:20 ds in
        Ok (Some ds)
  in
  let* exclude_domains = opt_string_list "exclude_domains" kvs in
  let* exclude_domains =
    match exclude_domains with
    | None -> Ok None
    | Some ds ->
        let* ds = check_max_items ~name:"exclude_domains" ~max:20 ds in
        Ok (Some ds)
  in
  let* recency = opt_recency "recency" kvs in
  let* language = opt_string "language" kvs in
  let* language =
    match language with
    | None -> Ok None
    | Some s ->
        let* s = check_exact_length ~name:"language" ~expected:2 s in
        Ok (Some s)
  in
  let* safe_search = opt_bool "safe_search" kvs in
  Ok
    {
      query;
      extra_queries;
      depth;
      provider;
      include_domains;
      exclude_domains;
      recency;
      language;
      safe_search;
    }

let answer_source_of_yojson (json : Yojson.Safe.t) =
  let* kvs = as_assoc json in
  let* () = reject_extra ~allowed:[ "title"; "url"; "provider" ] kvs in
  let* source_title = req_string "title" kvs in
  let* source_url = req_string "url" kvs in
  let* source_provider = req_string "provider" kvs in
  Ok { source_title; source_url; source_provider }

let answer_response_allowed =
  [
    "query";
    "answer";
    "sources";
    "model";
    "depth";
    "searches";
    "fetched";
    "retrieved_at";
    "truncated";
    "notice";
  ]

let answer_response_of_yojson (json : Yojson.Safe.t) =
  let* kvs = as_assoc json in
  let* () = reject_extra ~allowed:answer_response_allowed kvs in
  let* query = req_string "query" kvs in
  let* answer = req_string "answer" kvs in
  let* sources =
    match find "sources" kvs with
    | None -> Error "missing required field \"sources\""
    | Some `Null -> Error "field \"sources\" is not nullable"
    | Some json -> decode_list answer_source_of_yojson json
  in
  let* model = req_string "model" kvs in
  let* depth =
    match find "depth" kvs with
    | None -> Error "missing required field \"depth\""
    | Some json -> depth_of_yojson json
  in
  let* searches = req_int "searches" kvs in
  let* fetched = req_int "fetched" kvs in
  let* retrieved_at = opt_string "retrieved_at" kvs in
  let* truncated = opt_bool "truncated" kvs in
  let* notice = opt_string "notice" kvs in
  Ok
    {
      query;
      answer;
      sources;
      model;
      depth;
      searches;
      fetched;
      retrieved_at;
      truncated;
      notice;
    }

let provider_result_of_yojson (json : Yojson.Safe.t) =
  let* kvs = as_assoc json in
  let* provider = req_string "provider" kvs in
  let* results =
    match find "results" kvs with
    | None -> Error "missing required field \"results\""
    | Some `Null -> Error "field \"results\" is not nullable"
    | Some json -> decode_list result_of_yojson json
  in
  let* answer = opt_string "answer" kvs in
  let* cost_usd = opt_float "cost_usd" kvs in
  let* notice = opt_string "notice" kvs in
  Ok { provider; results; answer; cost_usd; notice }

(* {1 The engine's pass: escape in place, count, log the count} *)

let sanitize_option value =
  match value with
  | None -> (None, 0)
  | Some text ->
      let text, n = Sanitize.sanitize_text text in
      (Some text, n)

let sanitize_result (r : result) : result * int =
  let title, title_count = Sanitize.sanitize_text r.title in
  let snippet, snippet_count = sanitize_option r.snippet in
  let text, text_count = sanitize_option r.text in
  ( { r with title; snippet; text },
    title_count + snippet_count + text_count )

let sanitize_results results =
  List.fold_left
    (fun (acc, total) result ->
      let result, n = sanitize_result result in
      (result :: acc, total + n))
    ([], 0) results
  |> fun (results, total) -> (List.rev results, total)

let sanitize_search_response (r : search_response) : search_response * int =
  let results, results_count = sanitize_results r.results in
  let answer, answer_count = sanitize_option r.answer in
  ({ r with results; answer }, results_count + answer_count)

let sanitize_fetch_match (m : fetch_match) : fetch_match * int =
  let text, n = Sanitize.sanitize_text m.text in
  ({ m with text }, n)

let sanitize_answer_source (s : answer_source) : answer_source * int =
  let source_title, n = Sanitize.sanitize_text s.source_title in
  ({ s with source_title }, n)

let sanitize_fetch_response (r : fetch_response) : fetch_response * int =
  let title, title_count = sanitize_option r.title in
  let text, text_count = sanitize_option r.text in
  let matches, matches_count =
    match r.matches with
    | None -> (None, 0)
    | Some ms ->
        List.fold_left
          (fun (acc, total) m ->
            let m, n = sanitize_fetch_match m in
            (m :: acc, total + n))
          ([], 0) ms
        |> fun (ms, total) -> (Some (List.rev ms), total)
  in
  ( { r with title; text; matches },
    title_count + text_count + matches_count )

let sanitize_answer_response (r : answer_response) : answer_response * int =
  let answer, answer_count = Sanitize.sanitize_text r.answer in
  let sources, sources_count =
    List.fold_left
      (fun (acc, total) source ->
        let source, n = sanitize_answer_source source in
        (source :: acc, total + n))
      ([], 0) r.sources
    |> fun (sources, total) -> (List.rev sources, total)
  in
  ({ r with answer; sources }, answer_count + sources_count)

let sanitize_provider_result (r : provider_result) : provider_result * int =
  let results, results_count = sanitize_results r.results in
  let answer, answer_count = sanitize_option r.answer in
  ({ r with results; answer }, results_count + answer_count)
