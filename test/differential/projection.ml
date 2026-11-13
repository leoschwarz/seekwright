(** The OCaml half of every corpus projection.

    One function per corpus area, each taking the corpus input as text and
    answering with the projection lines the golden pins. [../ocaml-tools/oracle/
    projections.py] is the Python half, written against the oracle tree, and the
    golden file is what makes the two agree: neither side's rendering is trusted,
    only the pinned one.

    The area names and the line grammar are the corpus format's, written down in
    [README.md] beside this module. Two rules every area follows, because they
    are what keeps a golden re-generable:

    - no clock and no environment: {!Seekwright_diff.Canon.reset_key_environment}
      runs once in the driver, and any value a golden would have to re-read from
      the machine ([retrieved_at], [ms]) is left out of the projection rather
      than pinned at an invented instant;
    - free text is escaped, never embedded: a sentence or a page goes through
      {!Seekwright_diff.Canon.escape_text}, so a projection line stays one line
      and a golden stays ASCII. *)

module Config = Seekwright.Config
module Engine = Seekwright.Engine
module Fetcher = Seekwright_fetch.Fetcher
module Jsondoc = Seekwright_fetch.Jsondoc
module Model = Seekwright.Model
module Provider = Seekwright.Provider
module Repr = Seekwright_text.Repr
module Router = Seekwright.Router
module Sanitize = Seekwright.Sanitize
module Tabledoc = Seekwright_fetch.Tabledoc
module Utf8 = Seekwright_text.Utf8

(* {1 Reading a corpus spec} *)

let read_json text = Yojson.Safe.from_string text

let member key value =
  match value with `Assoc fields -> List.assoc_opt key fields | _ -> None

let ( $ ) key value =
  match member key value with
  | Some v -> v
  | None -> failwith (Printf.sprintf "corpus spec has no %S member" key)

let want_string key value =
  match key $ value with
  | `String s -> s
  | v -> failwith (Printf.sprintf "corpus %S is not a string: %s" key (Yojson.Safe.to_string v))

let maybe_string key value =
  match member key value with
  | Some `Null | None -> None
  | Some (`String s) -> Some s
  | Some v -> failwith (Printf.sprintf "corpus %S is not a string: %s" key (Yojson.Safe.to_string v))

let want_int key value =
  match key $ value with
  | `Int n -> n
  | `Intlit s -> int_of_string s
  | v -> failwith (Printf.sprintf "corpus %S is not an int: %s" key (Yojson.Safe.to_string v))

