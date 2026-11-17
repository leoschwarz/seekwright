module Config = Seekwright.Config
module Factory = Seekwright_factory.Factory
module Health = Seekwright.Health
module Registry = Seekwright_factory.Registry

let outcome_prose = function
  | Health.Reachable -> "reachable"
  | Health.Reachable_no_key -> "reachable (no key sent)"
  | Health.Key_rejected -> "reachable, but API key rejected"
  | Health.Key_required -> "no API key (key is mandatory)"
  | Health.Unreachable -> "unreachable"
  | Health.Unsupported -> "no connectivity probe"

let default_route_line config =
  match config.Config.default_provider with
  | Some name -> name
  | None ->
      if Config.default_route_is_free_only config then "none (a bare search walks the free set)"
      else "none (callers must pass provider)"

let no_row_state = "(inactive: no row in the fallback registry)"

let is_inactive state =
  let prefix = "(inactive:" in
  String.length state >= String.length prefix && String.sub state 0 (String.length prefix) = prefix

let fetch_key_host config key =
  match key with "crawl4ai_url" -> config.Config.fetch.Config.crawl4ai_url | _ -> None

let fallback_state config (row : Config.fetch_fallback) =
  let has_key name =
    match Config.api_key name with Some key when key <> "" -> true | _ -> false
  in
  let keyed = List.mem row.Config.name Config.providers_requiring_key in
  if row.Config.endpoint <> None && not (Config.is_permitted config row.Config.name) then
    "(inactive: not permitted)"
  else if keyed && not (has_key row.Config.name) then "(inactive: no API key)"
  else if row.Config.endpoint = None then
    match row.Config.fetch_key with
    | None -> "(inactive: the fallback row names no host)"
    | Some key -> (
        match fetch_key_host config key with
        | None | Some "" -> Printf.sprintf "(inactive: no fetch.%s)" key
        | Some host -> Printf.sprintf "self-hosted  %s" host)
  else if keyed then "keyed"
  else "keyless"

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
    emit
      (Printf.sprintf "  enabled   %d chars max, %d redirects, private addresses %s"
         fetch.Config.max_text_chars fetch.Config.max_redirects
         (if fetch.Config.allow_private_addresses then
            "allowed (the local reader is built with the private-web grant)"
          else "blocked"));
    if fetch.Config.primary = "http" then emit "  primary   http (the local reader)"
    else begin
      let row =
        List.find_opt
          (fun (r : Config.fetch_fallback) -> r.Config.name = fetch.Config.primary)
          Config.known_fetch_fallbacks
      in
      let state = match row with Some row -> fallback_state config row | None -> no_row_state in
      emit (Printf.sprintf "  primary   %s %s" fetch.Config.primary state);
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
              List.find_opt
                (fun (r : Config.fetch_fallback) -> r.Config.name = name)
                Config.known_fetch_fallbacks
            with
            | Some row -> emit (Printf.sprintf "  %-9s %s" name (fallback_state config row))
            | None -> emit (Printf.sprintf "  %-9s %s" name no_row_state))
          names);
    match (fetch.Config.cache_dir, cache_stats) with
    | None, _ -> emit "  cache     off"
    | Some dir, Some (Ok (Some (entries, body_bytes))) ->
        emit
          (Printf.sprintf "  cache     %s (%.0f MiB cap, ttl %.0fs)  %s, %s" dir
             (float_of_int fetch.Config.cache_max_bytes /. 1_048_576.0)
             fetch.Config.cache_ttl_seconds (human_entries entries) (human_bytes body_bytes))
    | Some dir, Some (Error message) ->
        emit
          (Printf.sprintf "  cache     %s (%.0f MiB cap, ttl %.0fs)  UNAVAILABLE: %s" dir
             (float_of_int fetch.Config.cache_max_bytes /. 1_048_576.0)
             fetch.Config.cache_ttl_seconds message);
        problems := !problems + 1
    | Some dir, _ ->
        emit
          (Printf.sprintf "  cache     %s (%.0f MiB cap, ttl %.0fs)" dir
             (float_of_int fetch.Config.cache_max_bytes /. 1_048_576.0)
             fetch.Config.cache_ttl_seconds)
  end;
  !problems

let report_agent emit config problems =
  let problems = ref problems in
  emit "agent";
  let agent = config.Config.agent in
  if not agent.Config.enabled then emit "  disabled in config"
  else
    begin match Config.missing_agent_settings config with
    | [] ->
        emit (Printf.sprintf "  model     %s" (Option.value ~default:"" agent.Config.model));
        emit (Printf.sprintf "  endpoint  %s" (Option.value ~default:"" agent.Config.base_url))
    | missing ->
        emit (Printf.sprintf "  enabled but incomplete: %s" (String.concat ", " missing));
        problems := !problems + 1
    end;
  !problems

