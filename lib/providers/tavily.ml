(* Tavily, ported from src/seekwright/providers/tavily.py. *)

module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider

let name = "tavily"

let endpoint = Uri.of_string "https://api.tavily.com/search"

(* The endpoint the grant must allow, in the policy's own words: derived from the
   URI this adapter dials rather than written beside it, so what is asked for and
   what is allowed cannot disagree. *)
let policy_endpoint = Provider.policy_of_uri endpoint

(* Tavily's [country] is a closed enum of lowercase English country names, valid
   only on the [general] topic this adapter uses, so the two-letter code a caller
   sends has to be translated onto it. The map is the vendor enum read from the
   inside: the two entries that are not ISO codes ([uk], [usa]) are the aliases
   callers actually write and Tavily's enum does not list, and the two Congo codes
   share one entry because which of them a regional boost resolves to is upstream's
   semantics, not ours. *)
let country_by_code =
  [
    ("af", "afghanistan");
    ("al", "albania");
    ("dz", "algeria");
    ("ad", "andorra");
    ("ao", "angola");
    ("ar", "argentina");
    ("am", "armenia");
    ("au", "australia");
    ("at", "austria");
    ("az", "azerbaijan");
    ("bs", "bahamas");
    ("bh", "bahrain");
    ("bd", "bangladesh");
    ("bb", "barbados");
    ("by", "belarus");
    ("be", "belgium");
    ("bz", "belize");
    ("bj", "benin");
    ("bt", "bhutan");
    ("bo", "bolivia");
    ("ba", "bosnia and herzegovina");
    ("bw", "botswana");
    ("br", "brazil");
    ("bn", "brunei");
    ("bg", "bulgaria");
    ("bf", "burkina faso");
    ("bi", "burundi");
    ("kh", "cambodia");
    ("cm", "cameroon");
    ("ca", "canada");
    ("cv", "cape verde");
    ("cf", "central african republic");
    ("td", "chad");
    ("cl", "chile");
    ("cn", "china");
    ("co", "colombia");
    ("km", "comoros");
    ("cg", "congo");
    ("cd", "congo");
    ("cr", "costa rica");
    ("hr", "croatia");
    ("cu", "cuba");
    ("cy", "cyprus");
    ("cz", "czech republic");
    ("dk", "denmark");
    ("dj", "djibouti");
    ("do", "dominican republic");
    ("ec", "ecuador");
    ("eg", "egypt");
    ("sv", "el salvador");
    ("gq", "equatorial guinea");
    ("er", "eritrea");
    ("ee", "estonia");
    ("et", "ethiopia");
    ("fj", "fiji");
    ("fi", "finland");
    ("fr", "france");
    ("ga", "gabon");
    ("gm", "gambia");
    ("ge", "georgia");
    ("de", "germany");
    ("gh", "ghana");
    ("gr", "greece");
    ("gt", "guatemala");
    ("gn", "guinea");
    ("ht", "haiti");
    ("hn", "honduras");
    ("hu", "hungary");
    ("is", "iceland");
    ("in", "india");
    ("id", "indonesia");
    ("ir", "iran");
    ("iq", "iraq");
    ("ie", "ireland");
    ("il", "israel");
    ("it", "italy");
    ("jm", "jamaica");
    ("jp", "japan");
    ("jo", "jordan");
    ("kz", "kazakhstan");
    ("ke", "kenya");
    ("kw", "kuwait");
    ("kg", "kyrgyzstan");
    ("lv", "latvia");
    ("lb", "lebanon");
    ("ls", "lesotho");
    ("lr", "liberia");
    ("ly", "libya");
    ("li", "liechtenstein");
    ("lt", "lithuania");
    ("lu", "luxembourg");
    ("mg", "madagascar");
    ("mw", "malawi");
    ("my", "malaysia");
    ("mv", "maldives");
    ("ml", "mali");
    ("mt", "malta");
    ("mr", "mauritania");
    ("mu", "mauritius");
    ("mx", "mexico");
    ("md", "moldova");
    ("mc", "monaco");
    ("mn", "mongolia");
    ("me", "montenegro");
    ("ma", "morocco");
    ("mz", "mozambique");
    ("mm", "myanmar");
    ("na", "namibia");
    ("np", "nepal");
    ("nl", "netherlands");
    ("nz", "new zealand");
    ("ni", "nicaragua");
    ("ne", "niger");
    ("ng", "nigeria");
    ("kp", "north korea");
    ("mk", "north macedonia");
    ("no", "norway");
    ("om", "oman");
    ("pk", "pakistan");
    ("pa", "panama");
    ("pg", "papua new guinea");
    ("py", "paraguay");
    ("pe", "peru");
    ("ph", "philippines");
    ("pl", "poland");
    ("pt", "portugal");
    ("qa", "qatar");
    ("ro", "romania");
    ("ru", "russia");
    ("rw", "rwanda");
    ("sa", "saudi arabia");
    ("sn", "senegal");
    ("rs", "serbia");
    ("sg", "singapore");
    ("sk", "slovakia");
    ("si", "slovenia");
    ("so", "somalia");
    ("za", "south africa");
    ("kr", "south korea");
    ("ss", "south sudan");
    ("es", "spain");
    ("lk", "sri lanka");
    ("sd", "sudan");
    ("se", "sweden");
    ("ch", "switzerland");
    ("sy", "syria");
    ("tw", "taiwan");
    ("tj", "tajikistan");
    ("tz", "tanzania");
    ("th", "thailand");
    ("tg", "togo");
    ("tt", "trinidad and tobago");
    ("tn", "tunisia");
    ("tr", "turkey");
    ("tm", "turkmenistan");
    ("ug", "uganda");
    ("ua", "ukraine");
    ("ae", "united arab emirates");
    ("gb", "united kingdom");
    ("us", "united states");
    ("uy", "uruguay");
    ("uz", "uzbekistan");
    ("ve", "venezuela");
    ("vn", "vietnam");
    ("ye", "yemen");
    ("zm", "zambia");
    ("zw", "zimbabwe");
    ("uk", "united kingdom");
    ("usa", "united states");
  ]

