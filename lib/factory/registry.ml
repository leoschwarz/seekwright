(* One declarative row per provider name; [registry.mli] carries the shape and the
   reason a row replaces a builder-per-name.

   The two facts this module is arranged to make impossible are the two the
   two-row factory could only promise in prose: a name's destination being spelled
   twice (once by the adapter, once by the grant that allows it), and a credential
   reaching a name that was never supposed to hold one. Both are answered by
   construction here — {!grant_endpoint} is derived from {!uri}, and {!key_for}
   consults the row before it consults the environment. *)

module Config = Seekwright.Config
module Health = Seekwright.Health
module Provider = Seekwright.Provider
module Freeserp = Seekwright_providers.Freeserp
module Anysearch = Seekwright_providers.Anysearch

let ( let* ) = Result.bind

type context_cap =
  | Snippets
  | Text
  | Snippets_and_text

type credential =
  | No_credential
  | Header of { header : string; prefix : string }
  | App_id_and_key of { id_header : string; key_header : string }
  | Key_in_query of string

type prerequisite =
  | Api_key
  | Config_url
  | App_id
  | Index

type cost_model =
  | Flat
  | Extra_results of { first : int; per_extra_1k : float }

type endpoint_source =
  | Fixed_uri of Uri.t
  | Url_override of Uri.t
  | Url_required
  | Algolia_index

type args = {
  net : Provider.Net.t;
  now : unit -> float;
  key : string option;
  entry : Config.provider_config;
  cost_per_1k : float;
  snippet_chars : int;
  text_chars : int;
}

type build =
  | Adapter of (args -> Provider.t)
  | Deferred of string

type probe_source =
  | No_probe
  | Probe of (Config.t -> string option -> string option)

type row = {
  name : Config.name;
  build : build;
  endpoint : endpoint_source;
  credential : credential;
  requires : prerequisite list;
  default_cost : float option;
  cost_model : cost_model;
  timeout_floor : float;
  context : context_cap;
  probe : probe_source;
  settings : string list;
  ocaml_live_tested : bool;
}

(* {1 The row table} *)

(* Every field a row does not state is the field most of the inventory shares: a
   SERP-shaped result, a flat per-request price, no timeout floor beyond the
   policy, no key requirement beyond [Api_key]. Naming the exceptions on the row
   is what makes [scrappa]'s fifteen seconds and [linkup]'s twenty readable
   against the table rather than buried in a builder. *)
let make_row ~name ~endpoint ~build
    ?(credential = No_credential)
    ?(requires = [ Api_key ])
    ?(default_cost = Some 0.0)
    ?(cost_model = Flat)
    ?(timeout_floor = 0.0)
    ?(context = Snippets)
    ?(probe = No_probe)
    ?(settings = [])
    () =
  {
    name;
    build;
    endpoint;
    credential;
    requires;
    default_cost;
    cost_model;
    timeout_floor;
    context;
    probe;
    settings;
    (* No name on this port has a recorded OCaml live run: the runner (F4.3) is
       what retires a name from [untested], and it never inherits Python's live
       history. A row that says [true] before that run is a disclosure bug, so
       the field is not a labelled argument — it is written here, once, until the
       runner says otherwise. *)
    ocaml_live_tested = false;
  }