let maybe_int key value =
  match member key value with
  | Some `Null | None -> None
  | Some (`Int n) -> Some n
  | Some (`Intlit s) -> Some (int_of_string s)
  | Some v -> failwith (Printf.sprintf "corpus %S is not an int: %s" key (Yojson.Safe.to_string v))

let maybe_float key value =
  match member key value with
  | Some `Null | None -> None
  | Some (`Float f) -> Some f
  | Some (`Int n) -> Some (float_of_int n)
  | Some v -> failwith (Printf.sprintf "corpus %S is not a float: %s" key (Yojson.Safe.to_string v))

let want_bool key value =
  match key $ value with
  | `Bool b -> b
  | v -> failwith (Printf.sprintf "corpus %S is not a bool: %s" key (Yojson.Safe.to_string v))

let maybe_bool key value =
  match member key value with
  | Some `Null | None -> None
  | Some (`Bool b) -> Some b
  | Some v -> failwith (Printf.sprintf "corpus %S is not a bool: %s" key (Yojson.Safe.to_string v))

let strings_of_list key items =
  List.map
    (fun item ->
      match item with
      | `String s -> s
      | v -> failwith (Printf.sprintf "corpus %S holds a non-string: %s" key (Yojson.Safe.to_string v)))
    items

let want_strings key value =
  match key $ value with
  | `List items -> strings_of_list key items
  | v -> failwith (Printf.sprintf "corpus %S is not a list: %s" key (Yojson.Safe.to_string v))

let maybe_strings key value =
  match member key value with
  | Some `Null | None -> None
  | Some (`List items) -> Some (strings_of_list key items)
  | Some v -> failwith (Printf.sprintf "corpus %S is not a list: %s" key (Yojson.Safe.to_string v))

let objects_of_list key items =
  List.map
    (fun item ->
      match item with
      | `Assoc _ as object_ -> object_
      | v -> failwith (Printf.sprintf "corpus %S holds a non-object: %s" key (Yojson.Safe.to_string v)))
    items

let want_objects key value =
  match key $ value with
  | `List items -> objects_of_list key items
  | v -> failwith (Printf.sprintf "corpus %S is not a list: %s" key (Yojson.Safe.to_string v))

let maybe_objects key value =
  match member key value with
  | Some `Null | None -> None
  | Some (`List items) -> Some (objects_of_list key items)
  | Some v -> failwith (Printf.sprintf "corpus %S is not a list: %s" key (Yojson.Safe.to_string v))

let flag = function true -> "true" | false -> "false"

let opt_value = function None -> "-" | Some s -> Canon.escape_text s

(* {1 config} *)

(* The projection of one loaded configuration. Field order is fixed by the
   corpus format, and the provider block is sorted by name because the two trees
   keep the file's order differently — the TOML table map is sorted, the Python
   dict keeps insertion order — and nothing reads either. *)
let pct value = Printf.sprintf "%.6f" value

let one_line text =
  String.map (fun ch -> if ch = '\n' || ch = '\r' || ch = '\t' then ' ' else ch) text

let cut_at marker text =
  let length = String.length marker in
  let haystack = String.length text in
  let rec go index =
    if index + length > haystack
    then text
    else if String.sub text index length = marker
    then String.sub text 0 index
    else go (index + 1)
  in
  go 0

let strip_prefix prefix text =
  if String.length text >= String.length prefix
     && String.sub text 0 (String.length prefix) = prefix
  then Some (String.sub text (String.length prefix) (String.length text - String.length prefix))
  else None

(* [seekwright: invalid config in <path>: …] is the loader's own wrapper; the
   path is the corpus file's sandbox location, so it is not part of the fact
   under test. *)
let drop_load_prefix message =
  match strip_prefix "seekwright: invalid config in " message with
  | None -> None
  | Some rest -> (
      match String.index_opt rest ':' with
      | Some colon when colon + 2 <= String.length rest ->
          Some (String.sub rest (colon + 2) (String.length rest - colon - 2))
      | _ -> None)

let provider_line (name, entry : string * Config.provider_config) =
  String.concat " "
    [
      "provider";
      name;
      "enabled=" ^ flag entry.enabled;
      "cost=" ^ (match entry.cost_per_1k with None -> "-" | Some v -> pct v);
      "depth=" ^ entry.depth;
      "output=" ^ Config.show_output_kind entry.output_type;
      "mode=" ^ entry.mode;
      "url=" ^ opt_value entry.url;
      "cooldown=" ^ pct entry.free_cooldown_seconds;
      "app=" ^ opt_value entry.app_id;
      "index=" ^ opt_value entry.index;
      "title_attr=" ^ opt_value entry.title_attr;
      "url_attr=" ^ opt_value entry.url_attr;
      "snippet_attr=" ^ opt_value entry.snippet_attr;
    ]

let list_value = function None -> "-" | Some items -> String.concat "," items

let config_lines (config : Config.t) =
  let strings = String.concat "," in
  [
    "default=" ^ opt_value config.default_provider;
    "permitted=" ^ list_value config.permitted_providers;
    "providers_defaulted=" ^ flag config.providers_defaulted;
    "enabled=" ^ strings (Config.enabled_providers config);
    "effective=" ^ strings (Config.effective_providers config);
    "free_only=" ^ flag (Config.default_route_is_free_only config);
    "missing_keys=" ^ strings (Config.missing_api_keys config);
    "missing_agent=" ^ strings (Config.missing_agent_settings config);
    String.concat ","
      [
        "policy";
        string_of_int config.policy.max_snippet_chars;
        string_of_int config.policy.max_result_text_chars;
        pct config.policy.provider_timeout_seconds;
      ];
    String.concat ","
      [
        "fetch";
        flag config.fetch.enabled;
        config.fetch.extractor;
        pct config.fetch.timeout_seconds;
        string_of_int config.fetch.max_download_bytes;
        string_of_int config.fetch.max_text_chars;
        string_of_int config.fetch.min_text_chars;
        string_of_int config.fetch.max_match_chars;
        string_of_int config.fetch.max_redirects;
        flag config.fetch.allow_private_addresses;
        flag config.fetch.allow_images;
        Canon.escape_text config.fetch.user_agent;
        list_value config.fetch.fallback;
        flag config.fetch.auto_fallback;
        config.fetch.primary;
        (match config.fetch.cost_per_1k with None -> "-" | Some v -> pct v);
        opt_value config.fetch.crawl4ai_url;
        opt_value config.fetch.crawl4ai_token;
        pct config.fetch.crawl4ai_timeout_seconds;
        opt_value config.fetch.cache_dir;
        string_of_int config.fetch.cache_max_bytes;
        string_of_int config.fetch.cache_max_entry_bytes;
        pct config.fetch.cache_ttl_seconds;
      ];
    String.concat ","
      [
        "search";
        list_value config.search.fallback;
        list_value config.search.free_fallback;
        pct config.search.health_interval_seconds;
        string_of_int config.search.health_failure_threshold;
        pct config.search.health_cooldown_seconds;
      ];
    String.concat ","
      [
        "agent";
        flag config.agent.enabled;
        opt_value config.agent.base_url;
        opt_value config.agent.model;
        pct config.agent.timeout_seconds;
        pct config.agent.model_timeout_seconds;
        string_of_int config.agent.max_material_chars;
        string_of_int config.agent.max_output_tokens_brief;
        string_of_int config.agent.max_output_tokens_report;
        (match config.agent.max_cost_usd with None -> "-" | Some v -> pct v);
        (match config.agent.cost_per_1k_in with None -> "-" | Some v -> pct v);
        (match config.agent.cost_per_1k_out with None -> "-" | Some v -> pct v);
      ];
    String.concat ","
      [
        "logging";
        Config.show_log_level config.logging.level;
        Config.show_log_format config.logging.format;
        Config.show_log_level config.logging.library_level;
        flag config.logging.access_log;
        flag config.logging.log_queries;
        flag config.logging.log_content;
      ];
    String.concat ","
      [ "dashboard"; flag config.dashboard.enabled; opt_value config.dashboard.history_path ];
  ]
  @ List.map provider_line (List.sort (fun (a, _) (b, _) -> String.compare a b) config.providers)

(* The refusal half of the projection: a TOML parse refusal is one token, because
   both parsers refuse and each names its own library's wording; a validation
   refusal is the loader's sentence with the file's path and the keyless hint
   taken out. *)
let config_refusal message =
  if String.length message >= String.length "seekwright: invalid TOML in "
     && String.sub message 0 (String.length "seekwright: invalid TOML in ")
        = "seekwright: invalid TOML in "
  then [ "PARSE-ERR" ]
  else
    let sentence =
      match drop_load_prefix message with
      | Some rest -> rest
      | None -> message
    in
    let sentence = cut_at "A config that needs no API key:" sentence in
    [ "ERR " ^ Canon.escape_text (String.concat " " (String.split_on_char ' ' (one_line sentence) |> List.filter (fun s -> s <> ""))) ]

let config path =
  match Config.load (Some path) with
  | Ok config -> config_lines config
  | Error message -> config_refusal message

(* {1 sanitize} *)

let remove_zwsp text =
  let zwsp = Sanitize.zwsp in
  let buffer = Buffer.create (String.length text) in
  let index = ref 0 in
  while !index < String.length text do
    if !index + String.length zwsp <= String.length text
       && String.sub text !index (String.length zwsp) = zwsp
    then index := !index + String.length zwsp
    else (
      Buffer.add_string buffer (String.sub text !index 1);
      incr index)
  done;
  Buffer.contents buffer

let sanitize text =
  let escaped, count = Sanitize.sanitize_text text in
  let again, extra = Sanitize.sanitize_text escaped in
  [
    "count=" ^ string_of_int count;
    "out=" ^ Canon.to_hex escaped;
    "idempotent=" ^ flag (again = escaped && extra = 0);
    "reversible=" ^ flag (remove_zwsp escaped = text);
  ]

(* {1 fetch: URL shape, windowing, image sniffing} *)

let url_case url =
  match Fetcher.validate_url url with
  | Ok normal -> [ "url= " ^ Canon.escape_text normal ]
  | Error message -> [ "url-refused= " ^ Canon.escape_text message ]

let window_case spec =
  let text = want_string "text" spec in
  let offset = want_int "offset" spec in
  let max_chars = want_int "max_chars" spec in
  (* A negative offset is out of contract for the tool surface ([Model] checks
     offset ≥ 0) but in contract for this function, whose docs say only that an
     offset past the end yields an empty window and a truthful flag. [window_text]
     reaches [Array.sub] with a negative index there, so the projection states
     the raise instead of aborting the area: a robustness case whose fact is a
     crash has to be pinnable. Only [Invalid_argument] is caught, so a malformed
     corpus spec — which fails with [Failure] — still stops the run. *)
  match Fetcher.window_text text ~offset ~max_chars with
  | window, more -> [ "window= " ^ Canon.escape_text window; "more=" ^ flag more ]
  | exception Invalid_argument name ->
      [ "raised= Invalid_argument(" ^ Canon.escape_text name ^ ")" ]

let sniff_case spec =
  let body = Canon.of_hex (want_string "hex" spec) in
  [ "image= " ^ opt_value (Fetcher.sniff_image_type body) ]

let cap_case spec =
  let default = want_int "default" spec in
  let max_chars = maybe_int "max_chars" spec in
  let cap = Fetcher.resolved_cap default max_chars in
  [ "cap=" ^ (if cap = Fetcher.uncapped then "uncapped" else string_of_int cap) ]

let fetch_ops =
  [
    ("url", fun spec -> url_case (want_string "url" spec));
    ("window", window_case);
    ("sniff", sniff_case);
    ("cap", cap_case);
  ]

let op_lines table area spec =
  let name = want_string "op" spec in
  match List.assoc_opt name table with
  | Some run -> run spec
  | None -> failwith (Printf.sprintf "the %s corpus has no op %S" area name)

let fetch spec_text = op_lines fetch_ops "fetch" (read_json spec_text)

(* {1 jsondoc and tabledoc} *)

let reprint_steps steps =
  String.concat ""
    (List.map
       (fun step ->
         match step with
         | Jsondoc.Key name -> "." ^ name
         | Jsondoc.Position ordinal -> Printf.sprintf "[%d]" ordinal
         | Jsondoc.Every -> "[*]"
         | Jsondoc.Bounds (start, stop) ->
             Printf.sprintf "[%s:%s]"
               (match start with None -> "" | Some n -> string_of_int n)
               (match stop with None -> "" | Some n -> string_of_int n))
       steps)

let jsondoc_ops =
  [
    ( "render",
      fun spec ->
        let body = want_string "body" spec in
        [ "render= " ^ opt_value (Jsondoc.render_json body) ] );
    ( "structure",
      fun spec ->
        let body = want_string "body" spec in
        (match Jsondoc.render_json body with
        | None -> [ "render= -" ]
        | Some rendered ->
            [ "render= " ^ Canon.escape_text rendered; "schema= " ^ opt_value (Jsondoc.render_schema rendered) ]) );
    ( "select",
      fun spec ->
        let body = want_string "body" spec in
        let path = want_string "path" spec in
        let max_chars = want_int "max_chars" spec in
        (match Jsondoc.render_json body with
        | None -> [ "render= -" ]
        | Some rendered ->
            (try
               let spans, dropped = Jsondoc.select_paths rendered path ~max_chars in
               [
                 "select= "
                 ^ String.concat "|"
                     (List.map
                        (fun (offset, text) -> string_of_int offset ^ ":" ^ Canon.escape_text text)
                        spans);
                 "dropped=" ^ string_of_int dropped;
               ]
             with Jsondoc.Path_syntax message -> [ "path-refused= " ^ Canon.escape_text message ])) );
    ( "parse-path",
      fun spec ->
        let path = want_string "path" spec in
        (try [ "steps= " ^ reprint_steps (Jsondoc.parse_path path) ]
         with Jsondoc.Path_syntax message -> [ "path-refused= " ^ Canon.escape_text message ]) );
    ( "child-path",
      fun spec ->
        let parent = want_string "parent" spec in
        let key =
          match member "key" spec with
          | Some (`Int n) -> Jsondoc.Ordinal n
          | _ -> Jsondoc.Name (want_string "key" spec)
        in
        [ "child= " ^ Canon.escape_text (Jsondoc.child_path parent key) ] );
    ( "media",
      fun spec ->
        let kind = want_string "type" spec in
        [
          "json= " ^ flag (Jsondoc.is_json_media kind);
          "json-document= " ^ flag (Jsondoc.is_json_document_media kind);
        ] );
    ( "sniffs-json",
      fun spec ->
        let body = want_string "body" spec in
        [ "sniffs= " ^ flag (Jsondoc.sniffs_json body) ] );
  ]

