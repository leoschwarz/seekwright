(* Algolia, ported from src/seekwright/providers/algolia.py. *)

module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider

let name = "algolia"

(* The DSN host {i is} the deployment: [app_id] names it, [index] names what is
   searched, and the index rides the path percent-encoded so a name like
   [products/2026] cannot escape its segment — [quote(index, safe="")] in the
   oracle, which is {!Seekwright.Provider.escape_path_segment}. This is the one
   spelling of the derivation: the registry resolves the row's endpoint and the
   grant entry from here, so the destination in the request and the destination
   in the confinement cannot drift. *)
let endpoint_of_deployment ~app_id ~index =
  Uri.make ~scheme:"https" ~host:(app_id ^ "-dsn.algolia.net")
    ~path:("/1/indexes/" ^ Provider.escape_path_segment index ^ "/query")
    ()

(* The first attribute holding a plain scalar, coerced to text. Records are
   schemaless JSON, so a wrong type counts as absent and the chain continues
   rather than failing the whole hit — the oracle's [isinstance] chain, [bool]
   excluded: JSON [true] is not the prose a [title] claims to be. The textual
   rendering of a number is the round-trip shortest one, which is what Python's
   [str] writes for a number parsed out of JSON text. *)
let scalar_text (value : Yojson.Safe.t) =
  match value with
  | `String text -> Some text
  | `Int n -> Some (string_of_int n)
  | `Intlit text -> Some text
  | `Float f -> Some (Yojson.Safe.to_string (`Float f))
  | _ -> None

let first_str attrs record =
  let rec go = function
    | [] -> None
    | attr :: rest -> (
        match scalar_text (Provider.Json.field attr record) with
        | Some text -> Some text
        | None -> go rest)
  in
  go attrs

(* DocSearch-shaped records keep their title in [hierarchy.lvl0]..[lvl6], and the
   most specific non-empty level is the displayed title — as DocSearch's own
   frontend renders these records. *)
let hierarchy_title record =
  let hierarchy = Provider.Json.field "hierarchy" record in
  match Provider.Json.members hierarchy with
  | None -> None
  | Some _ ->
      let rec go level =
        if level < 0 then None
        else
          match Provider.Json.string_field ("lvl" ^ string_of_int level) hierarchy with
          | Some text when text <> "" -> Some text
          | _ -> go (level - 1)
      in
      go 6

let take n items =
  let rec go count items acc =
    if count <= 0 then List.rev acc
    else match items with [] -> List.rev acc | item :: rest -> go (count - 1) rest (item :: acc)
  in
  go n items []

(* [hits[]] mapped onto title/url/snippet. An explicitly configured [*]_attr is
   used alone — no chain, no hierarchy fallback — because an operator who names
   an attribute has said what their records hold; the common-name chains and the
   hierarchy fallback are the guesses that fill in when nobody said. The slice is
   of the upstream list before anything is dropped, and an empty string counts as
   a missing title or url: a result the caller cannot cite or follow is not a
   result. *)
let parse ~snippet_chars ?title_attr ?url_attr ?snippet_attr data ~limit =
  let records =
    match Provider.Json.list (Provider.Json.field "hits" data) with
    | Some items -> items
    | None -> []
  in
  List.filter_map
    (fun record ->
      match Provider.Json.members record with
      | None -> None
      | Some _ ->
          let title =
            match title_attr with
            | Some attr -> first_str [attr] record
            | None -> (
                match first_str [ "title"; "name"; "question" ] record with
                | Some title -> Some title
                | None -> hierarchy_title record)
          in
          let url =
            match url_attr with
            | Some attr -> first_str [attr] record
            | None -> first_str [ "url"; "link" ] record
          in
          match (title, url) with
          | Some title, Some url when title <> "" && url <> "" ->
              let snippet =
                match snippet_attr with
                | Some attr -> first_str [attr] record
                | None ->
                    first_str [ "description"; "summary"; "excerpt"; "content"; "answer" ]
                      record
              in
              let snippet, uncapped_chars =
                Provider.truncate_snippet snippet snippet_chars
              in
              Some
                {
                  Provider.result =
                    {
                      Model.title;
                      url;
                      snippet;
                      (* Schemaless records carry no date or relevance this adapter
                         could rescale, and the SERP shape promises no page text. *)
                      text = None;
                      text_truncated = None;
                      published_date = None;
                      score = None;
                    };
                  uncapped_chars;
                }
          | _ -> None)
    (take limit records)

let check_status status =
  if status = 401 || status = 403 then
    (* 403, not 401, is Algolia's answer for an invalid Application-ID or key. *)
    Error (Provider.auth_error ~provider:name)
  else if status = 402 || status = 429 then
    (* 402 is Algolia's [FeatureNotEnabled]: a plan question, like the 429 rate
       limit — both answer what a [Grow] upgrade would change, so both move the
       quota fallback walk. *)
    Error (Provider.quota_exhausted ~provider:name ())
  else if status >= 400 then Error (Provider.http_status_error ~provider:name status)
  else Ok ()

(* Per-query cost in USD. Flat: Algolia bills per search request {i whatever it
   returns}, so [max_results] never scales the figure. The argument is ignored
   rather than absent because callers treat [cost_for] as the same duck-typed
   extra on every adapter. *)
let cost_for ~cost_per_1k _max_results = cost_per_1k /. 1000.

let request_body (q : Provider.search_query) =
  Yojson.Safe.to_string
    (`Assoc
      [
        ("query", `String q.Model.query);
        ("hitsPerPage", `Int q.Model.max_results);
      ])

let search ~app_id ~title_attr ~url_attr ~snippet_attr ~cost_per_1k ~snippet_chars
    ~key ~endpoint (net : Provider.Net.t) (q : Provider.search_query) =
  let ( let* ) = Result.bind in
  let request =
    {
      Caps.Authority.Net.meth = `POST;
      uri = endpoint;
      (* Both headers, and only on the deployment's own host: the Application-ID
         identifies the deployment and the key authorises the index — a key alone
         names nothing. *)
      headers =
        [
          ("x-algolia-application-id", app_id);
          ("x-algolia-api-key", key);
          ("Content-Type", "application/json");
        ];
      body = Some (request_body q);
    }
  in
  match net.request request with
  | Error failure -> Error (Provider.transport_error ~provider:name failure)
  | Ok response ->
      let* () = check_status response.status in
      let* data = Provider.decode_json_object ~provider:name response.body in
      Ok
        {
          Provider.provider = name;
          results =
            parse ~snippet_chars ?title_attr ?url_attr ?snippet_attr data
              ~limit:q.Model.max_results;
          (* The provider returns the operator's records, not prose. *)
          answer = None;
          cost_usd = Some (cost_for ~cost_per_1k q.Model.max_results);
          (* No filter field in this API; the record schema is the operator's. *)
          notice =
            Provider.ignored_constraints q ~domains:false ~dates:false ~geo:false
              ~language:None ~safety:false;
        }

let make ?(cost_per_1k = 0.50) ?(snippet_chars = 500) ?title_attr ?url_attr
    ?snippet_attr ~app_id ~key ~endpoint ~net () : Provider.t =
  (module struct
    let name = name
    let cost_per_1k = cost_per_1k
    let cost_for = cost_for ~cost_per_1k
    let search =
      search ~app_id ~title_attr ~url_attr ~snippet_attr ~cost_per_1k ~snippet_chars
        ~key ~endpoint net

    (* The grant is the server's, not the adapter's: closing it would break the
       sibling providers that share the same confinement. *)
    let aclose () = ()
  end : Provider.S)
