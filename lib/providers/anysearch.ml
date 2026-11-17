module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider

let name = "anysearch"

let endpoint = Uri.of_string "https://api.anysearch.com/v1/search"

let policy_endpoint = Provider.policy_of_uri endpoint

let max_results = 10

let clamp_results n = min (max n 1) max_results

(* Upstream limit 1-10; language code lowercased. *)
let request_body (q : Provider.search_query) =
  let fields =
    [ ("query", `String q.Model.query); ("max_results", `Int (clamp_results q.Model.max_results)) ]
  in
  let fields =
    match q.Model.language with
    | Some code -> fields @ [ ("language", `String (String.lowercase_ascii code)) ]
    | None -> fields
  in
  Yojson.Safe.to_string (`Assoc fields)

(* Records sit under [data.results]; the top-level [code] says whether the call
   succeeded at all. *)
let parse ~snippet_chars data ~limit =
  Provider.map_records ~list_path:[ "data"; "results" ] ~url_field:"url" ~title_field:"title"
    ~snippet_field:"snippet" ~snippet_chars ~limit data

(* 402 indicates quota exhaustion. The message is fixed wording rather than the
   body's, because a generated credential can sit in that body. *)
let check_status =
  Provider.check_status ~provider:name ~quota_message:"out of credits or rate limited"

(* Upstream success requires code 0. Body error message is not echoed for security. *)
let check_business_code data =
  match Provider.Json.field "code" data with
  | `Int 0 | `Float 0. -> Ok ()
  | _ -> Error (Provider.provider_error ~provider:name "search failed (business error)")

(* Keyless; zero cost. *)
let cost_for ~cost_per_1k _max_results = cost_per_1k /. 1000.

let search ~cost_per_1k ~snippet_chars (net : Provider.Net.t) (q : Provider.search_query) =
  Provider.http_search ~provider:name ~net ~status:check_status
    ~request:
      {
        Caps.Authority.Net.meth = `POST;
        uri = endpoint;
        headers = [ ("content-type", "application/json") ];
        body = Some (request_body q);
      }
    ~cost_for:(cost_for ~cost_per_1k) ~parse:(parse ~snippet_chars) ~check:check_business_code
    ~notice:(fun q _data ->
      Provider.ignored_constraints q ~domains:false ~dates:false ~geo:false ~language:(Some true)
        ~safety:false)
    q

let make ?(cost_per_1k = 0.) ?(snippet_chars = 500) ~net () : Provider.t =
  (module struct
    let name = name
    let cost_per_1k = cost_per_1k
    let cost_for = cost_for ~cost_per_1k
    let search = search ~cost_per_1k ~snippet_chars net

    (* Shared network grant; must not be closed by adapter instance. *)
    let aclose () = ()
  end : Provider.S)