let jsondoc spec_text = op_lines jsondoc_ops "jsondoc" (read_json spec_text)

let tabledoc_ops =
  [
    ( "render",
      fun spec ->
        let body = want_string "body" spec in
        let kind = want_string "media" spec in
        let delimiter = Tabledoc.table_delimiter kind body in
        [
          "delimiter= " ^ Canon.escape_text delimiter;
          "table= " ^ flag (Tabledoc.is_table_media kind);
          "render= " ^ opt_value (Tabledoc.render_table body ~delimiter);
        ] );
  ]

let tabledoc spec_text = op_lines tabledoc_ops "tabledoc" (read_json spec_text)

(* {1 text: the codepoint walk and the repr pass}

   The corpus carries these inputs as hex, not as the file's own bytes, for one
   reason: this area is where malformed UTF-8 is the subject rather than an
   accident. The oracle's projection decodes the same bytes with Python's
   [errors="replace"], which is the semantics [Utf8] claims, so a case that
   disagrees is a statement about the walk and not about how the file was read.
   Every value that leaves here is hex or an escaped [repr], so a golden stays
   one ASCII line per fact. *)

let text_bytes spec = Canon.of_hex (want_string "hex" spec)

let counted kind items =
  (kind ^ "s= " ^ string_of_int (List.length items))
  :: List.map (fun item -> kind ^ "= " ^ Canon.to_hex item) items

