module Config = Seekwright.Config

open Providers_build

let classify config (built : providers) =
  let built_names = List.sort String.compare (List.map fst built.built) in
  let missing = built.unsupported in
  let ocaml_untested =
    List.filter
      (fun name ->
        match Registry.row name with Some row -> not row.Registry.ocaml_live_tested | None -> true)
      built_names
  in
  let untested_pool = Config.untested_providers @ ocaml_untested in
  {
    enabled = Config.enabled_providers config;
    effective = Config.effective_providers config;
    built = built_names;
    unsupported = (if config.Config.providers_defaulted then [] else missing);
    skipped = (if config.Config.providers_defaulted then missing else []);
    untested =
      List.filter (fun name -> List.mem name untested_pool) (Config.enabled_providers config);
  }

let built_phrase sets = if sets.built = [] then "none" else String.concat ", " sets.built

let startup_verdict config (built : providers) =
  let sets = classify config built in
  match sets.unsupported with
  | [] -> (
      if config.Config.providers_defaulted && sets.built = [] then
        Error
          (Printf.sprintf
             "no keyless provider is built on this port: the implicit default (%s) is not built on \
              this port, and this build has nothing to route an unconfigured install through"
             (String.concat ", " sets.skipped))
      else
        match config.Config.default_provider with
        | Some name when not (List.mem name sets.built) ->
            Error
              (Printf.sprintf
                 "default provider '%s' is not built on this port (this build can dispatch: %s)"
                 name (built_phrase sets))
        | _ -> Ok ())
  | names ->
      Error
        (Printf.sprintf
           "the enabled providers %s are not built on this port (this build can dispatch: %s); \
            remove them from the [providers] table or see `seekwright --check`"
           (String.concat ", " names) (built_phrase sets))
