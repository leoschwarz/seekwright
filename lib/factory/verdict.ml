(* Whether a configuration may hold a routable provider set, and the sets a
   diagnosis reports. Port of the classification half of
   [src/seekwright/factory.py]'s report; the shape it reports in is
   [Provider_set]'s two records.

   [classify] is the reporting half — [--check] prints what it answers, and
   answers nothing else — and [startup_verdict] is the deciding half, the one
   [Factory.build_app] runs before an engine exists. They are one module because
   they are one classification: two renderings of the same sets, which is what
   makes [--check] and a startup refusal agree without a second rule.

   A configured name with no adapter in this build is a construction-time fact,
   and it is acted on at construction: [startup_verdict] refuses to start a server
   on an explicitly enabled name this port does not carry, naming every offender at
   once, because a running server holding such a config answers the named route with
   one refusal and the default route with a dispatch failure — and the honest choice
   is to refuse the half-configured deployment before it serves. The only exception
   is the implicit keyless default (no [providers] table at all), which may start
   over its built remainder with the skipped names logged by name; when even that
   remainder is empty, it refuses too. Every routing decision then reads one built,
   permitted set, and the engine's runtime no-adapter branch is a guard, never a
   route. *)

module Config = Seekwright.Config

(* The two records this module reports in are [Provider_set]'s. Opening it is
   what lets the record literal below keep its bare field labels: an unannotated
   function's return record has no expected type to disambiguate them by. *)
open Provider_set

(* {1 One routable set, and the configs that may serve it} *)

let classify config (built : providers) =
  let built_names = List.sort String.compare (List.map fst built.built) in
  let missing = built.unsupported in
  (* OCaml-untested is a property of this port, not of Python's live history:
     [Config.untested_providers] are the names Python itself has never run
     live, and {i every} name this build dispatches joins them until its own
     OCaml live run is recorded — which is what the row's [ocaml_live_tested]
     says, so the disclosure and the registry agree by reading one field
     rather than two lists kept in step. A probe ([--check], the health
     monitor) is a reachability check, not a live run — that is why this set
     is printed beside the ready count and never folded into it. *)
  let ocaml_untested =
    List.filter
      (fun name ->
        match Registry.row name with
        | Some row -> not row.Registry.ocaml_live_tested
        | None -> true)
      built_names
  in
  let untested_pool = Config.untested_providers @ ocaml_untested in
  {
    enabled = Config.enabled_providers config;
    effective = Config.effective_providers config;
    built = built_names;
    (* The same fact, split by how the config came to hold it: an explicit
       [providers] table naming an unbuilt name is the operator's mistake and
       startup refuses it; the implicit keyless default naming one is the
       port's transition and startup logs it. *)
    unsupported = (if config.Config.providers_defaulted then [] else missing);
    skipped = (if config.Config.providers_defaulted then missing else []);
    untested =
      List.filter (fun name -> List.mem name untested_pool) (Config.enabled_providers config);
  }

let built_phrase sets =
  if sets.built = [] then "none" else String.concat ", " sets.built

let startup_verdict config (built : providers) =
  let sets = classify config built in
  match sets.unsupported with
  | [] ->
      if config.Config.providers_defaulted && sets.built = [] then
        (* The transition exception to the rule stops applying when applying
           it would serve nothing: an unconfigured install must fail with the
           names that are missing, not boot into an engine that refuses every
           search. *)
        Error
          (Printf.sprintf
             "no keyless provider is built on this port: the implicit default \
              (%s) is not built on this port, and this build has nothing to \
              route an unconfigured install through"
             (String.concat ", " sets.skipped))
      else (
        match config.Config.default_provider with
        | Some name when not (List.mem name sets.built) ->
            (* Config validation already refuses a default outside [enabled];
               this is the enabled⇒built step that keeps [resolve_search]'s
               default arm and the engine registry describing one set, whatever
               pair reached this point. *)
            Error
              (Printf.sprintf "default provider '%s' is not built on this port \
                               (this build can dispatch: %s)"
                 name (built_phrase sets))
        | _ -> Ok ())
  | names ->
      (* Every offender in one line, sorted: a config missing three names
         should take one restart to fix, and the list has to read the same
         here as it does in [--check]. *)
      Error
        (Printf.sprintf "the enabled providers %s are not built on this port \
                         (this build can dispatch: %s); remove them from the \
                         [providers] table or see `seekwright --check`"
           (String.concat ", " names) (built_phrase sets))
