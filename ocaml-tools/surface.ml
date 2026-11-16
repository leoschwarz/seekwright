(* The frozen surface, printed from the OCaml tree.

   The body below the marker prints the frozen manifest: tools, routes, verbs,
   flags, provider names, config keys and the usage-journal fields. It prints in
   the format the freeze is written in — `--python-body` prints that body alone —
   so a frozen name that moves in the code but not in the manifest is visible.
   [surface.expected] is this tree's golden for the full rendering, and the
   runtest diff against it is what makes drift fail a build.

   Where each name comes from: tools, routes, verbs and flags are read from
   [Server]'s own tables (the same tables the declarations are built from, so
   the manifest cannot drift from the wire); provider names from
   [Config.known_providers]; the config keys by parsing the record types in
   [lib/config.mli], which is what the Python tool's [ast] pass does over
   [config.py]. The journal field lists are the keys [Usage] writes per line
   kind; [test/test_p8_surface.ml] records one of each and pins these lists
   against the real journal, so a field renamed in [usage.ml] fails a test. *)

module Config = Seekwright.Config
module Server = Seekwright.Server

let ( // ) = Filename.concat

(* Scan record definitions in config.mli to extract field names. *)
let sections =
  [
    ("agent", "AgentConfig", "agent_config");
    ("dashboard", "DashboardConfig", "dashboard_config");
    ("fetch", "FetchConfig", "fetch_config");
    ("logging", "LoggingConfig", "logging_config");
    ("policy", "PolicyConfig", "policy_config");
    ("search", "SearchConfig", "search_config");
  ]

let record_fields lines type_name =
  (* The fields of `type <type_name> = { ... }`, in declaration order. *)
  let rec scan in_block acc = function
    | [] -> List.rev acc
    | line :: rest ->
        if in_block then
          if String.starts_with ~prefix:"}" line then scan false acc rest
          else
            match String.trim line with
            | "" -> scan true acc rest
            | trimmed when String.starts_with ~prefix:"(*" trimmed ->
                scan true acc rest
            | trimmed -> (
                match String.index_opt trimmed ':' with
                | Some colon ->
                    let name = String.trim (String.sub trimmed 0 colon) in
                    if name <> "" && name.[0] >= 'a' && name.[0] <= 'z' then
                      scan true (name :: acc) rest
                    else scan true acc rest
                | None -> scan true acc rest)
        else if
          String.starts_with ~prefix:"type " line
          && (match String.index_opt line '=' with
             | Some eq ->
                 String.trim (String.sub line 5 (eq - 5)) = type_name
                 && String.trim (String.sub line (eq + 1) (String.length line - eq - 1)) = "{"
             | None -> false)
        then scan true [] rest
        else scan false acc rest
  in
  scan false [] lines

(* The three key lists the manifest prints, each already sorted the way the
   Python tool sorts it. *)
type config_keys = {
  section_keys : (string * string list) list;
  per_provider : string list;
  top_level : string list;
}

let read_config_keys path =
  let lines = String.split_on_char '\n' (In_channel.with_open_text path In_channel.input_all) in
  let section_keys =
    List.map (fun (table, _model, record) -> (table, List.sort compare (record_fields lines record))) sections
  in
  let per_provider = List.sort compare (record_fields lines "provider_config") in
  (* [providers_defaulted] is a computed report, not a key the file carries —
     Python's manifest does not list it either, because the pydantic class
     does not declare it as a field. *)
  let top_level =
    List.filter (( <> ) "providers_defaulted") (List.sort compare (record_fields lines "t"))
  in
  { section_keys; per_provider; top_level }

let strip_trailing_blanks lines =
  (* The manifest ends at its last name: a trailing separator moves on every
     regeneration. *)
  let rec go lines =
    match List.rev lines with
    | "" :: rest -> go (List.rev rest)
    | _ -> lines
  in
  go lines

let entry label = "- `" ^ label ^ "`"

(* One named count per rendered heading, in the order the manifest prints
   them. A record rather than a positional tuple: every consumer of these
   numbers prints a different subset, and [render_full]'s summary sentence
   reaches past [count_lines] for the journal total, which no ten-position
   tuple could keep straight. *)
type counts = {
  tools : int;
  routes : int;
  verbs : int;
  flags : int;
  providers : int;
  section_total : int;
  section_count : int;
  per_provider_count : int;
  operational : int;
  top_level_count : int;
}

let count_lines { section_keys; per_provider; top_level } =
  {
    tools = List.length Server.tools_surface;
    routes = List.length Server.rest_routes;
    verbs = List.length Server.cli_verbs;
    flags = List.length Server.server_flags;
    providers = List.length Config.known_providers;
    section_total = List.fold_left (fun acc (_, keys) -> acc + List.length keys) 0 section_keys;
    section_count = List.length section_keys;
    per_provider_count = List.length per_provider;
    operational = List.length Server.operational_routes;
    top_level_count = List.length top_level;
  }

let render_body ({ section_keys; per_provider; top_level } as config_keys) =
  let { tools; routes; verbs; flags; providers; section_total; section_count; per_provider_count; operational; top_level_count } =
    count_lines config_keys
  in
  let lines = [ ""; Printf.sprintf "## MCP tools (%d)" tools; "" ] in
  let lines =
    List.fold_left
      (fun lines (name, params) ->
        lines
        @ [ Printf.sprintf "### `%s` (%d arguments)" name (List.length params); "" ]
        @ List.map entry params @ [ "" ])
      lines Server.tools_surface
  in
  let lines = lines @ [ Printf.sprintf "## REST routes (%d)" routes; "" ] in
  let lines =
    List.fold_left
      (fun lines (meth, path, model, keys) ->
        lines
        @ [ Printf.sprintf "### `%s %s` (`%s`, %d body keys)" meth path model (List.length keys); "" ]
        @ List.map entry keys @ [ "" ])
      lines Server.rest_routes
  in
  let lines =
    lines
    @ [
        Printf.sprintf "## Routes outside the frozen projection (%d)" operational;
        "";
        "Registered by the same `custom_route` calls, not under `/api/v1/`:";
        "";
      ]
    @ List.map (fun (meth, path) -> entry (meth ^ " " ^ path)) Server.operational_routes
  in
  let lines = lines @ [ ""; Printf.sprintf "## CLI verbs (%d)" verbs; "" ] @ List.map entry Server.cli_verbs in
  let lines = lines @ [ ""; Printf.sprintf "## Server flags (%d)" flags; "" ] @ List.map entry Server.server_flags in
  let lines =
    lines @ [ ""; Printf.sprintf "## Provider names (%d)" providers; "" ] @ List.map entry Config.known_providers
  in
  let lines =
    lines
    @ [
        "";
        Printf.sprintf "## Config sections (%d keys over %d tables)" section_total section_count;
        "";
      ]
  in
  let lines =
    List.fold_left
      (fun lines (table, keys) ->
        let model =
          List.assoc table (List.map (fun (t, m, _) -> (t, m)) sections)
        in
        lines
        @ [ Printf.sprintf "### `[%s]` -- `%s` (%d)" table model (List.length keys); "" ]
        @ List.map entry keys @ [ "" ])
      lines section_keys
  in
  let lines =
    lines
    @ [
        Printf.sprintf "### Per-provider keys -- `ProviderConfig` (%d)" per_provider_count;
        "";
      ]
    @ List.map entry per_provider
    @ [ "" ]
  in
  let lines =
    lines
    @ [ Printf.sprintf "### Top-level keys -- `Config` (%d)" top_level_count; "" ]
    @ List.map entry top_level
  in
  strip_trailing_blanks lines

let render_journal () =
  let total = List.fold_left (fun acc (_, fields) -> acc + List.length fields) 0 Server.journal_fields in
  let lines =
    [ ""; Printf.sprintf "## Usage-journal fields (%d)" total; "" ]
  in
  List.fold_left
    (fun lines (kind, fields) ->
      lines
      @ [ Printf.sprintf "### `%s` line (%d fields)" kind (List.length fields); "" ]
      @ List.map entry fields @ [ "" ])
    lines Server.journal_fields
  |> strip_trailing_blanks

let render_full config_keys =
  let { tools; routes; verbs; flags; providers; section_total; section_count; per_provider_count; operational; top_level_count = _ } =
    count_lines config_keys
  in
  let journal_total =
    List.fold_left (fun acc (_, fields) -> acc + List.length fields) 0 Server.journal_fields
  in
  let header =
    [
      "# The frozen surface, printed from the OCaml tree";
      "";
      "Generated by `ocaml-tools/surface.ml` from the OCaml port's tree; not edited by hand.";
      "The body below the marker prints the frozen manifest in the format the freeze is";
      "written in (`--python-body` prints that body alone). The golden `surface.expected`";
      "fails the build on any drift, journal fields included.";
      "";
      Printf.sprintf
        "%d MCP tools, %d REST routes, %d CLI verbs, %d server flags, %d provider names, %d section config keys over %d tables, %d per-provider config keys, %d operational routes, %d usage-journal fields."
        tools routes verbs flags providers section_total section_count per_provider_count operational
        journal_total;
      "";
      "<!-- surface:body -->";
    ]
  in
  header @ render_body config_keys @ render_journal ()

let print lines = List.iter print_endline lines

let () =
  (* argv always carries the executable name, but reading the tail by pattern
     keeps the scan total. *)
  let args =
    match Array.to_list Sys.argv with _ :: args -> args | [] -> []
  in
  let python_body = List.mem "--python-body" args in
  let path_args = List.filter (fun a -> a <> "--python-body") args in
  let config_mli =
    match path_args with
    | path :: _ -> path
    | [] -> ".." // "lib" // "config.mli"
  in
  let config_keys = read_config_keys config_mli in
  if python_body then print (render_body config_keys) else print (render_full config_keys)