(* A probe at the adapter's own endpoint. The URL is that URI with the probe's
   query added, so a probe can never ask a host the adapter does not dial; the
   headers come from the row's credential, never from here. *)
let probe_at ?(query = []) (uri : Uri.t) =
  Probe
    (Health.probe_endpoint_const
       (Uri.to_string (if query = [] then uri else Uri.with_query uri query)))

(* [serpapi]'s probe: the endpoint the adapter dials, with the key in the query
   string because that is the shape this vendor documents. The key rides the URL
   and never a header, which is why {!Seekwright.Provider.redact_url} is the
   reduction every line naming one of these URLs must pass through. *)
let serpapi_probe (uri : Uri.t) = Probe (Health.serpapi_endpoint ~base:(Uri.to_string uri))

let key_header header = Header { header; prefix = "" }
let bearer = Header { header = "Authorization"; prefix = "Bearer " }

let rows =
  [
    (* The DSN host {i is} the deployment: [app_id] names it, [index] names what is
       searched, and both are config rather than a constant. [hitsPerPage] is
       malformed in the probe on purpose — a valid bodyless GET would run a search,
       and every search bills the monthly quota. *)
    make_row ~name:"algolia" ~endpoint:Algolia_index
      ~credential:
        (App_id_and_key
           { id_header = "x-algolia-application-id"; key_header = "x-algolia-api-key" })
      ~requires:[ Api_key; App_id; Index ] ~default_cost:(Some 0.50)
      ~probe:(Probe Health.algolia_endpoint)
      ~settings:[ "app_id"; "index"; "snippet_attr"; "title_attr"; "url_attr" ]
      ~build:(Deferred "F5.4") ();
    (* Keyless and priced at zero, but built only because this config named it:
       the explicit-only stance keeps it out of the keyless default and the free
       set, so this row is the only route to the adapter. Its endpoint is
       POST-only, so the bodyless probe proves the network path and the live test
       proves the contract. *)
    make_row ~name:"anysearch" ~endpoint:(Fixed_uri Anysearch.endpoint) ~requires:[]
      ~probe:(probe_at Anysearch.endpoint)
      ~build:
        (Adapter
           (fun a ->
             Anysearch.make ~cost_per_1k:a.cost_per_1k ~snippet_chars:a.snippet_chars
               ~net:a.net ()))
      ();
    (* Keyed, and the only name here with no free tier to be keyed {i despite}:
       billed per successful request. It is also the one name that fills [snippet]
       {i and} [text] — the query fold and the 128-codepoint limit are the
       adapter's, recorded in F5.5. *)
    make_row ~name:"deepseek"
      ~endpoint:(Fixed_uri (Uri.of_string "https://api.deepseek.com/v1/tools/search"))
      ~credential:bearer ~default_cost:(Some 0.75) ~context:Snippets_and_text
      ~probe:(probe_at (Uri.of_string "https://api.deepseek.com/v1/tools/search"))
      ~build:(Deferred "F5.5") ();
    (* Billed Exa, which still spends the free tier first ([TieredExaProvider]):
       without a key there is no billed fallback, and without a free tier the key
       is what spends. The floor is the MCP handshake's headroom; the [url]
       override and [free_cooldown_seconds] are the two settings its builder reads. *)
    make_row ~name:"exa"
      ~endpoint:(Url_override (Uri.of_string "https://mcp.exa.ai/mcp")) ~credential:bearer
      ~default_cost:(Some 7.00) ~timeout_floor:30.0 ~context:Text
      ~cost_model:(Extra_results { first = 10; per_extra_1k = 1.0 })
      ~settings:[ "free_cooldown_seconds"; "url" ] ~build:(Deferred "F5.1") ();
    (* Exa's MCP endpoint reached anonymously: the one row that fixes its price at
       zero rather than offering it as a default, and the one name whose key is
       never read even when the environment holds one. No ladder behind it, because
       it cannot bill. *)
    make_row ~name:"exa:free"
      ~endpoint:(Url_override (Uri.of_string "https://mcp.exa.ai/mcp"))
      ~requires:[] ~default_cost:None ~timeout_floor:30.0 ~context:Text
      ~settings:[ "url" ] ~build:(Deferred "F5.1") ();
    (* Keyless — no account, no key, no card — and priced at zero: nothing about a
       call here can bill. The probe names [index=web] because that index is not
       this endpoint's default, and a probe of the wrong index proves the wrong
       thing. *)
    make_row ~name:"freeserp" ~endpoint:(Fixed_uri Freeserp.endpoint) ~requires:[]
      ~probe:(probe_at ~query:[ ("index", [ "web" ]); ("q", [ "probe" ]) ] Freeserp.endpoint)
      ~build:
        (Adapter
           (fun a ->
             Freeserp.make ~cost_per_1k:a.cost_per_1k ~snippet_chars:a.snippet_chars
               ~now:a.now ~net:a.net ()))
      ();
    (* An answer-or-results API whose [depth] is a ~10x cost cliff, so the rung is
       operator-configured and never model-chosen; [20s] is the deep-rung budget. *)
    make_row ~name:"linkup"
      ~endpoint:(Fixed_uri (Uri.of_string "https://api.linkup.so/v1/search"))
      ~credential:bearer ~default_cost:(Some 6.00) ~timeout_floor:20.0
      ~probe:(probe_at (Uri.of_string "https://api.linkup.so/v1/search"))
      ~settings:[ "depth"; "output_type" ] ~build:(Deferred "F5.3") ();
    (* Keyed despite the free tier — it is an account quota, and the key names
       whose quota a search spends. REST, not the authenticated MCP, is the surface
       that carries the filter fields, and [mode] is the preset that decides price. *)
    make_row ~name:"parallel"
      ~endpoint:(Fixed_uri (Uri.of_string "https://api.parallel.ai/v1/search"))
      ~credential:(key_header "x-api-key") ~default_cost:(Some 1.00) ~context:Text
      ~probe:(probe_at (Uri.of_string "https://api.parallel.ai/v1/search"))
      ~settings:[ "mode" ] ~build:(Deferred "F5.1") ();
    (* Keyless anonymous hosted MCP, priced at zero like [exa:free], and proven by
       its MCP handshake rather than a bodyless GET — which this contract cannot
       drive until a [warmup] member exists. *)
    make_row ~name:"parallel:free"
      ~endpoint:(Url_override (Uri.of_string "https://search.parallel.ai/mcp"))
      ~requires:[] ~timeout_floor:30.0 ~context:Text ~settings:[ "url" ]
      ~build:(Deferred "F5.1") ();
    (* Keyed despite the 1,000 free calls/month for the metered-quota reason;
       [default_cost] is the free plan and the PAYG tier corrects it in config. *)
    make_row ~name:"querit"
      ~endpoint:(Fixed_uri (Uri.of_string "https://api.querit.ai/v1/search"))
      ~credential:bearer ~probe:(probe_at (Uri.of_string "https://api.querit.ai/v1/search"))
      ~build:(Deferred "F5.5") ();
    (* A scraping backend, not a cached SERP index: slower than [serper] on the same
       query, which is what the 15-second floor buys. *)
    make_row ~name:"scrappa"
      ~endpoint:(Fixed_uri (Uri.of_string "https://scrappa.co/api/search-light"))
      ~credential:(key_header "x-api-key") ~default_cost:(Some 0.30) ~timeout_floor:15.0
      ~probe:(probe_at (Uri.of_string "https://scrappa.co/api/search-light"))
      ~build:(Deferred "F5.2") ();
    (* Keyed despite the 100 free credits: a metered allowance is a billable quota.
       The figure is the entry Basic plan's rate; a cheaper plan corrects it. *)
    make_row ~name:"search1api"
      ~endpoint:(Fixed_uri (Uri.of_string "https://api.search1api.com/search"))
      ~credential:bearer ~default_cost:(Some 0.76)
      ~probe:(probe_at (Uri.of_string "https://api.search1api.com/search"))
      ~build:(Deferred "F5.5") ();
    (* A metasearch instance queries its upstream engines live, so it answers at
       scraper speed, not SERP-API speed: the 15-second floor. The instance is
       config, with no default and no key — and the key stays absent whatever the
       environment holds, because this name's grant is to the operator's own host. *)
    make_row ~name:"searxng" ~endpoint:Url_required ~requires:[ Config_url ] ~timeout_floor:15.0
      ~probe:(Probe Health.searxng_endpoint) ~settings:[ "url" ] ~build:(Deferred "F5.2")
      ();
    (* Keyed despite the 250 searches/month free tier. The documented request puts
       the key in the {i query string}, so this is the one row whose credential is
       not a header — and the one name for which a URL that reaches a log or an
       error must be reduced to its host first. *)
    make_row ~name:"serpapi"
      ~endpoint:(Fixed_uri (Uri.of_string "https://serpapi.com/search"))
      ~credential:(Key_in_query "api_key")
      ~probe:(serpapi_probe (Uri.of_string "https://serpapi.com/search"))
      ~build:(Deferred "F5.5") ();
    (* An API with its own SERP cache, not a scrape: the policy timeout is enough,
       and its header spelling is the vendor's own. *)
    make_row ~name:"serper"
      ~endpoint:(Fixed_uri (Uri.of_string "https://google.serper.dev/search"))
      ~credential:(key_header "X-API-KEY") ~default_cost:(Some 1.00)
      ~probe:(probe_at (Uri.of_string "https://google.serper.dev/search"))
      ~build:(Deferred "F5.2") ();
    (* An API, not a scrape: normal timeout. The figure is the free-then-metered
       tier's rate, and depth stays pinned at [basic] because [advanced] is the
       cost cliff an operator may choose and a model may not. *)
    make_row ~name:"tavily"
      ~endpoint:(Fixed_uri (Uri.of_string "https://api.tavily.com/search"))
      ~credential:bearer ~default_cost:(Some 8.00) ~context:Text
      ~probe:(probe_at (Uri.of_string "https://api.tavily.com/search"))
      ~build:(Deferred "F5.3") ();
    (* An API, not a scrape, and free but keyed: a metered allowance, so the key is
       what names whose allowance a search spends. *)
    make_row ~name:"tinyfish"
      ~endpoint:(Fixed_uri (Uri.of_string "https://api.search.tinyfish.ai"))
      ~credential:(key_header "X-API-Key")
      ~probe:(probe_at (Uri.of_string "https://api.search.tinyfish.ai"))
      ~build:(Deferred "F5.3") ()
  ]

let row name = List.find_opt (fun r -> r.name = name) rows
let names = List.map (fun r -> r.name) rows
let is_built r = match r.build with Adapter _ -> true | Deferred _ -> false

(* {1 Reading a row} *)

(* The one gate a destination passes before it becomes a grant entry. A config
   value is operator text, and an operator can write anything in it — including a
   URL whose userinfo carries a credential. So the failure names the {i key} and
   never echoes the value that failed. *)
let http_uri (uri : Uri.t) =
  match (Uri.scheme uri, Uri.host uri) with
  | (Some ("http" | "https"), Some host) when String.length host > 0 -> true
  | _ -> false

let absolute ~what raw =
  let uri = Uri.of_string raw in
  if http_uri uri then (
    (* A URL is an address, not a credential: [SEEKWRIGHT_*] is the only place a
       key comes from, and a userinfo in an operator's [url] would ride every
       request as Basic auth. The refusal names the key and never echoes the
       value, which is the same rule [Provider.redact_url] exists for. *)
    match Uri.userinfo uri with
    | Some _ -> Error (Printf.sprintf "[providers.%s] url must not carry credentials" what)
    | None -> Ok uri)
  else Error (Printf.sprintf "[providers.%s] url is not an absolute http(s) URL" what)

(* A present string, or [None] for the absent and the empty form: the oracle's
   [if not a.pc.url] guard treats both the same way. *)
let non_empty value = match value with Some v when String.length v > 0 -> Some v | _ -> None

let uri (row : row) (pc : Config.provider_config) =
  match row.endpoint with
  | Fixed_uri uri -> Ok uri
  | Url_override default -> (
      match pc.Config.url with
      | None -> Ok default
      | Some raw -> absolute ~what:row.name raw)
  | Url_required -> (
      match non_empty pc.Config.url with
      | Some raw -> absolute ~what:row.name raw
      | None -> Error (Printf.sprintf "[providers.%s] url is not set" row.name))
  | Algolia_index -> (
      (* [app_id] and [index] are validated as a pair at config load; the guard is
         what narrows them to present strings here, and an index name is escaped
         because it is a path segment, not a query value. *)
      match (non_empty pc.Config.app_id, non_empty pc.Config.index) with
      | Some app_id, Some index ->
          Ok
            (Uri.make ~scheme:"https" ~host:(app_id ^ "-dsn.algolia.net")
               ~path:(Printf.sprintf "/1/indexes/%s/query" (Provider.escape_path_segment index))
               ())
      | _ ->
          Error
            (Printf.sprintf "[providers.%s] app_id and index are not set" row.name))

(* The grant entry, through the seam's one URI-to-endpoint derivation: scheme
   pinned, host, and an explicit port when the URI carries one, so an override
   that says [:8443] allows that port and no other. *)
let grant_endpoint (row : row) (pc : Config.provider_config) =
  let* uri = uri row pc in
  if http_uri uri then Ok (Provider.policy_of_uri uri)
  else Error (Printf.sprintf "%s: its endpoint is not an absolute http(s) URL" row.name)

let timeout_seconds row ~policy_seconds = max policy_seconds row.timeout_floor

let price (row : row) (pc : Config.provider_config) =
  match row.default_cost with
  | None -> 0.0
  | Some default -> Option.value ~default pc.Config.cost_per_1k

let cost_of row ~cost_per_1k n =
  match row.cost_model with
  | Flat -> cost_per_1k /. 1000.
  | Extra_results { first; per_extra_1k } ->
      let extra = float_of_int (max 0 (n - first)) in
      (cost_per_1k +. (extra *. per_extra_1k)) /. 1000.

(* The credential decision, in one place: a keyless row answers [None] whatever the
   environment holds, so [exa:free] stays anonymous while [exa] spends the same
   variable, and a [searxng] grant cannot acquire a header by accident. *)
let key_for row config =
  if List.mem Api_key row.requires then Config.api_key config row.name else None

let missing_prerequisite (row : row) (config : Config.t) (pc : Config.provider_config) =
  let missing =
    List.filter_map
      (fun need ->
        match need with
        | Api_key when Config.api_key config row.name = None ->
            Some (Printf.sprintf "no %s in the environment" (Config.api_key_env_var row.name))
        | Config_url when non_empty pc.Config.url = None ->
            Some (Printf.sprintf "[providers.%s] url is not set" row.name)
        | App_id when non_empty pc.Config.app_id = None ->
            Some (Printf.sprintf "[providers.%s] app_id is not set" row.name)
        | Index when non_empty pc.Config.index = None ->
            Some (Printf.sprintf "[providers.%s] index is not set" row.name)
        | _ -> None)
      row.requires
  in
  match missing with [] -> None | reasons -> Some (String.concat "; " reasons)

(* A probe authenticates the way its adapter does, or the probe proves a
   credential path nothing dispatches uses. [Key_in_query] contributes no header:
   that key is already in the URL, which is why {!Seekwright.Provider.redact_url}
   is what any line naming that URL must go through. *)
let probe_headers credential : Config.t -> string option -> (string * string) list =
  match credential with
  | No_credential | Key_in_query _ -> (fun _config _key -> [])
  | Header { header; prefix } -> Health.probe_headers_const ~prefix header
  | App_id_and_key _ -> Health.algolia_headers

let probe_spec row =
  match row.probe with
  | No_probe -> Health.no_probe
  | Probe endpoint -> { Health.endpoint; headers = probe_headers row.credential }