let text_ops =
  [
    ( "count",
      fun spec ->
        let text = text_bytes spec in
        [ "count= " ^ string_of_int (Utf8.count text) ] );
    ( "take",
      fun spec ->
        let text = text_bytes spec in
        [ "take= " ^ Canon.to_hex (Utf8.take (want_int "limit" spec) text) ] );
    ("strip", fun spec -> [ "strip= " ^ Canon.to_hex (Utf8.strip (text_bytes spec)) ]);
    ("lstrip", fun spec -> [ "lstrip= " ^ Canon.to_hex (Utf8.lstrip (text_bytes spec)) ]);
    ("rstrip", fun spec -> [ "rstrip= " ^ Canon.to_hex (Utf8.rstrip (text_bytes spec)) ]);
    ( "words",
      fun spec -> counted "word" (Utf8.split_whitespace (text_bytes spec)) );
    ( "lines",
      fun spec ->
        counted "line" (List.map Utf8.to_string (Utf8.splitlines (Utf8.of_string (text_bytes spec)))) );
    ( "slices",
      fun spec -> counted "slice" (Array.to_list (Utf8.slices (text_bytes spec))) );
    ( "repr",
      fun spec -> [ "repr= " ^ Canon.escape_text (Repr.py_repr (text_bytes spec)) ] );
    ( "roundtrip",
      fun spec ->
        [ "roundtrip= " ^ Canon.to_hex (Utf8.to_string (Utf8.of_string (text_bytes spec))) ] );
  ]

