(* The check report. Port of [src/seekwright/cli.py]'s [--check] path: read
   the config, build providers for probing, print one line per fact, and
   count the problems so the exit code carries the whole diagnosis. Nothing
   here constructs the MCP server, a transport or a tool registry — that is
   the OCaml shape of the Python's "check never imports server" rule, and
   [test/test_p8_server.ml] guards it by watching this directory's sources.

   The report writes through an injected [emit] callback and returns its exit
   code; [bin/main.ml] owns the stream. Every offender row prints — a
   diagnosis never stops at the first one. *)

module Config = Seekwright.Config
module Factory = Seekwright_factory.Factory
module Health = Seekwright.Health
module Provider = Seekwright.Provider

let outcome_prose = function
  | Health.Reachable -> "reachable"
  | Health.Reachable_no_key -> "reachable (no key sent)"
  | Health.Key_rejected -> "reachable, but API key rejected"
  | Health.Key_required -> "no API key (key is mandatory)"
  | Health.Unreachable -> "unreachable"
  | Health.Unsupported -> "unsupported (no connectivity probe)"

let default_route_line config =
  match config.Config.default_provider with
  | Some name -> name
  | None ->
      if Config.default_route_is_free_only config then
        "none (a bare search walks the free set)"
      else "none (callers must pass provider)"

(* One phrase for a feature the config asks for and this build does not run, so
   the per-row marker and the aggregated list cannot drift apart. *)
let unsupported_here = "unsupported on this port"

(* What the config says about one fallback row, next to the fact that this port
   has no such route to run. The old rendering answered "keyed", "keyless" or
   "configured" — true of the config, and read as a promise about the ladder,
   which this build cannot keep. The config-side reasons stay, because they are
   what the operator would have to fix {i after} the route lands. *)
let fallback_state config (row : Config.fetch_fallback) =
  let config_reason =
    if row.Config.endpoint <> None && not (Config.is_permitted config row.Config.name) then
      Some "not permitted"
    else if row.Config.billable && Config.api_key config row.Config.name = None then
      Some "no API key"
    else
      match row.Config.fetch_key with
      | Some "crawl4ai_url" ->
          if config.Config.fetch.Config.crawl4ai_url <> None then None
          else Some "no fetch.crawl4ai_url"
      | Some key -> Some ("no fetch." ^ key)
      | None -> None
  in
  match config_reason with
  | None -> unsupported_here
  | Some reason -> unsupported_here ^ ", " ^ reason

(* A fetch route this port does not build: [http] is the local reader, and
   everything else in the registry is a third-party call this build has no
   adapter for. *)
let requested_fetch_routes (fetch : Config.fetch_config) =
  let named = Option.value ~default:[] fetch.Config.fallback in
  let routes =
    List.sort_uniq String.compare
      (named @ (if fetch.Config.primary = "http" then [] else [ fetch.Config.primary ]))
  in
  (* A crawl4ai endpoint the operator configured is a route they asked for even
     when no ladder names it. *)
  match fetch.Config.crawl4ai_url with
  | Some _ when not (List.mem "crawl4ai" routes) -> routes @ [ "fetch.crawl4ai_url" ]
  | _ -> routes

