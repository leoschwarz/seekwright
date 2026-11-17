module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider

let name = "algolia"

(* The index rides the path percent-encoded so a name like [products/2026] cannot
   escape its segment. The registry and adapter share this single derivation. *)
let endpoint_of_deployment ~app_id ~index =
  Uri.make ~scheme:"https" ~host:(app_id ^ "-dsn.algolia.net")
    ~path:("/1/indexes/" ^ Provider.escape_path_segment index ^ "/query")
    ()

(* Coerces scalar values to text; booleans excluded as they are not prose. *)
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

(* DocSearch-shaped records keep title in [hierarchy.lvl0]..[lvl6]; most specific
   non-empty level wins. *)
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

(* Configured attribute overrides fallback chain. Sliced before validation;
   empty title or url drops the record. *)
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
      | Some _ -> (
          let title =
            match title_attr with
            | Some attr -> first_str [ attr ] record
            | None -> (
                match first_str [ "title"; "name"; "question" ] record with
                | Some title -> Some title
                | None -> hierarchy_title record)
          in
          let url =
            match url_attr with
            | Some attr -> first_str [ attr ] record
            | None -> first_str [ "url"; "link" ] record
          in
          match (title, url) with
          | Some title, Some url when title <> "" && url <> "" ->
              let snippet =
                match snippet_attr with
                | Some attr -> first_str [ attr ] record
                | None ->
                    first_str [ "description"; "summary"; "excerpt"; "content"; "answer" ] record
              in
              let snippet, uncapped_chars = Provider.truncate_snippet snippet snippet_chars in
              Some
                {
                  Provider.result =
                    {
                      Model.title;
                      url;
                      snippet;
                      text = None;
                      text_truncated = None;
                      published_date = None;
                      score = None;
                    };
                  uncapped_chars;
                }
          | _ -> None))
    (Provider.take limit records)

(* Flat rate per request; max_results is ignored. *)
let cost_for ~cost_per_1k _max_results = cost_per_1k /. 1000.

let request_body (q : Provider.search_query) =
  Yojson.Safe.to_string
    (`Assoc [ ("query", `String q.Model.query); ("hitsPerPage", `Int q.Model.max_results) ])

(* 403, not 401, is Algolia's answer for an invalid Application-ID or key, and
   402 is its [FeatureNotEnabled] rather than a plain billing error. Those are
   the shared status mapping's own rows with its default wording, so this adapter
   sends no [~status] of its own. *)
let search ~app_id ~title_attr ~url_attr ~snippet_attr ~cost_per_1k ~snippet_chars ~key ~endpoint
    (net : Provider.Net.t) (q : Provider.search_query) =
  Provider.http_search ~provider:name ~net
    ~request:
      {
        Caps.Authority.Net.meth = `POST;
        uri = endpoint;
        (* Application-ID identifies deployment, API key authorises index. *)
        headers =
          [
            ("x-algolia-application-id", app_id);
            ("x-algolia-api-key", key);
            ("Content-Type", "application/json");
          ];
        body = Some (request_body q);
      }
    ~cost_for:(cost_for ~cost_per_1k)
    ~parse:(parse ~snippet_chars ?title_attr ?url_attr ?snippet_attr)
    ~notice:(fun q _data ->
      Provider.ignored_constraints q ~domains:false ~dates:false ~geo:false ~language:None
        ~safety:false)
    q

let make ?(cost_per_1k = 0.50) ?(snippet_chars = 500) ?title_attr ?url_attr ?snippet_attr ~app_id
    ~key ~endpoint ~net () : Provider.t =
  (module struct
    let name = name
    let cost_per_1k = cost_per_1k
    let cost_for = cost_for ~cost_per_1k
    let search =
      search ~app_id ~title_attr ~url_attr ~snippet_attr ~cost_per_1k ~snippet_chars ~key ~endpoint
        net

    (* Shared network grant; must not be closed by adapter instance. *)
    let aclose () = ()
  end : Provider.S)