(* The enum's own words, so a caller who sends [france] rather than [fr] goes
   through unchanged instead of being looked up as a code and dropped. [List.mem]
   over 166 names is the cost of not carrying a set module here; a country filter
   is one lookup per search. *)
let country_names = List.map snd country_by_code

(* A country outside the enum is not guessed at: {!country_param} answers [None]
   and the caller drops the parameter and files the notice, because sending a name
   Tavily does not recognise would either be rejected outright or silently ignored
   with no word back. *)
let country_param value =
  let lowered = String.lowercase_ascii (String.trim value) in
  if List.mem lowered country_names then Some lowered else List.assoc_opt lowered country_by_code

(* [search_depth] stays pinned at [basic]: [advanced] is a different price per
   search, and a rung that multiplies the bill belongs to the operator's config the
   way Linkup's [depth] does, not to a model's tool call. [include_usage] asks for
   the vendor's own credit count — see the note on {!search}. *)
let request_body ~(country : string option) (q : Provider.search_query) =
  let fields =
    [
      ("query", `String q.Model.query);
      ("search_depth", `String "basic");
      ("max_results", `Int q.Model.max_results);
      ("include_answer", `String "basic");
      ("include_raw_content", `Bool false);
    ]
  in
  let fields = fields @ [ ("include_usage", `Bool true) ] in
  let fields =
    match q.Model.recency with
    (* The vendor's own four words are the four rungs of [recency], so the mapping
       is the identity and no clock is needed: [time_range] is a window, not a date. *)
    | Some period ->
        let word =
          match period with
          | Model.Day -> "day"
          | Model.Week -> "week"
          | Model.Month -> "month"
          | Model.Year -> "year"
        in
        fields @ [ ("time_range", `String word) ]
    | None -> fields
  in
  (* Native domain fields, so the query goes verbatim: no [site:] folding, and a
     search that carries both lists is refused upstream rather than resolved here. *)
  let fields =
    if q.Model.include_domains <> [] then
      fields
      @ [
          ( "include_domains",
            `List (List.map (fun domain -> `String domain) q.Model.include_domains) );
        ]
    else fields
  in
  let fields =
    if q.Model.exclude_domains <> [] then
      fields
      @ [
          ( "exclude_domains",
            `List (List.map (fun domain -> `String domain) q.Model.exclude_domains) );
        ]
    else fields
  in
  let fields =
    match country with
    | Some country -> fields @ [ ("country", `String country) ]
    | None -> fields
  in
  let fields =
    match q.Model.language with
    | Some code -> fields @ [ ("language", `String (String.lowercase_ascii code)) ]
    | None -> fields
  in
  (* Sent only when asked: [None] leaves Tavily's default standing, and [Some
     false] is a request the vendor can honour, so unlike the adapters with no
     safety parameter this one files no notice for it. *)
  let fields =
    match q.Model.safe_search with
    | Some value -> fields @ [ ("safe_search", `Bool value) ]
    | None -> fields
  in
  Yojson.Safe.to_string (`Assoc fields)

(* The published date Tavily adds for some records. Kept only when it is a
   string: a nested object there is upstream shape drift, and the contract
   resolves that to a dropped field rather than an internal error. *)
let published_date item = Provider.Json.string_field "published_date" item

let score item = Provider.Json.number_field "score" item

let parse ~text_chars data ~limit =
  let records =
    match Provider.Json.list (Provider.Json.field "results" data) with
    | Some items -> items
    | None -> []
  in
  let rec take n items acc =
    if n <= 0 then List.rev acc
    else
      match items with
      | [] -> List.rev acc
      | item :: rest -> take (n - 1) rest (item :: acc)
  in
  (* The limit slices the upstream list before anything is dropped, so a record
     that fails to parse still spends one of the slots. *)
  List.filter_map
    (fun item ->
      match (Provider.Json.string_field "url" item, Provider.Json.string_field "title" item) with
      | Some url, Some title when url <> "" && title <> "" ->
          (* A content backend: the extract goes in [text] and [snippet] stays
             empty, because filling both ships the same prose twice. *)
          let text, text_truncated, uncapped_chars =
            Provider.truncate_text (Provider.Json.string_field "content" item) text_chars
          in
          Some
            {
              Provider.result =
                {
                  Model.title;
                  url;
                  snippet = None;
                  text;
                  text_truncated = (if text_truncated then Some true else None);
                  published_date = published_date item;
                  score = score item;
                };
              uncapped_chars;
            }
      | _ -> None)
    (take limit records [])

(* Tavily's answer is prose the vendor writes over the same material, requested
   with [include_answer]. It rides [Provider.outcome.answer] and reaches the
   caller as the [search] tool's [answer] field. *)
let answer data = Provider.Json.string_field "answer" data

let check_status status =
  if status = 401 || status = 403 then Error (Provider.auth_error ~provider:name)
  else if status = 429 || status = 432 then
    (* 432 is Tavily's own monthly-credits-exhausted code and 429 is short-term
       rate limiting: different limits, the same consequence for this deployment,
       and the quota class is what moves the fallback walk off this name. *)
    Error (Provider.quota_exhausted ~provider:name ~message:"rate limited or out of credits" ())
  else if status >= 400 then Error (Provider.http_status_error ~provider:name status)
  else Ok ()

(* Per-query cost in USD, flat: a basic Tavily search is one credit whatever the
   result count, so [max_results] does not scale it. The oracle also reads the
   vendor's [usage.credits] back as a check on that figure, for the
   [--check --live] cost-drift diff. [Provider.outcome] has no private channel to
   carry an actual-usage figure, so the ask stays on the wire for request parity
   and the reported number is the one field this port leaves uncarried. *)
let cost_for ~cost_per_1k _max_results = cost_per_1k /. 1000.

let search ~cost_per_1k ~text_chars ~key (net : Provider.Net.t) (q : Provider.search_query) =
  let ( let* ) = Result.bind in
  let country =
    match q.Model.country with Some code -> country_param code | None -> None
  in
  let request =
    {
      Caps.Authority.Net.meth = `POST;
      uri = endpoint;
      (* The key is a bearer token in a header, never a query parameter, so no URL
         that reaches a log or an error can carry it. *)
      headers = [ ("Authorization", "Bearer " ^ key); ("Content-Type", "application/json") ];
      body = Some (request_body ~country q);
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
          results = parse ~text_chars data ~limit:q.Model.max_results;
          answer = answer data;
          cost_usd = Some (cost_for ~cost_per_1k q.Model.max_results);
          (* Domain lists, [time_range], [language] and [safe_search] are all
             native. [country] is native {i only when the code maps}, so [geo] is
             answered per call rather than per adapter: an unmappable code drops
             the parameter and the notice names it. *)
          notice =
            Provider.ignored_constraints q ~domains:true ~dates:true ~geo:(country <> None)
              ~language:(Some true) ~safety:true;
        }

let make ?(cost_per_1k = 8.00) ?(text_chars = 2000) ~key ~net () : Provider.t =
  (module struct
    let name = name
    let cost_per_1k = cost_per_1k
    let cost_for = cost_for ~cost_per_1k
    let search = search ~cost_per_1k ~text_chars ~key net

    (* The grant is the server's, not the adapter's: closing it would break the
       sibling providers that share the same confinement. *)
    let aclose () = ()
  end : Provider.S)
