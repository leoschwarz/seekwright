(* The decisions, not the machinery that reads TOML to build a table. Every
   function here is a value-to-value map over the tables in the interface: no
   I/O, no clock, no mutable state, and no dependency on any other module
   ([lib/dune] declares none, and test/dune pins the dependency list), which is
   what makes this the file a rewrite in another language can implement 1:1. *)

exception Route_refused of string

type name = string

type rung_status =
  | Skip
  | Unpermitted
  | Open
  | Candidate

type rung = { name : name; status : rung_status }

let show_rung_status = function
  | Skip -> "skip"
  | Unpermitted -> "unpermitted"
  | Open -> "open"
  | Candidate -> "candidate"

type search_table =
  { providers : name list
  ; default : name option
  ; permitted : name list option
  ; fallback : name list
  ; free_fallback : name list
  ; free : name list
  ; free_order : name list
  ; effective : name list
  }

type fetch_table = { built : name list; primary : name option }

type search_mode = Free

(* Python writes these sentences with f-strings, where a name arrives through
   [repr] and is therefore single-quoted. A provider name is [backend] or
   [backend:flavour] — never a quote or a backslash — so the repr is exactly
   this, and the sentences the callers pin keep their quotes. *)
let quoted name = "'" ^ name ^ "'"

(* A [frozenset] renders sorted and without duplicates; a list can do neither
   on its own, so the vocabulary a sentence quotes goes through here. *)
let sorted_names names =
  let rec step acc = function
    | [] -> List.rev acc
    | head :: rest -> step (if List.mem head acc then acc else head :: acc) rest
  in
  List.sort String.compare (step [] names)

(* The allow-list as a printable list: [None] and the empty list both mean
  "nothing to name here" to the sentence, exactly as [table.permitted or ()]
  does in Python. *)
let permitted_names table =
  match table.permitted with None -> [] | Some names -> names

let is_permitted table name =
  match table.permitted with None -> true | Some names -> List.mem name names

let unnamed_walks_free table =
  table.default = None
  && table.effective <> []
  && List.for_all (fun name -> List.mem name table.free) table.effective

let free_candidates table =
  if table.free_fallback = [] then table.free_order else table.free_fallback

let free_walk table =
  List.filter
    (fun fallback ->
      List.mem fallback table.providers
      && List.mem fallback table.free
      && is_permitted table fallback)
    (free_candidates table)

(* The refusal for a caller-named provider the allow-list excludes.

   The recovery clause offers the default only when one exists *and* is itself
   permitted: advice to omit [provider] when that retry would be refused for
   the same reason fails on the second call. *)
let not_permitted table requested =
  let recovery =
    match table.default with
    | Some default when is_permitted table default ->
        "Retry with one of those, or omit `provider` to use the default."
    | Some _ | None -> "Retry with one of those."
  in
  Printf.sprintf "Provider %s is not permitted on this server. Permitted: %s. %s"
    (quoted requested)
    (String.concat ", " (permitted_names table))
    recovery

(* The refusal for a default the allow-list excludes.

   Never a reroute: raised in [resolve_search], before any ladder exists. *)
let default_not_permitted table default =
  Printf.sprintf
    "The default provider %s is not permitted on this server. Permitted: %s. \
     Pass `provider` with one of those."
    (quoted default)
    (String.concat ", " (permitted_names table))

(* The free walk's first fallback, or a [Route_refused] naming the free set.

   A clean error rather than a disappearing tool, because the schema is frozen
   at import and cannot advertise what this deployment enabled.

   Two reasons empty the walk, and they must not read alike: nothing free is
   enabled, or the allow-list removes every free name that is. The second names
   the permission set, the key the operator has to fix. *)
let resolve_free table =
  match free_walk table with
  | first :: _ -> first
  | [] ->
      let enabled_free =
        List.filter
          (fun fallback ->
            List.mem fallback table.providers && List.mem fallback table.free)
          (free_candidates table)
      in
      if enabled_free <> [] then
        raise
          (Route_refused
             (Printf.sprintf
                "No permitted free provider is enabled on this server, so a \
                 mode=\"free\" search has nothing to try. Permitted: %s. The \
                 free providers are: %s."
                (String.concat ", " (permitted_names table))
                (String.concat ", " (sorted_names table.free))))
      else
        raise
          (Route_refused
             (Printf.sprintf
                "No free provider is enabled on this server, so a mode=\"free\" \
                 search has nothing to try. The free providers are: %s."
                (String.concat ", " (sorted_names table.free))))