let text spec_text = op_lines text_ops "text" (read_json spec_text)

(* {1 router} *)

let search_table spec =
  let table = "table" $ spec in
  {
    Router.providers = want_strings "providers" table;
    default = maybe_string "default" table;
    permitted = maybe_strings "permitted" table;
    fallback = want_strings "fallback" table;
    free_fallback = want_strings "free_fallback" table;
    free = want_strings "free" table;
    free_order = want_strings "free_order" table;
    effective = want_strings "effective" table;
  }

let fetch_table spec =
  let table = "table" $ spec in
  { Router.built = want_strings "built" table; primary = maybe_string "primary" table }

let refused message = "refused= " ^ Canon.escape_text message

(* The one call the case makes, named so a projection line says which decision
   produced it. Both trees dispatch the same table through the same names. *)
let router_call (table : Router.search_table) call =
  let name = want_string "fn" call in
  let names key = want_strings key call in
  let requested = maybe_string "requested" call in
  let mode = if maybe_string "mode" call <> None then Some Router.Free else None in
  match name with
  | "resolve_search" -> (
      try [ "resolve_search= " ^ opt_value (Some (Router.resolve_search table ?mode requested)) ]
      with Router.Route_refused message -> [ "resolve_search " ^ refused message ])
  | "is_permitted" -> [ "is_permitted= " ^ flag (Router.is_permitted table (want_string "name" call)) ]
  | "unnamed_walks_free" -> [ "unnamed_walks_free= " ^ flag (Router.unnamed_walks_free table) ]
  | "free_candidates" -> [ "free_candidates= " ^ String.concat "," (Router.free_candidates table) ]
  | "free_walk" -> [ "free_walk= " ^ String.concat "," (Router.free_walk table) ]
  | "fallback_rungs" ->
      let rungs =
        Router.fallback_rungs table ~ladder:(names "ladder") ~tried:(want_string "tried" call)
          ~gated:(names "gated")
      in
      [
        "rungs= "
        ^ String.concat ","
            (List.map (fun rung -> rung.Router.name ^ "/" ^ Router.show_rung_status rung.Router.status) rungs);
      ]
  | "fallback_served_notice" ->
      [
        "notice= "
        ^ Canon.escape_text
            (Router.fallback_served_notice ~tried:(want_string "tried" call)
               ~original_reason:(want_string "original_reason" call)
               ~fallback:(want_string "fallback" call) ~notice:(maybe_string "notice" call));
      ]
  | "fallback_exhausted_note" ->
      [
        "note= "
        ^ Canon.escape_text
            (Router.fallback_exhausted_note ~failed:(names "failed")
               ~mode:(if maybe_string "mode" call <> None then Some Router.Free else None))
      ]
  | "retry_advice" -> [ "advice= " ^ Canon.escape_text (Router.retry_advice ~quota:(want_bool "quota" call)) ]
  | _ -> failwith (Printf.sprintf "router corpus has no fn %S" name)