let run ~env ~sw ~config ~emit ~live =
  let problems = ref 0 in
  emit "seekwright check";
  emit "================";
  let path = Config.config_path None in
  emit
    (Printf.sprintf "config      %s  %s" path
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
    emit
      (Printf.sprintf
         "  implicit  nothing was enabled, so the keyless set (%s) is the effective set"
         (String.concat ", " Config.keyless_providers));
  let built =
    Factory.build_providers ~sw ~net:env#net ~mono_clock:env#mono_clock
      ~now:(fun () -> Unix.gettimeofday ())
      config
  in
  let sets = Factory.classify config built in
  emit
    (Printf.sprintf "  enabled   %s"
       (if sets.Factory.enabled = [] then "(none)" else String.concat ", " sets.Factory.enabled));
  emit
    (Printf.sprintf "  effective %s"
       (if sets.Factory.effective = [] then "(none)" else String.concat ", " sets.Factory.effective));
  emit
    (Printf.sprintf "  built     %s"
       (if sets.Factory.built = [] then "(none)" else String.concat ", " sets.Factory.built));
  (match sets.Factory.skipped with
  | [] -> ()
  | names ->
      emit
        (Printf.sprintf
           "  skipped   %s  (keyless defaults not built on this port; routing uses the built \
            remainder: %s)"
           (String.concat ", " names)
           (String.concat ", " sets.Factory.built)));
  (match sets.Factory.unsupported with
  | [] -> ()
  | names -> begin
      emit
        (Printf.sprintf
           "  unsupported %s  (not built on this port; the server refuses to start on this config)"
           (String.concat ", " names))
    end);
  (match sets.Factory.untested with
  | [] -> ()
  | names ->
      let verb = if List.length names = 1 then "is" else "are" in
      emit
        (Printf.sprintf
           "  untested  %s %s untested on this port: no live verification against the real \
            endpoint has happened in the OCaml build, and a reachability probe is not one"
           (String.concat ", " names) verb));
  if config.Config.providers_defaulted && sets.Factory.built = [] then begin
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
      ~timeout_seconds:config.Config.policy.Config.provider_timeout_seconds built.Factory.endpoints
  in
  let ready = ref 0 in
  let unprobed_names = ref [] in
  let failed = ref 0 in
  let lines = ref [] in
  List.iter
    (fun name ->
      match List.assoc_opt name built.Factory.built with
      | None ->
          lines := !lines @ [ Printf.sprintf "  %-9s not built on this port" name ];
          if List.mem name sets.Factory.unsupported then begin
            problems := !problems + 1;
            incr failed
          end
      | Some _provider ->
          let outcome = Health.probe ~net:probe_net ~table:built.Factory.probe_table config name in
          (* The rate is the row's, not the adapter's: an adapter is handed a price function and
             reports only what a search actually cost. *)
          let price =
            match (Registry.row name, List.assoc_opt name config.Config.providers) with
            | Some row, Some pc ->
                let rate = Registry.rate row pc in
                if rate > 0.0 then Printf.sprintf "$%.2f/1k" rate else "unbilled"
            | _ -> "unbilled"
          in
          (match outcome with
          | Health.Reachable | Health.Reachable_no_key -> incr ready
          | Health.Unsupported ->
              (* Unsupported probe is not a failure: the adapter is built but has no bodyless probe. *)
              unprobed_names := !unprobed_names @ [ name ]
          | _ ->
              problems := !problems + 1;
              incr failed);
          lines := !lines @ [ Printf.sprintf "  %-9s %-22s %s" name (outcome_prose outcome) price ])
    (Config.enabled_providers config);
  if live then lines := !lines @ [ "live probes (one real search per ready permitted provider):" ]
  else if !ready = 0 && !lines = [] then lines := [ "  (none ready)" ];
  List.iter emit !lines;
  let enabled = Config.enabled_providers config in
  if !ready > 0 then
    emit (Printf.sprintf "%d of %d enabled providers ready" !ready (List.length enabled))
  else begin
    if !unprobed_names <> [] then
      emit
        (Printf.sprintf
           "  probes    no connectivity probe on this port for: %s -- built here, and their \
            readiness is the MCP handshake at warmup"
           (String.concat ", " !unprobed_names));
    if !unprobed_names = [] || !failed > 0 then begin
      emit "no providers ready -- searches would fail until configured";
      problems := !problems + 1
    end
  end;
  let effective = Config.effective_providers config in
  if List.length effective <> List.length enabled then
    emit
      (Printf.sprintf "narrowed    %d of %d enabled providers permitted; not permitted: %s"
         (List.length effective) (List.length enabled)
         (String.concat ", " (List.filter (fun name -> not (List.mem name effective)) enabled)));
  let cache_stats = Factory.page_cache_stats ~sw ~mono_clock:env#mono_clock ~fs:env#fs config in
  let problems = report_fetch ~cache_stats emit config !problems in
  let problems = report_agent emit config problems in
  if problems > 0 then 1 else 0
