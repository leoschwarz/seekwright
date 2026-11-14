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
  (* Not a connectivity verdict: [Unsupported] means this port has no bodyless GET
     for a name it did build, and the row below says so in those words. *)
  | Health.Unsupported -> "no connectivity probe"

let default_route_line config =
  match config.Config.default_provider with
  | Some name -> name
  | None ->
      if Config.default_route_is_free_only config then
        "none (a bare search walks the free set)"
      else "none (callers must pass provider)"

(* The state word for a configured route this deployment did not build, and the
   test that counts one: every inert reason begins with the same prefix, so the row
   and the problem count read the same answer. *)
let no_row_state = "(inactive: no row in the fallback registry)"

let is_inactive state =
  let prefix = "(inactive:" in
  String.length state >= String.length prefix
  && String.sub state 0 (String.length prefix) = prefix

(* The one fallback row whose host this deployment writes itself. A self-hosted row
   declares no [endpoint] constant and names the [fetch] key that holds its host, so
   a new one has to appear here as well as in [Config.known_fetch_fallbacks]. *)
let fetch_key_host config key =
  match key with
  | "crawl4ai_url" -> config.Config.fetch.Config.crawl4ai_url
  | _ -> None

(* What one configured fetch route is on this build, read off its registry row, this
   deployment's permission set, and its keys — never off its name. A route is inert
   for one of four reasons, each a thing the operator can change; otherwise it is
   built, and the word says which half of [built] this deployment satisfies: [keyed]
   holds the credential its vendor bills against, [keyless] dials a route that needs
   none, and [self-hosted] names the renderer this deployment wrote itself.

   Two readings are deliberate. The permission test asks only of a row dialing a
   vendor constant, because a set that could refuse a self-hosted name would report a
   live route inert. And no probe rides these rows, unlike the provider block: a
   fetch row's state is a construction fact about keys and config, so it stays true on
   a box with no egress, and [--check] never dials somebody's reader on the
   operator's behalf. *)
let fallback_state config (row : Config.fetch_fallback) =
  let has_key name =
    match Config.api_key name with Some key when key <> "" -> true | _ -> false
  in
  let keyed = List.mem row.Config.name Config.providers_requiring_key in
  if row.Config.endpoint <> None && not (Config.is_permitted config row.Config.name) then
    "(inactive: not permitted)"
  else if keyed && not (has_key row.Config.name) then "(inactive: no API key)"
  else if row.Config.endpoint = None then
    (match row.Config.fetch_key with
    | None -> "(inactive: the fallback row names no host)"
    | Some key -> (
        match fetch_key_host config key with
        | None | Some "" -> Printf.sprintf "(inactive: no fetch.%s)" key
        | Some host -> Printf.sprintf "self-hosted  %s" host))
  else if keyed then "keyed"
  else "keyless"

(* The cache row's measured half: [Some (Ok (Some (entries, body_bytes)))] read off
   the directory the config names — [Factory.page_cache_stats] is the reader
   [--check] passes — or [Error] with the reason that directory could not be read.
   The reader is an argument rather than a call because the pure half of this
   report, which [test_cli_check] drives, has no filesystem to read: a row that
   invented figures it had not measured is the invention this file refuses. *)
let human_bytes bytes =
  let kib = float_of_int bytes /. 1024.0 in
  if bytes < 1024 then Printf.sprintf "%d B" bytes
  else if kib < 1024.0 then Printf.sprintf "%.1f KiB" kib
  else Printf.sprintf "%.1f MiB" (kib /. 1024.0)

let human_entries entries =
  Printf.sprintf "%d %s" entries (if entries = 1 then "entry" else "entries")

let report_fetch ?cache_stats emit config problems =
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
        | None -> no_row_state
      in
      emit (Printf.sprintf "  primary   %s %s" fetch.Config.primary state);
      (* Only an unbuilt primary counts, and only an unbuilt one can stop the
         server: the startup verdict refuses a [fetch.primary] the config names and
         the gates do not build. A built primary is a route the operator chose, and
         what it costs them is their own decision. *)
      if is_inactive state then problems := !problems + 1
    end;
    (match Factory.build_extractor config with
    | Ok _ -> emit (Printf.sprintf "  extractor %s" fetch.Config.extractor)
    | Error message ->
        emit (Printf.sprintf "  extractor %s  UNAVAILABLE: %s" fetch.Config.extractor message);
        problems := !problems + 1);
    (match fetch.Config.fallback with
    | None | Some [] -> ()
    | Some names ->
        emit (Printf.sprintf "  fallback  %s" (String.concat " -> " names));
        List.iter
          (fun name ->
            match
              List.find_opt (fun (r : Config.fetch_fallback) -> r.Config.name = name) Config.known_fetch_fallbacks
            with
            | Some row -> emit (Printf.sprintf "  %-9s %s" name (fallback_state config row))
            (* [fetch.fallback]'s validator refuses a name outside the registry, so this arm
               is the same defensive read [Factory] makes, reported rather than raised. *)
            | None -> emit (Printf.sprintf "  %-9s %s" name no_row_state))
          names);
    (match fetch.Config.cache_dir, cache_stats with
    | None, _ -> emit "  cache     off"
    | Some dir, Some (Ok (Some (entries, body_bytes))) ->
        (* The oracle prints the cap and the ttl; the port adds what is actually
           in the directory, because on this path those are measured rather than
           configured, and a diagnosis that could count them but prints only the
           ceiling is a diagnosis holding back the answer the operator wants. *)
        emit (Printf.sprintf "  cache     %s (%.0f MiB cap, ttl %.0fs)  %s, %s" dir
          (float_of_int fetch.Config.cache_max_bytes /. 1_048_576.0)
          fetch.Config.cache_ttl_seconds (human_entries entries) (human_bytes body_bytes))
    | Some dir, Some (Error message) ->
        (* A [cache_dir] this process cannot open is a startup failure the server
           would refuse on, so it counts as a problem here even though the config
           key itself is fine. *)
        emit (Printf.sprintf "  cache     %s (%.0f MiB cap, ttl %.0fs)  UNAVAILABLE: %s" dir
          (float_of_int fetch.Config.cache_max_bytes /. 1_048_576.0)
          fetch.Config.cache_ttl_seconds message);
        problems := !problems + 1
    | Some dir, _ ->
        emit (Printf.sprintf "  cache     %s (%.0f MiB cap, ttl %.0fs)" dir
          (float_of_int fetch.Config.cache_max_bytes /. 1_048_576.0)
          fetch.Config.cache_ttl_seconds))
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
  (* Built, probed, and this port has no probe for the name; and the names that
     failed a probe or a build. The summary needs them separately: "no providers
     ready" is a claim about the deployment, and it must not fire because this
     binary has nothing to dial. *)
  let unprobed_names = ref [] in
  let failed = ref 0 in
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
          if List.mem name sets.Factory.unsupported then begin
            problems := !problems + 1;
            incr failed
          end
      | Some provider ->
          let outcome = Health.probe ~net:probe_net ~table:built.Factory.probe_table config name in
          let price =
            let cost = Provider.cost_per_1k provider in
            if cost > 0.0 then Printf.sprintf "$%.2f/1k" cost else "unbilled"
          in
          (match outcome with
          | Health.Reachable | Health.Reachable_no_key -> incr ready
          | Health.Unsupported ->
              (* Built here, and this port has no bodyless GET for it — the two
                 anonymous MCP rows answer readiness with the handshake at warmup,
                 which the probe vocabulary cannot express. Nothing about the
                 deployment is wrong and the server serves these names, so this is
                 neither ready nor a problem: it is a hole in what [--check] can
                 say, and it is reported as one in the summary below. *)
              unprobed_names := !unprobed_names @ [ name ]
          | _ ->
              problems := !problems + 1;
              incr failed);
          lines := !lines @ [ Printf.sprintf "  %-9s %-22s %s" name (outcome_prose outcome) price ])
    (Config.enabled_providers config);
  if live then
    lines := !lines @ [ "live probes (one real search per ready permitted provider):" ]
  else if !ready = 0 && !lines = [] then lines := [ "  (none ready)" ];
  List.iter emit !lines;
  let enabled = Config.enabled_providers config in
  if !ready > 0 then emit (Printf.sprintf "%d of %d enabled providers ready" !ready (List.length enabled))
  else begin
    (* A built name this port cannot probe is a hole in the diagnosis, not a fault
       in the deployment: the server starts and serves these names, and their
       readiness is the MCP handshake at warmup. Say which names are unprobed
       rather than claiming none is ready — the claim would send an operator to
       fix a config that is already right, and would make an exit code out of a
       gap in this binary's own vocabulary. *)
    if !unprobed_names <> [] then
      emit (Printf.sprintf "  probes    no connectivity probe on this port for: %s -- built here, and their readiness is the MCP handshake at warmup"
        (String.concat ", " !unprobed_names));
    if !unprobed_names = [] || !failed > 0 then begin
      (* The refusal to serve stands only where a probe or a build actually
         failed: with an unprobed built name in the set, "searches would fail"
         is a prediction this port has not earned. *)
      emit "no providers ready -- searches would fail until configured";
      problems := !problems + 1
    end
  end;
  let effective = Config.effective_providers config in
  if List.length effective <> List.length enabled then
    (* The permission set's doing, spelled out after the rows because it is
       the reason a name above was never probed. *)
    emit (Printf.sprintf "narrowed    %d of %d enabled providers permitted; not permitted: %s"
      (List.length effective) (List.length enabled)
      (String.concat ", " (List.filter (fun name -> not (List.mem name effective)) enabled)));
  (* The cache figures are read before the fetch block prints, because the row
     that names the cap is the row that carries them. [page_cache_stats] opens the
     same written root [build_page_cache] does, so a [cache_dir] this process
     cannot create or open arrives here as an [Error] and counts as a problem —
     which is what the server would do with it at startup. *)
  let cache_stats = Factory.page_cache_stats ~sw ~mono_clock:env#mono_clock ~fs:env#fs config in
  let problems = report_fetch ~cache_stats emit config !problems in
  let problems = report_agent emit config problems in
  if problems > 0 then 1 else 0