let fetch_router_call table call =
  let name = want_string "fn" call in
  match name with
  | "fetch_walk" -> [ "fetch_walk= " ^ String.concat "," (Router.fetch_walk table) ]
  | "origin" -> [ "origin= " ^ Canon.escape_text (Router.origin table) ]
  | "provider_names" -> [ "provider_names= " ^ Canon.escape_text (Router.provider_names table) ]
  | "choose_names" -> [ "choose_names= " ^ Canon.escape_text (Router.choose_names table) ]
  | "choose_instead" -> [ "choose_instead= " ^ Canon.escape_text (Router.choose_instead table) ]
  | "empty_notice" -> [ "empty_notice= " ^ Canon.escape_text (Router.empty_notice table ~walked:(want_bool "walked" call)) ]
  | "refetched_notice" ->
      [
        "refetched= "
        ^ Canon.escape_text
            (Router.refetched_notice table ~reason:(want_string "reason" call)
               ~fallback:(want_string "fallback" call));
      ]
  | "not_enabled" -> [ "not_enabled= " ^ Canon.escape_text (Router.not_enabled table (want_string "requested" call)) ]
  | "resolve_fetch" -> (
      try
        (match Router.resolve_fetch table (maybe_string "requested" call) with
        | None -> [ "resolve_fetch= local" ]
        | Some name -> [ "resolve_fetch= " ^ name ])
      with Router.Route_refused message -> [ "resolve_fetch " ^ refused message ])
  | _ -> failwith (Printf.sprintf "fetch router corpus has no fn %S" name)

