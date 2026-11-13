(* F4.1: the provider registry. The factory used to hold one builder function
   per name, and every other fact about a name — its price, its timeout floor,
   its endpoint, its probe, where its key rides — sat somewhere else, so the
   only way to check those facts was to read a builder. Now they are one row per
   name, and this suite asks all seventeen rows the same questions.

   Nothing here opens a provider socket: the rows are read as data, and the
   construction cases build grants without dialling them, as [test_routing_sets]
   and [test_grant_timeouts] do. The only environment variables this suite
   writes are sentinel API keys, which is what lets a keyless row prove it never
   reads one. *)

module Caps = Mcp_caps
module Config = Seekwright.Config
module Factory = Seekwright_factory.Factory
module Health = Seekwright.Health
module Provider = Seekwright.Provider
module Registry = Seekwright_factory.Registry
module A = Alcotest
open Test_support

let some = function Some value -> value | None -> A.fail "expected a value, got None"

let ok = function Ok value -> value | Error message -> A.fail message

(* The sentinel stands in the environment for the credential cases: a row with
   no [Api_key] prerequisite has to answer [None] anyway, and the name that
   cannot bill has to stay anonymous with a key in hand. *)
let sentinel = "SEEKWRIGHT-SENTINEL-KEY"

let set_keys () =
  List.iter (fun name -> Unix.putenv (Config.api_key_env_var name) sentinel)
    Config.providers_requiring_key

(* [Unix] has no unsetenv, and [Config.api_key] reads an empty value as absent,
   so restoring means writing the empty form. *)
let clear_keys () =
  List.iter (fun name -> Unix.putenv (Config.api_key_env_var name) "")
    Config.providers_requiring_key

let entry ?(enabled = true) ?cost ?url ?app_id ?index () =
  {
    Config.default_provider_config with
    Config.enabled = enabled;
    cost_per_1k = cost;
    url;
    app_id;
    index;
  }

let config ?policy ?default ?permitted table =
  match
    Config.resolve ~providers:table ?policy ?default_provider:default
      ?permitted_providers:permitted ()
  with
  | Error message -> A.failf "the fixture config was refused: %s" message
  | Ok value -> value

(* Every name enabled, with the prerequisites config itself insists on filled
   in — [searxng]'s instance, [algolia]'s registration — since a config that
   omits them is refused before construction is ever asked. *)
let every_name_registered =
  List.map
    (fun name ->
      if name = "searxng" then (name, entry ~url:"http://searx.example:8080/" ())
      else if name = "algolia" then (name, entry ~app_id:"ABCD1234" ~index:"docs" ())
      else (name, entry ()))
    Config.known_providers

let fixture_config = config every_name_registered

let row_of name =
  match Registry.row name with
  | Some row -> row
  | None -> A.failf "no row for %s" name

let entry_of name =
  match List.assoc_opt name fixture_config.Config.providers with
  | Some pc -> pc
  | None -> A.failf "the fixture config does not carry %s" name

let show_endpoint (endpoint : Caps.Policy.endpoint) =
  Printf.sprintf "%s://%s%s"
    (match endpoint.Caps.Policy.scheme with `Http -> "http" | `Https -> "https")
    endpoint.Caps.Policy.host
    (match endpoint.Caps.Policy.port with Some port -> ":" ^ string_of_int port | None -> "")

(* {1 The table is the inventory} *)

let the_rows_are_the_frozen_seventeen () =
  A.(check (list string) "row names == known_providers"
       (List.sort String.compare Config.known_providers) Registry.names);
  (* stored sorted, so a diff of the table reads as a change of the inventory
     rather than a row moved *)
  A.(check (list string) "rows are sorted" Registry.names
       (List.sort String.compare Registry.names));
  List.iter
    (fun name ->
      A.(check string "the row carries the name it answers" name (row_of name).name))
    Config.known_providers;
  (* a name outside the frozen vocabulary has no row, and [Config] cannot make
     one either *)
  A.(check bool "no row for a name nobody ships" true (Registry.row "googgle" = None);
    check bool "known_providers refuses it too" true
      (not (List.mem "googgle" Config.known_providers)))

(* A row exists for every name whether or not this build can dispatch it: the
   row is the inventory, [build] is the promise, and a wave name says where the
   dispatch lands (plans/ocaml-finalisation.md, F5). *)