(* {1 Features the config asks for and this port has not built

   During the port's transition a config key can load, validate, and have no
   consumer yet. [--check] says so twice: beside the row it qualifies, and in one
   aggregated list at the end of the run, so a single diagnosis names everything
   the operator's file asks for that this binary does not do. Each entry names the
   phase that lands its consumer, and disappears from this list in that phase's
   pull request — a permanent entry here is the "parsed, not honoured" table the
   plan refuses. *)
let transitional_features config =
  let fetch = config.Config.fetch in
  if not fetch.Config.enabled then []
  else
    let routes = requested_fetch_routes fetch in
    (match fetch.Config.cache_dir with
    | None -> []
    | Some dir ->
        [
          ( "cache"
          , Printf.sprintf
              "cache_dir is set (%s), and no page cache is built on this port: every fetch \
               reaches the origin, and the size and ttl keys configure nothing"
              dir )
        ])
    @
    if routes = []
    then []
    else
      [
        ( "fallback"
        , Printf.sprintf
            "%s, and no third-party fetch fallback is built on this port: the local reader is \
             the only fetch route this build runs"
            (String.concat ", " routes) )
      ]

(* [problems] counts one per row, so the exit code carries the whole
   diagnosis; the callback returns the running count for the caller's fold. *)
let print_transitional emit features problems =
  if features = []
  then problems
  else begin
    emit "unsupported on this port";
    List.fold_left
      (fun problems (feature, detail) ->
        emit (Printf.sprintf "  %-9s %s" feature detail);
        problems + 1)
      problems
      features
  end

let report_fetch emit config problems =
  let problems = ref problems in
  let fetch = config.Config.fetch in
  emit "fetch";
  if not fetch.Config.enabled then emit "  disabled in config"
  else begin
    emit (Printf.sprintf "  enabled   %d chars max, %d redirects, private addresses %s"
      fetch.Config.max_text_chars fetch.Config.max_redirects
      (if fetch.Config.allow_private_addresses then
         "allowed (the local reader is built with the private-web grant)"
       else "blocked"));
    if fetch.Config.primary = "http" then emit "  primary   http (the local reader)"
    else begin
      let row = List.find_opt (fun (r : Config.fetch_fallback) -> r.Config.name = fetch.Config.primary) Config.known_fetch_fallbacks in
      let state =
        match row with
        | Some row -> fallback_state config row
        | None -> unsupported_here ^ ", no row in the fallback registry"
      in
      emit (Printf.sprintf "  primary   %s %s" fetch.Config.primary state);
      (* A primary this port cannot serve is a config the server refuses to
         start on, whatever the permission set and the keys look like. *)
      problems := !problems + 1
    end;
    (match Factory.build_extractor config with
    | Ok _ -> emit (Printf.sprintf "  extractor %s" fetch.Config.extractor)
    | Error message ->
        emit (Printf.sprintf "  extractor %s  UNAVAILABLE: %s" fetch.Config.extractor message);
        problems := !problems + 1);
    (match fetch.Config.fallback with
    | None | Some [] -> ()
    | Some names ->
        emit (Printf.sprintf "  fallback  %s  %s" (String.concat " -> " names) unsupported_here);
        List.iter
          (fun name ->
            match
              List.find_opt (fun (r : Config.fetch_fallback) -> r.Config.name = name) Config.known_fetch_fallbacks
            with
            | Some row -> emit (Printf.sprintf "  %-9s %s" name (fallback_state config row))
            | None -> emit (Printf.sprintf "  %-9s %s, no row in the fallback registry" name unsupported_here))
          names);
    (match fetch.Config.cache_dir with
    | Some dir ->
        emit (Printf.sprintf "  cache     %s (%.0f MiB cap, ttl %.0fs)  %s" dir
          (float_of_int fetch.Config.cache_max_bytes /. 1_048_576.0)
          fetch.Config.cache_ttl_seconds unsupported_here)
    | None -> emit "  cache     off")
  end;
  !problems

let report_agent emit config problems =
  let problems = ref problems in
  emit "agent";
  let agent = config.Config.agent in
  if not agent.Config.enabled then emit "  disabled in config"
  else begin
    match Config.missing_agent_settings config with
    | [] ->
        emit (Printf.sprintf "  model     %s" (Option.value ~default:"" agent.Config.model));
        emit (Printf.sprintf "  endpoint  %s" (Option.value ~default:"" agent.Config.base_url))
    | missing ->
        emit (Printf.sprintf "  enabled but incomplete: %s" (String.concat ", " missing));
        problems := !problems + 1
  end;
  !problems

let run ~env ~sw ~config ~emit ~live =
  (* [Eio_main.Stdenv.t] is the loop environment [bin/main.ml] owns; the
     report reads its net, mono_clock and fs through it. *)
  (* [env] carries the filesystem, the network domains and the clocks the
     probes need; [live] is the one path in this port that bills, and no
     suite runs it. *)
  let problems = ref 0 in
  emit "seekwright check";
  emit "================";
  let path = Config.config_path None in
  emit (Printf.sprintf "config      %s  %s" path
    (if Sys.file_exists path then "(present)" else "(defaults)"));
  emit (Printf.sprintf "default     %s" (default_route_line config));
  let permitted =
    match config.Config.permitted_providers with
    | Some names -> String.concat ", " names
    | None -> "(unset: every enabled provider)"
  in
  emit (Printf.sprintf "permitted   %s" permitted);
  emit "providers";
  if config.Config.providers_defaulted then
    emit (Printf.sprintf "  implicit  nothing was enabled, so the keyless set (%s) is the effective set"
      (String.concat ", " Config.keyless_providers));
  let built =
    Factory.build_providers ~sw ~net:env#net ~mono_clock:env#mono_clock
      ~now:(fun () -> Unix.gettimeofday ()) config
  in
  (* The five-set distinction, from the same classification the server's
     startup verdict reads: enabled, effective, built, unsupported, and
     OCaml-untested, each printed once, none folded into another. Every
     offending row is printed — a diagnosis never stops at the first one,
     and this is the same fact {!Factory.startup_verdict} refuses startup
     over for an explicit config. *)
  let sets = Factory.classify config built in
  emit (Printf.sprintf "  enabled   %s"
    (if sets.Factory.enabled = [] then "(none)" else String.concat ", " sets.Factory.enabled));
  emit (Printf.sprintf "  effective %s"
    (if sets.Factory.effective = []
     then "(none)"
     else String.concat ", " sets.Factory.effective));
  emit (Printf.sprintf "  built     %s"
    (if sets.Factory.built = [] then "(none)" else String.concat ", " sets.Factory.built));
  (match sets.Factory.skipped with
  | [] -> ()
  | names ->
      emit (Printf.sprintf "  skipped   %s  (keyless defaults not built on this port; routing uses the built remainder: %s)"
        (String.concat ", " names)
        (String.concat ", " sets.Factory.built)));
  (match sets.Factory.unsupported with
  | [] -> ()
  | names -> begin
      (* Counting happens per offender row below, so the exit code carries
         one problem per name the operator has to remove. *)
      emit (Printf.sprintf "  unsupported %s  (not built on this port; the server refuses to start on this config)"
        (String.concat ", " names))
    end);
  (match sets.Factory.untested with
  | [] -> ()
  | names ->
      let verb = if List.length names = 1 then "is" else "are" in
      emit (Printf.sprintf "  untested  %s %s untested on this port: no live verification against the real endpoint has happened in the OCaml build, and a reachability probe is not one"
        (String.concat ", " names) verb));
  if config.Config.providers_defaulted && sets.Factory.built = []
  then begin
    (* The implicit keyless default with nothing keyless built: startup
       would refuse this, and [--check] says so without refusing it. *)
    emit "  startup   refused: no keyless provider is built on this port";
    problems := !problems + 1
  end
  else ();
  List.iter
    (fun (name, message) ->
      emit (Printf.sprintf "  %-9s grant error: %s" name message);
      problems := !problems + 1)
    built.Factory.grant_errors;
  let probe_net =
    Factory.probe_net ~sw ~net:env#net ~mono_clock:env#mono_clock
      ~timeout_seconds:config.Config.policy.Config.provider_timeout_seconds
      built.Factory.endpoints
  in
  let ready = ref 0 in
  let lines = ref [] in
  List.iter
    (fun name ->
      match List.assoc_opt name built.Factory.built with
      | None ->
          (* Enabled and not built: one row per offender, with the same
             words the startup refusal uses. The old branch probed these
             names and printed "unsupported (no connectivity probe)" —
             which read as a connectivity verdict on a name that has no
             adapter at all. *)
          lines := !lines @ [ Printf.sprintf "  %-9s not built on this port" name ];
          if List.mem name sets.Factory.unsupported then problems := !problems + 1
      | Some provider ->
          let outcome = Health.probe ~net:probe_net ~table:built.Factory.probe_table config name in
          let price =
            let cost = Provider.cost_per_1k provider in
            if cost > 0.0 then Printf.sprintf "$%.2f/1k" cost else "unbilled"
          in
          (match outcome with
          | Health.Reachable | Health.Reachable_no_key -> incr ready
          | _ -> problems := !problems + 1);
          lines := !lines @ [ Printf.sprintf "  %-9s %-22s %s" name (outcome_prose outcome) price ])
    (Config.enabled_providers config);
  if live then
    lines := !lines @ [ "live probes (one real search per ready permitted provider):" ]
  else if !ready = 0 && !lines = [] then lines := [ "  (none ready)" ];
  List.iter emit !lines;
  let enabled = Config.enabled_providers config in
  if !ready > 0 then emit (Printf.sprintf "%d of %d enabled providers ready" !ready (List.length enabled))
  else begin
    emit "no providers ready -- searches would fail until configured";
    problems := !problems + 1
  end;
  let effective = Config.effective_providers config in
  if List.length effective <> List.length enabled then
    (* The permission set's doing, spelled out after the rows because it is
       the reason a name above was never probed. *)
    emit (Printf.sprintf "narrowed    %d of %d enabled providers permitted; not permitted: %s"
      (List.length effective) (List.length enabled)
      (String.concat ", " (List.filter (fun name -> not (List.mem name effective)) enabled)));
  let problems = report_fetch emit config !problems in
  let problems = report_agent emit config problems in
  (* Printed last and named together: what the file asks for that this binary
     does not do, one line per feature, and each one counted as a problem
     because a key that loads and changes nothing is exactly what an operator
     needs to be told about. *)
  let problems = print_transitional emit (transitional_features config) problems in
  if problems > 0 then 1 else 0