let router spec_text =
  let spec = read_json spec_text in
  let calls = want_objects "calls" spec in
  let is_search_table =
    match member "table" spec with
    | Some (`Assoc fields) -> List.mem_assoc "providers" fields
    | _ -> false
  in
  if is_search_table
  then
    let table = search_table spec in
    List.concat_map (fun call -> router_call table call) calls
  else
    let table = fetch_table spec in
    List.concat_map (fun call -> fetch_router_call table call) calls

(* {1 model} *)

(* Decode a body into the port's record and re-encode it, in one step per model,
   because that round trip is the whole claim [lib/model.mli] makes: a body the
   oracle accepts becomes the same wire object here, and the encoder's rules —
   unset fields dropped, [Sanitize.text_fields] escaped — are what the golden
   pins. *)
let decode_encode name (body : Yojson.Safe.t) : (Yojson.Safe.t, string) Stdlib.result =
  match name with
  | "result" -> Result.map Model.result_to_yojson (Model.result_of_yojson body)
  | "search_response" ->
      Result.map Model.search_response_to_yojson (Model.search_response_of_yojson body)
  | "fetch_response" ->
      Result.map Model.fetch_response_to_yojson (Model.fetch_response_of_yojson body)
  | "fetch_match" -> Result.map Model.fetch_match_to_yojson (Model.fetch_match_of_yojson body)
  | "fetch_image" -> Result.map Model.fetch_image_to_yojson (Model.fetch_image_of_yojson body)
  | "search_request" ->
      Result.map Model.search_request_to_yojson (Model.search_request_of_yojson body)
  | "fetch_request" -> Result.map Model.fetch_request_to_yojson (Model.fetch_request_of_yojson body)
  | "answer_request" -> Result.map Model.answer_request_to_yojson (Model.answer_request_of_yojson body)
  | "answer_response" ->
      Result.map Model.answer_response_to_yojson (Model.answer_response_of_yojson body)
  | "answer_source" ->
      Result.map Model.answer_source_to_yojson (Model.answer_source_of_yojson body)
  | "search_query" -> Result.map Model.search_query_to_yojson (Model.search_query_of_yojson body)
  | "provider_result" ->
      Result.map Model.provider_result_to_yojson (Model.provider_result_of_yojson body)
  | _ -> failwith (Printf.sprintf "model corpus has no model %S" name)

(* A refusal is a verdict, not a sentence: pydantic reports a structured error
   list and the port states the same fault as one sentence, and [lib/model.mli]
   records that as an accepted difference. The corpus therefore pins that both
   trees refuse the same body. *)
let model spec_text =
  let spec = read_json spec_text in
  List.concat_map
    (fun case ->
      let name = want_string "model" case in
      (* [body_text] carries a raw JSON document so a duplicate key can reach the
         decoder with both members still in it: a corpus spec written as an
         object would have collapsed them before the port saw anything. *)
      let body =
        match member "body_text" case with
        | Some (`String text) -> read_json text
        | _ -> "body" $ case
      in
      match decode_encode name body with
      | Ok encoded -> [ "verdict= accept"; "wire= " ^ Canon.canon_json encoded ]
      | Error _ -> [ "verdict= reject" ])
    (want_objects "cases" spec)

(* {1 engine: the search walk over scripted providers}

   The scripted provider is the position [StubProvider] holds in
   [tests/test_engine.py] and [httpx.MockTransport] holds in the adapter suites:
   the case names the provider's behaviour, the projection reads what the engine
   did with it. [attempts] is the seam's own record — which names the engine
   dispatched, in order — and it is the projection's most informative line: a
   ladder that walks the wrong rung shows up here before anywhere else. *)

type state = {
  name : string;
  cost : float;
  fail : Provider.error option;
  results : Provider.hit list;
  answer : string option;
  notice : string option;
}

let stub (state : state) (attempts : string list ref) : Provider.t =
  (module struct
    let name = state.name
    let cost_per_1k = state.cost
    let cost_for _count = state.cost

    let search _query =
      attempts := state.name :: !attempts;
      match state.fail with
      | Some error -> Error error
      | None ->
          Ok
            {
              Provider.provider = state.name;
              results = state.results;
              answer = state.answer;
              cost_usd = None;
              notice = state.notice;
            }

    let aclose () = ()
  end : Provider.S)

let recency_of_string = function
  | "day" -> Some Model.Day
  | "week" -> Some Model.Week
  | "month" -> Some Model.Month
  | "year" -> Some Model.Year
  | other -> failwith (Printf.sprintf "engine corpus recency %S" other)

let hit body =
  {
    Provider.result =
      (match Model.result_of_yojson body with
      | Ok result -> result
      | Error message -> failwith (Printf.sprintf "engine corpus result: %s" message));
    uncapped_chars = None;
  }

let error_of_spec provider spec =
  match maybe_string "kind" spec with
  | None -> None
  | Some kind -> (
      let message = want_string "message" spec in
      match kind with
      | "failure" -> Some (Provider.provider_error ~provider ~retryable:(want_bool "retryable" spec) message)
      | "quota" -> Some (Provider.quota_exhausted ~provider ~message ())
      | _ -> failwith (Printf.sprintf "engine corpus failure kind %S" kind))