let every_name_has_a_row_built_or_deferred () =
  let built =
    List.filter_map (fun r -> if Registry.is_built r then Some r.Registry.name else None) Registry.rows
  in
  let deferred =
    List.filter_map
      (fun r ->
        match r.Registry.build with
        | Registry.Adapter _ -> None
        | Registry.Deferred wave ->
            if wave <> "" then Some r.Registry.name else A.failf "%s defers with no wave named" r.Registry.name)
      Registry.rows
  in
  let unbuilt =
    List.sort String.compare
      [ "algolia"; "deepseek"; "exa"; "exa:free"; "linkup"; "parallel"; "parallel:free"; "querit";
        "search1api"; "serpapi"; "tavily"; "tinyfish" ]
  in
  A.(check (list string) "the built rows"
         [ "anysearch"; "freeserp"; "scrappa"; "searxng"; "serper" ]
         (List.sort String.compare built);
    check (list string) "the deferred rows are the rest" unbuilt
       (List.sort String.compare deferred);
    check int "the two halves are the seventeen" 17 (List.length built + List.length deferred));
  (* live-tested is a property of this port: the runner (F4.3) retires a name in
     the change that records its successful run in
     [plans/seekwright-ocaml-port.md], and it never inherits Python's live
     history. F4.3's first acceptance check ran the two keyless built names. *)
  let live_tested =
    List.filter_map
      (fun r -> if r.Registry.ocaml_live_tested then Some r.Registry.name else None)
      Registry.rows
  in
  A.(check (list string) "only the recorded keyless runs are live-tested"
       [ "anysearch"; "freeserp" ] (List.sort String.compare live_tested))

(* {1 Price: one figure per name, and one name with none to spend} *)

(* [factory.py]'s [_BuildSpec] table: [default_cost] per name, [None] meaning
   fixed at zero. Written down here rather than read from the oracle, so a
   figure that moves in one tree fails a run in the other. *)
let oracle_cost =
  [ ("algolia", Some 0.50); ("anysearch", Some 0.0); ("deepseek", Some 0.75)
  ; ("exa", Some 7.00); ("exa:free", None); ("freeserp", Some 0.0)
  ; ("linkup", Some 6.00); ("parallel", Some 1.00); ("parallel:free", Some 0.0)
  ; ("querit", Some 0.0); ("scrappa", Some 0.30); ("search1api", Some 0.76)
  ; ("searxng", Some 0.0); ("serpapi", Some 0.0); ("serper", Some 1.00)
  ; ("tavily", Some 8.00); ("tinyfish", Some 0.0) ]

let the_rows_price_their_names () =
  A.(check int "one figure per name" 17 (List.length oracle_cost));
  List.iter
    (fun (name, want) ->
      let row = row_of name in
      A.(check (option (float 1e-9)) (name ^ " default cost") want row.Registry.default_cost);
      (* with no config correction, the row's figure is what the adapter is
         built at *)
      A.(check (float 1e-9) (name ^ " is built at its row's figure")
           (Option.value ~default:0.0 want) (Registry.price row (entry ())));
      (* and a [[providers]] [cost_per_1k] corrects it — except for the name
         that cannot bill, where the correction is what would bill it *)
      let overridden = entry ~cost:4.25 () in
      match want with
      | None -> A.(check (float 1e-9) (name ^ " stays at zero") 0.0 (Registry.price row overridden))
      | Some figure ->
          A.(check (float 1e-9) (name ^ " takes the config figure") 4.25 (Registry.price row overridden);
            check bool (name ^ " is not the fixed-zero name") true (figure <> 4.25)))
    oracle_cost;
  (* the flavour shares its backend's endpoint and none of its price: one key
     variable serves both halves, and the free half never reads it *)
  A.(check (float 1e-9) "the free half is fixed at zero" 0.0
       (Registry.price (row_of "exa:free") (entry ~cost:7.00 ()));
    check string "one key variable serves both halves"
      (Config.api_key_env_var "exa") (Config.api_key_env_var "exa:free");
    check string "and it names the backend" "SEEKWRIGHT_EXA_API_KEY"
      (Config.api_key_env_var "exa:free"))

(* Exa publishes a subscription plus a per-result rung above it; Serper publishes a
   credit count that doubles past ten results; every other name charges the same per
   query. *)
let the_cost_models_are_the_published_shapes () =
  List.iter
    (fun r ->
      match r.Registry.cost_model with
      | Registry.Flat ->
          A.(check (float 1e-9) (r.Registry.name ^ " is flat over its price") 0.004
               (Registry.cost_of r ~cost_per_1k:4.0 1);
            check (float 1e-9) (r.Registry.name ^ " is flat at any result count") 0.004
               (Registry.cost_of r ~cost_per_1k:4.0 50))
      | Registry.Extra_results { first; per_extra_1k } ->
          A.(check int (r.Registry.name ^ " covers the subscription") 10 first;
            check (float 1e-9) (r.Registry.name ^ " per extra result") 1.0 per_extra_1k;
            check (float 1e-9) (r.Registry.name ^ " charges nothing under the threshold") 0.007
              (Registry.cost_of r ~cost_per_1k:7.0 10);
            check (float 1e-9) (r.Registry.name ^ " adds the rung above it") 10.007
              (Registry.cost_of r ~cost_per_1k:7.0 10_010))
      | Registry.Credit_multiplier { over; multiplier } ->
          A.(check int (r.Registry.name ^ " doubles past ten results") 10 over;
            check int (r.Registry.name ^ " spends two credits there") 2 multiplier;
            (* The threshold belongs to the ask, not to the answer: ten results is
               one credit, eleven is two, and the figure a caller plans a budget by
               has to say so. *)
            check (float 1e-9) (r.Registry.name ^ " is one credit at the threshold") 0.004
              (Registry.cost_of r ~cost_per_1k:4.0 10);
            check (float 1e-9) (r.Registry.name ^ " doubles past it") 0.008
              (Registry.cost_of r ~cost_per_1k:4.0 11)))
    Registry.rows;
  let rung =
    List.filter_map
      (fun r -> match r.Registry.cost_model with Registry.Flat -> None | _ -> Some r.Registry.name)
      Registry.rows
  in
  A.(check (list string) "two names bill differently per query, and they are the billed halves"
         [ "exa"; "serper" ] (List.sort String.compare rung))

(* {1 Timeout floor: config lengthens, never shortens} *)

let floors =
  [ ("exa", 30.0); ("exa:free", 30.0); ("linkup", 20.0); ("parallel:free", 30.0)
  ; ("scrappa", 15.0); ("searxng", 15.0) ]

let the_floors_are_what_the_backends_need () =
  (* the oracle's [timeout_floor] column: a scrape, a metasearch fan-out and an
     MCP handshake need more than a cached SERP API *)
  List.iter
    (fun (name, want) -> A.(check (float 1e-9) ("floor " ^ name) want (row_of name).timeout_floor))
    floors;
  List.iter
    (fun r ->
      if not (List.mem_assoc r.Registry.name floors) then
        A.(check (float 1e-9) (r.Registry.name ^ " has no floor") 0.0 r.Registry.timeout_floor))
    Registry.rows

let a_floor_is_a_floor_not_a_ceiling () =
  List.iter
    (fun r ->
      (* a policy timeout shorter than the floor gives way to the floor... *)
      A.(check (float 1e-9) (r.Registry.name ^ " keeps its floor")
           (max r.Registry.timeout_floor 1.0)
           (Registry.timeout_seconds r ~policy_seconds:1.0);
         (* ...and a longer one is what the name gets, floor or no floor: the
            floor is what a backend needs, never what it gets capped at *)
         check (float 1e-9) (r.Registry.name ^ " takes a longer config timeout") 45.0
           (Registry.timeout_seconds r ~policy_seconds:45.0)))
    Registry.rows

(* {1 Endpoint: one URI per name, derived where config decides it} *)

(* The single-destination pin: the grant entry is the row's URI read through the
   seam's one derivation, so there is no third spelling of a host to keep in
   step with the adapter's. *)
let the_grant_is_the_endpoint_read_once () =
  List.iter
    (fun name ->
      let row = row_of name in
      let pc = entry_of name in
      match (Registry.uri row pc, Registry.grant_endpoint row pc) with
      | Ok uri, Ok endpoint ->
          A.(check string (name ^ ": the grant is policy_of_uri of the row's URI")
               (show_endpoint (Provider.policy_of_uri uri)) (show_endpoint endpoint);
            (* the host the adapter would dial is the host the grant allows *)
            check string (name ^ ": the grant host is the URI host")
              (Uri.host uri |> Option.value ~default:"?") endpoint.Caps.Policy.host;
            check string (name ^ ": and the scheme is pinned, not inferred")
              (if Uri.scheme uri = Some "https" then "https" else "http")
              (match endpoint.Caps.Policy.scheme with `Http -> "http" | `Https -> "https"))
      | Error first, Error second -> A.(check string "both readings refuse alike" first second)
      | Ok uri, Error message ->
          A.failf "%s: the endpoint built (%s) but the grant refused: %s" name
            (Uri.to_string uri) message
      | Error message, Ok endpoint ->
          A.failf "%s: the URI refused (%s) and the grant did not: %s" name message
            (show_endpoint endpoint))
    Config.known_providers

let a_fixed_endpoint_is_the_adapters_own () =
  (* for a built name the row's URI {i is} the adapter module's constant, which
     is why the adapter and its grant cannot drift apart *)
  let module Freeserp = Seekwright_providers.Freeserp in
  let module Anysearch = Seekwright_providers.Anysearch in
  List.iter
    (fun (name, endpoint) ->
      let row = row_of name in
      A.(check string (name ^ ": one URI") (Uri.to_string endpoint)
           (Uri.to_string (ok (Registry.uri row (entry ())))));
      match row.Registry.endpoint with
      | Registry.Fixed_uri uri ->
          A.(check string (name ^ ": the row names that URI") (Uri.to_string uri)
               (Uri.to_string endpoint))
      | other ->
          A.failf "%s: the endpoint is not a fixed URI (%s)" name
            (match other with
            | Registry.Fixed_uri uri -> Uri.to_string uri
            | Registry.Url_override uri -> Uri.to_string uri
            | Registry.Url_required -> "from config"
            | Registry.Algolia_index -> "derived from app_id"))
    [ ("freeserp", Freeserp.endpoint); ("anysearch", Anysearch.endpoint) ]

let a_config_endpoint_comes_from_one_value () =
  (* [searxng] has no default: its instance is the whole address. *)
  let searxng = row_of "searxng" in
  A.(check bool "searxng requires a url" true (searxng.endpoint = Registry.Url_required);
    check string "and refuses without one" "[providers.searxng] url is not set"
      (match Registry.uri searxng (entry ()) with
      | Error message -> message
      | Ok uri -> Uri.to_string uri));
  let instance = entry ~url:"http://searx.example:8080/" () in
  let uri = ok (Registry.uri searxng instance) in
  A.(check (option string) "instance scheme" (Some "http") (Uri.scheme uri);
    check (option string) "instance host" (Some "searx.example") (Uri.host uri);
    check (option int) "instance port" (Some 8080) (Uri.port uri));
  (* the grant pins the port the operator pinned, so [:8080] is not a hint *)
  let endpoint = ok (Registry.grant_endpoint searxng instance) in
  A.(check (option int) "the grant pins the port" (Some 8080) endpoint.Caps.Policy.port;
    check string "the grant host is the instance" "searx.example" endpoint.Caps.Policy.host);
  (* [exa], [exa:free] and [parallel:free] take an override over a default that
     stays available when the key is absent *)
  List.iter
    (fun (name, default_host) ->
      let row = row_of name in
      A.(check string (name ^ " default host") default_host
           (Uri.host (ok (Registry.uri row (entry ()))) |> Option.value ~default:"?"));
      let overridden = entry ~url:"https://mirror.example.com:8443/" () in
      let uri = ok (Registry.uri row overridden) in
      A.(check (option int) (name ^ " override port") (Some 8443) (Uri.port uri);
        check (option string) (name ^ " override host") (Some "mirror.example.com") (Uri.host uri));
      let endpoint = ok (Registry.grant_endpoint row overridden) in
      A.(check string (name ^ " grant follows the override") "mirror.example.com"
           endpoint.Caps.Policy.host;
        check (option int) (name ^ " grant pins the override port") (Some 8443)
          endpoint.Caps.Policy.port);
      (* a config value is operator text, and operator text may carry a
         credential in its userinfo: the refusal names the key and never echoes
         the value that failed *)
      match Registry.uri row (entry ~url:"http://user:hunter2@broken" ()) with
      | Ok uri -> A.failf "%s accepted a malformed url: %s" name (Uri.to_string uri)
      | Error message ->
          includes (name ^ " names the key") "url" message;
          excludes (name ^ " does not echo the value") "hunter2" message)
    [ ("exa", "mcp.exa.ai"); ("exa:free", "mcp.exa.ai"); ("parallel:free", "search.parallel.ai") ];
  (* a name with no [url] of its own ignores one it is given — and says so on
     the row, which is what makes the inertness visible instead of a key that
     parses, validates and does nothing (F1.4's failure mode). What the operator
     reads is the row's [settings], and the endpoint stays the module constant. *)
  List.iter
    (fun name ->
      let row = row_of name in
      A.(check bool (name ^ " does not list url as its own") true
           (not (List.mem "url" row.Registry.settings));
         check bool (name ^ " ignores a url it was not given") true
           (match Registry.uri row (entry ~url:"http://not-this-one.example/" ()) with
           | Ok uri -> Uri.host uri = Uri.host (ok (Registry.uri row (entry ())))
           | Error message -> A.failf "%s: %s" name message))
      )
    [ "freeserp"; "serper"; "tavily" ];
  (* an empty value is the absent form, and a value that names no absolute
     http(s) URL is a construction failure the operator reads — never a grant
     that quietly allows nothing *)
  (match Registry.uri (row_of "searxng") (entry ~url:"" ()) with
  | Ok uri -> A.failf "an empty url built %s" (Uri.to_string uri)
  | Error message -> includes "an empty url is the absent form" "url is not set" message);
  List.iter
    (fun bad ->
      match Registry.uri (row_of "searxng") (entry ~url:bad ()) with
      | Ok uri -> A.failf "%S built an endpoint: %s" bad (Uri.to_string uri)
      | Error message -> includes ("refuses " ^ bad) "absolute http(s) URL" message)
    [ "not a url"; "ftp://searx.example/"; "http://"; "://searx.example" ]

let algolias_endpoint_is_the_deployment () =
  let row = row_of "algolia" in
  (* no registration: no endpoint, and the refusal names both keys, because an
     Algolia host {i is} the application *)
  (match Registry.uri row (entry ()) with
  | Ok uri -> A.failf "algolia built %s with no registration" (Uri.to_string uri)
  | Error message ->
      includes "names app_id" "app_id" message;
      includes "names index" "index" message);
  let registered = entry ~app_id:"ABCD1234" ~index:"docs" () in
  let uri = ok (Registry.uri row registered) in
  A.(check (option string) "the app id is the host, lower-cased as the vendor spells it"
       (Some "abcd1234-dsn.algolia.net") (Uri.host uri);
    check string "the index is the path" "/1/indexes/docs/query" (Uri.path uri));
  (* an index name is a path segment, so it is escaped the way the oracle
     escapes it: every byte outside the unreserved set, [+] and [&] included —
     narrower than [Uri.escape], which keeps the sub-delims literal, and a
     segment that keeps them is a segment that changes meaning. [Uri] then
     normalises a path back to those two literals, so the two assertions pin
     different halves: the seam's escaping is what a request writer putting
     bytes on the wire must use (F5.4's adapter), and the URI is what this row
     hands the grant. *)
  let awkward = entry ~app_id:"ABCD1234" ~index:"my index/e+x&y" () in
  A.(check string "the seam escapes every byte the unreserved set excludes"
       (Provider.escape_path_segment "my index/e+x&y") "my%20index%2Fe%2Bx%26y";
    check string "the index reaches the URI as one segment"
      "/1/indexes/my%20index%2Fe+x&y/query" (Uri.path (ok (Registry.uri row awkward))));
  (* one half of the pair is not a registration *)
  List.iter
    (fun pc ->
      match Registry.uri row pc with
      | Ok uri -> A.failf "a half registration built %s" (Uri.to_string uri)
      | Error _ -> ())
    [ entry ~app_id:"ABCD1234" (); entry ~index:"docs" () ]

(* {1 Probe: the same destination, the same credential shape} *)

let the_probe_asks_the_endpoint_the_grant_allows () =
  let mcp_backed = [ "exa"; "exa:free"; "parallel:free" ] in
  List.iter
    (fun name ->
      let row = row_of name in
      let pc = entry_of name in
      let spec = Registry.probe_spec row in
      let asked =
        set_keys ();
        let answer = spec.Health.endpoint fixture_config (Registry.key_for row fixture_config) in
        clear_keys ();
        answer
      in
      match (asked, Registry.grant_endpoint row pc) with
      | None, _ ->
          (* the MCP-backed names the oracle proves with a session handshake,
             which this contract has no [warmup] member for yet: no probe, and
             [--check] reports them as unsupported rather than unreachable *)
          A.(check bool (name ^ " is probe-free because it is MCP-backed") true
               (List.mem name mcp_backed))
      | Some url, Ok endpoint ->
          let asked = Uri.of_string url in
          A.(check string (name ^ ": the probe dials the granted host")
               endpoint.Caps.Policy.host (Uri.host asked |> Option.value ~default:"?");
             check (option int) (name ^ ": at the granted port") endpoint.Caps.Policy.port
               (Uri.port asked));
          (* The probe asks the endpoint's own path, except where the
             endpoint is a base the operator wrote: a [searxng] instance
             URL is the root of a deployment, and the probe adds the
             search path to it. *)
          if name <> "searxng" then
            A.(check string (name ^ ": and asks the endpoint's own path")
                 (Uri.path (ok (Registry.uri row pc))) (Uri.path asked))
          else
            A.(check string "searxng: the probe adds its path to the instance"
                 "/search" (Uri.path asked))
      | Some url, Error message -> A.failf "%s probes %s with no grant: %s" name url message)
    Config.known_providers;
  (* [searxng]'s and [algolia]'s probes follow their config-derived endpoints,
     so [--check] proves the instance and the index the operator actually named *)
  let searxng_asked =
    some ((Registry.probe_spec (row_of "searxng")).Health.endpoint fixture_config None)
  in
  A.(check string "searxng probe host" "searx.example"
       (Uri.host (Uri.of_string searxng_asked) |> Option.value ~default:"?");
    check (option int) "searxng probe port" (Some 8080) (Uri.port (Uri.of_string searxng_asked)));
  let algolia_asked =
    some ((Registry.probe_spec (row_of "algolia")).Health.endpoint fixture_config None)
  in
  A.(check string "algolia probe host" "abcd1234-dsn.algolia.net"
       (Uri.host (Uri.of_string algolia_asked) |> Option.value ~default:"?"));
  (* and a deployment that names nothing for those two gets no probe at all
     rather than one at a guessed host *)
  A.(check bool "no searxng probe without an instance" true
       ((Registry.probe_spec (row_of "searxng")).Health.endpoint Config.default None = None);
    check bool "no algolia probe without a registration" true
      ((Registry.probe_spec (row_of "algolia")).Health.endpoint Config.default None = None))

(* A probe that authenticates in a shape no search uses proves a path nothing
   dispatches, so the headers come from the row's credential and nowhere else. *)
let the_probe_authenticates_the_way_the_adapter_does () =
  set_keys ();
  List.iter
    (fun name ->
      let row = row_of name in
      let key = Registry.key_for row fixture_config in
      let headers = (Registry.probe_spec row).Health.headers fixture_config key in
      (* the MCP-backed names have no probe at all, so there is no header to
         compare against: the probe-free claim is pinned in the case above. *)
      (match row.Registry.probe with
      | Registry.No_probe ->
          A.(check (list (pair string string)) (name ^ " has no probe to authenticate") []
               headers)
      | Registry.Probe _ ->
      match row.Registry.credential with
      | Registry.No_credential ->
          A.(check (list (pair string string)) (name ^ " sends no header") [] headers;
            check bool (name ^ " is handed no key either" ) true (key = None))
      | Registry.Header { header; prefix } ->
          A.(check (list (pair string string)) (name ^ " sends its own header")
               [ (header, prefix ^ sentinel) ] headers)
      | Registry.App_id_and_key { id_header; key_header } ->
          A.(check (list string) (name ^ " sends its pair of headers")
               [ id_header; key_header ] (List.map fst headers))
      | Registry.Key_in_query param ->
          (* no header for this shape: the key is already in the URL the probe
             asks, which is what makes the reduction in the next section a
             requirement rather than hygiene *)
          A.(check (list (pair string string)) (name ^ " sends no header") [] headers);
          let asked =
            Option.value ~default:"" ((Registry.probe_spec row).Health.endpoint fixture_config key)
          in
          includes (name ^ " puts the key in the query") (param ^ "=") asked))
    Config.known_providers;
  clear_keys ()

(* {1 Credentials: what a row permits, and where it puts the key} *)

let the_header_spellings_are_the_vendors () =
  List.iter
    (fun (name, want) ->
      match (row_of name).credential with
      | Registry.Header { header; prefix = "" } -> A.(check string ("header " ^ name) want header)
      | Registry.Header { header; prefix } ->
          A.(check string ("bearer header " ^ name) want header;
            check string ("bearer prefix " ^ name) "Bearer " prefix)
      | other ->
          A.failf "%s carries its key as something else (%s)" name
            (match other with
            | Registry.Header { header; prefix } ->
                "the header " ^ header ^ (if prefix = "" then "" else " with a prefix")
            | Registry.No_credential -> "no credential"
            | Registry.App_id_and_key _ -> "a pair of headers"
            | Registry.Key_in_query param -> "the query parameter " ^ param))
    [ ("scrappa", "x-api-key"); ("parallel", "x-api-key"); ("serper", "X-API-KEY")
    ; ("tinyfish", "X-API-Key"); ("deepseek", "Authorization"); ("exa", "Authorization")
    ; ("linkup", "Authorization"); ("querit", "Authorization"); ("search1api", "Authorization")
    ; ("tavily", "Authorization") ];
  (* the registration pair: a public identifier and a secret, in that order *)
  match (row_of "algolia").credential with
  | Registry.App_id_and_key { id_header; key_header } ->
      A.(check string "algolia's identifier header" "x-algolia-application-id" id_header;
        check string "algolia's secret header" "x-algolia-api-key" key_header)
  | _ -> A.fail "algolia's credential is not the registration pair"

(* The one name whose documented request carries the key in the query string,
   and the reduction that keeps it out of every line naming such a URL. *)
let serpapi_keys_ride_the_query_and_never_a_log () =
  let row = row_of "serpapi" in
  A.(check (list string) "the query parameter" [ "api_key" ]
       (match row.Registry.credential with Registry.Key_in_query param -> [ param ] | _ -> []));
  let keyed =
    "https://serpapi.com/search?engine=google&q=seekwright&api_key=" ^ sentinel
  in
  A.(check string "reduced to a host" "serpapi.com" (Provider.redact_url keyed);
    check bool "the key did not survive the reduction" false
      (contains ~haystack:(Provider.redact_url keyed) ~needle:sentinel);
    check bool "nor the query" false
      (contains ~haystack:(Provider.redact_url keyed) ~needle:"q=seekwright");
    check string "a URL with no host reduces to the oracle's placeholder" "?"
      (Provider.redact_url "not a url"))

(* A key reaches a name only through its row: the environment offers the
   backend a key, and the row decides whether that name may hold one. *)
let only_the_names_that_may_bill_are_handed_a_key () =
  set_keys ();
  List.iter
    (fun name ->
      let row = row_of name in
      let needs_key = List.mem Registry.Api_key row.Registry.requires in
      A.(check bool (name ^ " declares its key requirement once") needs_key
           (List.mem name Config.providers_requiring_key);
         (* and a name that needs a key has somewhere on the wire to put it *)
         check bool (name ^ " has somewhere to put it") needs_key
           (match row.Registry.credential with
           | Registry.No_credential -> false
           | Registry.Header _ | Registry.App_id_and_key _ | Registry.Key_in_query _ -> true));
      match Registry.key_for row fixture_config with
      | Some key ->
          A.(check string (name ^ " reads its own variable") sentinel key;
            check bool "only a name that needs a key gets one" true needs_key)
      | None -> A.(check bool (name ^ " needs no key") true (not needs_key)))
    Config.known_providers;
  (* [exa] and [exa:free] share one variable, and only one of them reads it:
     the anonymous half cannot be handed the key by a shell that happens to
     hold one *)
  A.(check bool "exa gets the key" true (Registry.key_for (row_of "exa") fixture_config <> None);
    check bool "exa:free does not" true
      (Registry.key_for (row_of "exa:free") fixture_config = None);
    check bool "parallel:free does not" true
      (Registry.key_for (row_of "parallel:free") fixture_config = None);
    check bool "searxng does not, whatever the environment holds" true
      (Registry.key_for (row_of "searxng") fixture_config = None));
  clear_keys ();
  (* with the variables empty again, the same rows answer [None]: the key is
     read at construction, from the environment only *)
  List.iter
    (fun name ->
      A.(check bool (name ^ " reads nothing once the environment is empty") true
           (Registry.key_for (row_of name) fixture_config = None)))
    Config.known_providers

(* Why a deployment cannot build a name, in one sentence naming every missing
   prerequisite: the difference between an incomplete config and a build with
   no adapter behind the name. *)
let a_missing_prerequisite_is_named () =
  clear_keys ();
  List.iter
    (fun name ->
      let row = row_of name in
      match Registry.missing_prerequisite row fixture_config (entry_of name) with
      | None ->
          (* nothing missing means the row asks for no key, since the fixture
             fills in every config-side prerequisite *)
          A.(check bool (name ^ " asks for no key") true
               (not (List.mem Registry.Api_key row.Registry.requires)))
      | Some sentence ->
          A.(check bool (name ^ " gives a reason") true (sentence <> "");
            (* every sentence names the missing thing: a variable, or a key of
               this name's own [[providers]] table *)
            check bool (name ^ " names what is missing") true
              (contains ~haystack:sentence ~needle:"environment"
              || contains ~haystack:sentence ~needle:"not set")))
    Config.known_providers;
  (* every missing prerequisite of one name lands in the one sentence: an
     operator fixing a config should not need a restart per key *)
  set_keys ();
  let algolia = row_of "algolia" in
  let half_registered = entry ~app_id:"only-the-id" () in
  (match Registry.missing_prerequisite algolia fixture_config half_registered with
  | Some sentence ->
      includes "the remaining half is named" "index" sentence;
      excludes "and the present half is not complained about" "app_id is not set" sentence
  | None -> A.fail "a half registration looked complete");
  clear_keys ()

(* {1 Settings: every knob a name reads is on its row} *)

(* [Config.provider_config]'s fields, spelled out: the union of the rows'
   [settings] plus the two the factory reads for every name has to be that set,
   or a key exists that parses, validates, and belongs to no row — the failure
   mode plans/ocaml-finalisation.md F1.4 refuses. *)
let every_provider_key_belongs_to_a_row () =
  let fields =
    [ "enabled"; "cost_per_1k"; "depth"; "output_type"; "mode"; "url"; "free_cooldown_seconds";
      "app_id"; "index"; "title_attr"; "url_attr"; "snippet_attr" ]
  in
  let from_rows =
    Registry.rows
    |> List.map (fun r -> r.Registry.settings)
    |> List.concat
    |> List.append [ "enabled"; "cost_per_1k" ]
    |> List.sort_uniq String.compare
  in
  A.(check (list string) "the rows account for every provider key"
       (List.sort String.compare fields) from_rows);
  List.iter
    (fun r ->
      A.(check (list string) (r.Registry.name ^ " lists its settings sorted")
           (List.sort String.compare r.Registry.settings) r.Registry.settings;
        (* [enabled] and [cost_per_1k] are the factory's, so a row listing them
           would be a row claiming a knob it does not read *)
        check bool (r.Registry.name ^ " claims no factory key") true
          (not (List.mem "enabled" r.Registry.settings || List.mem "cost_per_1k" r.Registry.settings))))
    Registry.rows;
  (* [url] is the four names that can take an override or an instance, and no
     other row mentions it *)
  let url_rows =
    List.filter_map (fun r -> if List.mem "url" r.Registry.settings then Some r.Registry.name else None) Registry.rows
  in
  A.(check (list string) "url is the override and instance names'"
       [ "exa"; "exa:free"; "parallel:free"; "searxng" ] (List.sort String.compare url_rows))

(* {1 Construction: the decision a row drives} *)

let build_all () =
  set_keys ();
  let providers =
    Eio_main.run @@ fun env ->
    Eio.Switch.run (fun sw ->
      Factory.build_providers ~sw ~net:env#net ~mono_clock:env#mono_clock
        ~now:(fun () -> 1768478400.) fixture_config)
  in
  clear_keys ();
  providers

let construction_answers_from_the_rows () =
  let providers = build_all () in
  A.(check (list string) "this build dispatches five of the seventeen"
       [ "anysearch"; "freeserp"; "scrappa"; "searxng"; "serper" ]
       (List.sort String.compare (List.map fst providers.Factory.built));
    (* a deferred row is an inventoried name with no dispatch, reported as such
       rather than dropped, and sorted because two sentences print this set *)
    check (list string) "the other twelve are unsupported"
      (List.sort String.compare
         [ "algolia"; "deepseek"; "exa"; "exa:free"; "linkup"; "parallel"; "parallel:free"; "querit"
         ; "search1api"; "serpapi"; "tavily"; "tinyfish" ])
      providers.Factory.unsupported;
    check (list (pair string string)) "and no grant was refused along the way" []
      providers.Factory.grant_errors);
  (* the probe rows and the allowlist entries come from the built names' rows,
     so [--check] and the grant answer from the same table *)
  A.(check (list string) "one probe row per built name"
       [ "anysearch"; "freeserp"; "scrappa"; "searxng"; "serper" ]
       (List.sort String.compare (List.map fst providers.Factory.probe_table)));
  List.iter
    (fun name ->
      let endpoint = ok (Registry.grant_endpoint (row_of name) (entry_of name)) in
      A.(check bool (name ^ "'s allowlist entry is its row's endpoint") true
           (List.mem (show_endpoint endpoint) (List.map show_endpoint providers.Factory.endpoints))))
    [ "anysearch"; "freeserp"; "scrappa"; "searxng"; "serper" ];
  (* the row's probe is the one in the table, so [--check] asks what the row
     says rather than what a probe table somewhere else says *)
  List.iter
    (fun (name, spec) ->
      let row = row_of name in
      A.(check bool (name ^ " probes where its row points") true
           ((spec.Health.endpoint Config.default None
            : string option)
            = (Registry.probe_spec row).Health.endpoint Config.default None)))
    providers.Factory.probe_table

(* The row resolves the price, the cap and the key its adapter is built with:
   the builder takes them as arguments rather than re-deriving them, which is
   what lets an adapter's suite compare its own constants against the row. *)
let an_adapter_is_built_at_its_rows_figures () =
  let providers = build_all () in
  let unused_net =
    { Provider.Net.request = (fun _request -> failwith "this fixture never dials") }
  in
  List.iter
    (fun name ->
      let row = row_of name in
      let adapter =
        match List.assoc_opt name providers.Factory.built with
        | Some adapter -> adapter
        | None -> A.failf "%s did not build" name
      in
      A.(check string "the adapter answers to the row's name" name (Provider.name adapter);
        check (float 1e-9) (name ^ " is priced by its row")
          (Registry.price row (entry_of name)) (Provider.cost_per_1k adapter));
      match row.Registry.build with
      | Registry.Adapter make ->
          (* the row's builder is the only producer of a provider here, and a
             builder run with a price of its own passes that price through *)
          let args : Registry.args =
            {
              Registry.net = unused_net;
              now = (fun () -> 1768478400.);
              key = Some sentinel;
              entry = entry_of name;
              cost_per_1k = 1.25;
              snippet_chars = 400;
              text_chars = 2000;
              endpoint = ok (Registry.uri row (entry_of name));
            }
          in
          let built = make args in
          A.(check (float 1e-9) "a builder run directly takes its price from its arguments" 1.25
               (Provider.cost_per_1k built));
          List.iter
            (fun n ->
              (* the row's pricing model is the figure the adapter reports:
                 [--check --live] prints the row's [cost_of], a caller's notice
                 carries the adapter's [cost_for], and two spellings of a quote is
                 how one of them starts lying *)
              A.(check (float 1e-9) (name ^ " prices " ^ string_of_int n ^ " results like its row")
                   (Registry.cost_of row ~cost_per_1k:1.25 n) (Provider.cost_for built n)))
            [ 1; 10; 20 ]
      | Registry.Deferred wave -> A.failf "%s built from a row deferred to %s" name wave)
    [ "anysearch"; "freeserp" ]

(* A config correction reaches the adapter through the row, which is the whole
   point of [cost_per_1k] being a config key: the figure [--check --live] prints
   is the figure the adapter reports. *)
let a_config_correction_reaches_the_adapter () =
  set_keys ();
  let corrected =
    config [ ("freeserp", entry ~cost:3.50 ()); ("anysearch", entry ~cost:0.25 ()) ]
  in
  let providers =
    Eio_main.run @@ fun env ->
    Eio.Switch.run (fun sw ->
      Factory.build_providers ~sw ~net:env#net ~mono_clock:env#mono_clock
        ~now:(fun () -> 1768478400.) corrected)
  in
  clear_keys ();
  A.(check (list string) "both built" [ "anysearch"; "freeserp" ]
       (List.sort String.compare (List.map fst providers.Factory.built));
    check (float 1e-9) "the corrected freeserp figure" 3.50
      (Provider.cost_per_1k (some (List.assoc_opt "freeserp" providers.Factory.built)));
    check (float 1e-9) "and the corrected anysearch figure" 0.25
      (Provider.cost_per_1k (some (List.assoc_opt "anysearch" providers.Factory.built))))

(* Permission narrowing is a routing decision, not a construction one: the table
   holds the same seventeen rows whatever [permitted_providers] says, and a built
   but unpermitted name is still built so the router can refuse it by name at call
   time ([test_router] pins that sentence). Pinned here because a row that
   filtered itself by permission would turn a runtime refusal into a startup
   failure over a config the operator can only fix by widening the set. *)
let a_permission_set_narrows_routing_not_rows () =
  set_keys ();
  let narrowed =
    config ~permitted:[ "freeserp" ] [ ("anysearch", entry ()); ("freeserp", entry ()) ]
  in
  let providers =
    Eio_main.run @@ fun env ->
    Eio.Switch.run (fun sw ->
      Factory.build_providers ~sw ~net:env#net ~mono_clock:env#mono_clock
        ~now:(fun () -> 1768478400.) narrowed)
  in
  clear_keys ();
  let sets = Factory.classify narrowed providers in
  let anysearch_row = row_of "anysearch" in
  let unpermitted_entry = some (List.assoc_opt "anysearch" narrowed.Config.providers) in
  A.(check (float 1e-9) "an unpermitted name prices the same as a permitted one"
        (Registry.price anysearch_row (entry_of "anysearch"))
        (Registry.price anysearch_row unpermitted_entry);
     check string "and grants the same endpoint"
       (show_endpoint (ok (Registry.grant_endpoint anysearch_row (entry_of "anysearch"))))
       (show_endpoint (ok (Registry.grant_endpoint anysearch_row unpermitted_entry)));
     check (list string) "both adapters still build under a narrowed set"
       [ "anysearch"; "freeserp" ]
       (List.sort String.compare (List.map fst providers.Factory.built));
     check (list string) "built is not where the permission set bites"
       [ "anysearch"; "freeserp" ] (List.sort String.compare sets.Factory.built);
     check (list string) "effective is" [ "freeserp" ] sets.Factory.effective)

let () =
  (* A random generator is the caller's job, and a grant's TLS connector asks
     for one at construction: this suite holds the same caller-side wiring
     [test_boot] and [test_routing_sets] do. *)
  Mirage_crypto_rng_unix.use_default ();
  A.run "provider_registry"
    [ ("table", [ A.test_case "the rows are the frozen seventeen" `Quick
                    the_rows_are_the_frozen_seventeen;
                  A.test_case "every name has a row, built or deferred" `Quick
                    every_name_has_a_row_built_or_deferred ])
    ; ("price", [ A.test_case "one figure per name, one name fixed at zero" `Quick
                    the_rows_price_their_names;
                  A.test_case "the cost models are the published shapes" `Quick
                    the_cost_models_are_the_published_shapes ])
    ; ("timeout", [ A.test_case "the floors are what the backends need" `Quick
                      the_floors_are_what_the_backends_need;
                    A.test_case "a floor is a floor, not a ceiling" `Quick
                      a_floor_is_a_floor_not_a_ceiling ])
    ; ("endpoint", [ A.test_case "the grant is the endpoint read once" `Quick
                       the_grant_is_the_endpoint_read_once;
                     A.test_case "a fixed endpoint is the adapter's own" `Quick
                       a_fixed_endpoint_is_the_adapters_own;
                     A.test_case "a config endpoint comes from one value" `Quick
                       a_config_endpoint_comes_from_one_value;
                     A.test_case "Algolia's endpoint is the deployment" `Quick
                       algolias_endpoint_is_the_deployment ])
    ; ("probe", [ A.test_case "the probe asks what the grant allows" `Quick
                    the_probe_asks_the_endpoint_the_grant_allows;
                  A.test_case "the probe authenticates like the adapter" `Quick
                    the_probe_authenticates_the_way_the_adapter_does ])
    ; ("credential", [ A.test_case "the header spellings are the vendors'" `Quick
                         the_header_spellings_are_the_vendors;
                       A.test_case "serpapi keys ride the query, never a log" `Quick
                         serpapi_keys_ride_the_query_and_never_a_log;
                       A.test_case "only the names that may bill are handed a key" `Quick
                         only_the_names_that_may_bill_are_handed_a_key;
                       A.test_case "a missing prerequisite is named" `Quick
                         a_missing_prerequisite_is_named ])
    ; ("settings", [ A.test_case "every provider key belongs to a row" `Quick
                       every_provider_key_belongs_to_a_row ])
    ; ("construction", [ A.test_case "construction answers from the rows" `Quick
                           construction_answers_from_the_rows;
                         A.test_case "an adapter is built at its row's figures" `Quick
                           an_adapter_is_built_at_its_rows_figures;
                         A.test_case "a config correction reaches the adapter" `Quick
                           a_config_correction_reaches_the_adapter;
                         A.test_case "a permission set narrows routing, not rows" `Quick
                           a_permission_set_narrows_routing_not_rows ])
    ]
