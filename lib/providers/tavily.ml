module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider

let name = "tavily"

let endpoint = Uri.of_string "https://api.tavily.com/search"

(* Closed enum of lowercase English country names for general search. *)
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

let country_names = List.map snd country_by_code

let country_param value =
  let lowered = String.lowercase_ascii (String.trim value) in
  if List.mem lowered country_names then Some lowered else List.assoc_opt lowered country_by_code

(* search_depth pinned to basic to avoid higher pricing tier. *)
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
    match country with Some country -> fields @ [ ("country", `String country) ] | None -> fields
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
  Provider.map_content_records ~list_path:[ "results" ] ~url_field:"url" ~title_field:"title"
    ~content_field:"content" ~content_chars:text_chars ~date:published_date ~score ~limit data

let answer data = Provider.Json.string_field "answer" data

(* Flat rate per request. *)
let cost_for ~cost_per_1k _max_results = cost_per_1k /. 1000.

(* 432 is monthly credit exhaustion; 429 is rate limit. *)
let check_status =
  Provider.check_status ~provider:name ~quota:[ 429; 432 ]
    ~quota_message:"rate limited or out of credits"

let search ~cost_per_1k ~text_chars ~key (net : Provider.Net.t) (q : Provider.search_query) =
  let country = match q.Model.country with Some code -> country_param code | None -> None in
  Provider.http_search ~provider:name ~net ~status:check_status
    ~request:
      {
        Caps.Authority.Net.meth = `POST;
        uri = endpoint;
        headers = [ ("Authorization", "Bearer " ^ key); ("Content-Type", "application/json") ];
        body = Some (request_body ~country q);
      }
    ~cost_for:(cost_for ~cost_per_1k) ~parse:(parse ~text_chars) ~answer
    ~notice:(fun q _data ->
      Provider.ignored_constraints q ~domains:true ~dates:true ~geo:(country <> None)
        ~language:(Some true) ~safety:true ~drops_exclude_domains:false)
    q

let make ?(cost_per_1k = 8.00) ?(text_chars = 2000) ~key ~net () : Provider.t =
  (module struct
    let name = name
    let cost_per_1k = cost_per_1k
    let cost_for = cost_for ~cost_per_1k
    let search = search ~cost_per_1k ~text_chars ~key net

    (* Shared network grant; must not be closed by adapter instance. *)
    let aclose () = ()
  end : Provider.S)