let engine_provider_entry spec =
  let name = want_string "name" spec in
  let results =
    match maybe_objects "results" spec with
    | None -> []
    | Some bodies -> List.map hit bodies
  in
  ( name,
    {
      name;
      cost = (match member "cost" spec with Some (`Float f) -> f | Some (`Int n) -> float_of_int n | _ -> 0.);
      fail = error_of_spec name spec;
      results;
      answer = maybe_string "answer" spec;
      notice = maybe_string "notice" spec;
    } )

let engine_config spec =
  let section = "config" $ spec in
  let entries =
    match member "providers" section with
    | Some (`Assoc members) ->
        List.map
          (fun (name, entry) ->
            ( name,
              {
                Config.default_provider_config with
                enabled = want_bool "enabled" entry;
                cost_per_1k = maybe_float "cost_per_1k" entry;
                depth = (match maybe_string "depth" entry with Some d -> d | None -> Config.default_provider_config.depth);
                mode = (match maybe_string "mode" entry with Some m -> m | None -> Config.default_provider_config.mode);
                url = maybe_string "url" entry;
              } ))
          members
    | _ -> []
  in
  let search_section =
    match member "search" section with
    | Some (`Assoc _ as search) ->
        {
          Config.default_search_config with
          fallback = maybe_strings "fallback" search;
          free_fallback = maybe_strings "free_fallback" search;
        }
    | _ -> Config.default_search_config
  in
  match
    Config.resolve ~providers:entries
      ?default_provider:(maybe_string "default_provider" section)
      ?permitted_providers:(maybe_strings "permitted_providers" section)
      ~search:search_section ()
  with
  | Ok config -> config
  | Error message -> failwith (Printf.sprintf "engine corpus config: %s" message)

let attempt_lines attempts = List.map (fun name -> "attempt " ^ name) attempts

let engine_call engine call attempts events =
  let query =
    {
      Model.query = want_string "query" call;
      max_results = (match maybe_int "max_results" call with Some n -> n | None -> 5);
      include_domains = (match maybe_strings "include_domains" call with Some xs -> xs | None -> []);
      exclude_domains = (match maybe_strings "exclude_domains" call with Some xs -> xs | None -> []);
      country = maybe_string "country" call;
      language = maybe_string "language" call;
      recency = (match maybe_string "recency" call with Some s -> recency_of_string s | None -> None);
      safe_search = maybe_bool "safe_search" call;
    }
  in
  let mode = if maybe_string "mode" call <> None then Some Router.Free else None in
  let provider = maybe_string "provider" call in
  let lines =
    match Engine.Search.search engine ?provider ?mode query with
    | Ok response ->
        [
          "verdict= ok";
          "provider= " ^ response.Model.provider;
          "results=" ^ string_of_int (List.length response.Model.results);
          "titles="
          ^ String.concat ","
              (List.map (fun (hit : Model.result) -> Canon.escape_text hit.Model.title) response.Model.results);
          "notice=" ^ opt_value response.Model.notice;
        ]
    | Error (Engine.Search.Refused message) -> [ "verdict= refused"; "message= " ^ Canon.escape_text message ]
    | Error (Engine.Search.Failed message) -> [ "verdict= failed"; "message= " ^ Canon.escape_text message ]
  in
  List.rev (attempt_lines !attempts) @ [ "events= " ^ String.concat "," (List.rev !events) ] @ lines


let engine spec_text =
  let spec = read_json spec_text in
  let config = engine_config spec in
  let attempts = ref [] in
  let events = ref [] in
  let entries =
    List.map
      (fun spec ->
        let name, state = engine_provider_entry spec in
        (name, stub state attempts))
      (want_objects "providers" spec)
  in
  let log _level event _fields = events := event :: !events in
  let engine =
    Engine.Search.create config entries ~log ~clock:(fun () -> 1768478400.) ~now:(fun () -> 1768478400.) ()
  in
  let lines =
    List.concat_map
      (fun call ->
        attempts := [];
        events := [];
        engine_call engine call attempts events)
      (want_objects "calls" spec)
  in
  lines

(* {2 The area table}

   One entry per corpus directory, and the golden runner walks this list rather
   than a list of its own: an area nobody runs is an area nobody tests. *)
let areas =
  [
    ("config", fun path -> config path);
    ("sanitize", sanitize);
    ("fetch", fetch);
    ("jsondoc", jsondoc);
    ("tabledoc", tabledoc);
    ("text", text);
    ("router", router);
    ("model", model);
    ("engine", engine);
  ]