let resolve_search table ?mode requested =
  match mode with
  | Some Free -> resolve_free table
  | None ->
      let enabled =
        match table.providers with
        | [] -> "none"
        | names -> String.concat ", " names
      in
      (match requested with
      | None -> (
          match table.default with
          | None ->
              if unnamed_walks_free table then
                (* Same fallbacks, same order, same ending as [mode=Free] — the
                   mode's own walk, reached from the other direction. *)
                resolve_free table
              else
                raise
                  (Route_refused
                     ("No default provider is configured; pass `provider`. \
                        Available: "
                     ^ enabled ^ "."))
          | Some default ->
              if not (is_permitted table default) then
                raise (Route_refused (default_not_permitted table default))
              else default)
      | Some requested ->
          if not (List.mem requested table.providers) then begin
            (* Offer the default only when there is one; the other error is the
               recovery. *)
            let recovery =
              if table.default <> None then
                "Retry with one of those, or omit `provider` to use the default."
              else "Retry with one of those."
            in
            raise
              (Route_refused
                 (Printf.sprintf
                    "Provider %s is not enabled on this server. Available: %s. \
                     %s"
                    (quoted requested) enabled recovery))
          end
          else if not (is_permitted table requested) then
            raise (Route_refused (not_permitted table requested))
          else requested)

let fallback_rungs table ~ladder ~tried ~gated =
  List.map
    (fun name ->
      let status =
        if name = tried || not (List.mem name table.providers) then
          (* Already tried, or enabled-but-unbuilt: skipped silently, like
             fetch's inert fallbacks. *)
          Skip
        else if not (is_permitted table name) then
          (* Dead config the operator should fix, unlike a gated name's
             ordinary skip. *)
          Unpermitted
        else if List.mem name gated then Open
        else Candidate
      in
      { name; status })
    ladder

let fallback_served_notice ~tried ~original_reason ~fallback ~notice =
  let served =
    Printf.sprintf "%s failed (%s); served by %s instead" tried original_reason
      fallback
  in
  (* Python's condition is truthiness, so an adapter that sets [notice] to the
     empty string is served the same sentence as one that leaves it unset: the
     suffix would end in a dangling "; ". *)
  match notice with
  | None -> served
  | Some notice -> if notice = "" then served else served ^ "; " ^ notice

let fallback_exhausted_note ~failed ~mode =
  let fallbacks_note =
    if failed = [] then ""
    else " Fallbacks also failed: " ^ String.concat ", " failed ^ "."
  in
  let mode_note =
    match mode with
    | Some Free ->
        " The server was asked for a free-only search, so no paid provider was \
         tried."
    | None -> ""
  in
  fallbacks_note ^ mode_note

let retry_advice ~quota =
  if quota then " Do not retry immediately."
  else " Retry shortly or try a different phrasing."

let fetch_walk table =
  List.filter (fun name -> Some name <> table.primary) table.built

let origin table =
  match table.primary with None -> "local fetch" | Some primary -> primary

let provider_names table = String.concat ", " table.built

let choose_names table = String.concat ", " (fetch_walk table)

let choose_instead table =
  if fetch_walk table = [] then ""
  else
    " Other configured fetch providers: "
    ^ choose_names table
    ^ ". Retry once with `provider` set to one of those before concluding the \
       page cannot be read."

let not_enabled table requested =
  let listed =
    if table.built = [] then "No other fetch provider is configured on this server."
    else "Available: " ^ provider_names table ^ "."
  in
  let omit =
    match table.primary with
    | None -> "read the page locally"
    | Some _ -> "use this server's default route"
  in
  Printf.sprintf
    "Fetch provider %s is not enabled on this server. %s Retry with one of \
     those, or omit `provider` to %s."
    (quoted requested) listed omit

let empty_notice table ~walked =
  if walked || fetch_walk table = [] then
    "almost no readable text could be extracted (the page may be \
     JavaScript-rendered); try `search` for its content instead"
  else
    let source =
      match table.primary with
      | None -> "the local fetcher"
      | Some primary -> "`" ^ primary ^ "`"
    in
    "Almost no readable text came back from "
    ^ source ^ ". Other configured fetch providers: "
    ^ choose_names table
    ^ ". A page that extracts to nothing usually needs a browser, not a second \
       try at the same reader: retry once with `provider` set to one of those \
       before concluding the page has no text."

let refetched_notice table ~reason ~fallback =
  Printf.sprintf "%s failed (%s); refetched via %s" (origin table) reason fallback

let resolve_fetch table requested =
  match requested with
  | None -> None
  | Some requested ->
      if List.mem requested table.built then Some requested
      else raise (Route_refused (not_enabled table requested))
