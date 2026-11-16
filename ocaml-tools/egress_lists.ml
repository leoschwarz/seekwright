(* The host lists the deployment's proxies read, printed out of this tree rather
   than from memory.

   The half that is not the operator's opinion is derivable: [search] dials the
   destination on each [Registry.rows] row, and [fetch]'s ladder dials the
   endpoint on each [Config.known_fetch_fallbacks] row. Written by hand those
   lists drift — a provider lands, the list does not move, and the deployment
   quietly refuses a working provider — so this program prints them, and the
   diffs beside it in [dune] fail [dune runtest] when a checked-in copy has
   drifted.

   Two conventions the rendering depends on: a [dstdomain] list takes one item
   per line and documents no comment syntax, so the output carries no comments;
   and hosts are sorted by byte, so a new endpoint shows up as one added line at
   a known place.

   The operator's half is read from [deploy/compose/egress/] rather than derived:
   which pages a deployment reads, and which sinks it refuses, is that
   deployment's business. *)

module Config = Seekwright.Config
module Registry = Seekwright_factory.Registry
module StringSet = Set.Make (String)

let die fmt =
  Printf.ksprintf
    (fun message ->
      prerr_endline ("egress_lists: " ^ message);
      exit 2)
    fmt

let read_file path =
  try In_channel.with_open_text path In_channel.input_all
  with Sys_error message -> die "%s" message

(* A row whose endpoint names no host cannot be rendered into a host list, so it
   fails here, naming the row, rather than dropping a host from the list. *)
let host_of ~what uri =
  match Uri.host uri with
  | Some host when String.length host > 0 -> String.lowercase_ascii host
  | _ -> die "%s endpoint %s names no host" what (Uri.to_string uri)

(* [algolia]'s DSN host is [{app_id}-dsn.algolia.net], and the app id is the
   operator's: one deployment's app id names a host another deployment never
   dials, so the domain is the widest honest line; the leading dot is the
   domain-match form, which covers the DSN host under any app id. *)
let algolia_domain = ".algolia.net"

(* One line per host that any registry row dials. Every row contributes, so a row
   added to the inventory lands in the deployment's search list without a second
   edit. *)
let search_hosts () =
  let open Registry in
  List.fold_left
    (fun hosts (row : row) ->
      (* [Url_required] is [searxng]: its instance is the operator's URL, which no
         reading of this tree names, so the operator's own lists answer for it.
         [Url_override] contributes the vendor endpoint the row falls back to,
         not the override: an operator's [url] is that deployment's host. *)
      match row.endpoint with
      | Fixed_uri uri -> host_of ~what:row.name uri :: hosts
      | Url_override vendor -> host_of ~what:row.name vendor :: hosts
      | Url_required -> hosts
      | Algolia_index -> algolia_domain :: hosts)
    [] rows
  |> List.sort_uniq String.compare

(* A host line in the spelling Squid's [dstdomain] reads. This is validation, not
   parsing: a URL written into an operator list would match nothing forever, so
   it is refused rather than printed into the generated file. *)
let is_label label =
  let length = String.length label in
  length > 0
  && (match label.[0] with 'a' .. 'z' | '0' .. '9' -> true | _ -> false)
  && (match label.[length - 1] with 'a' .. 'z' | '0' .. '9' -> true | _ -> false)
  && String.for_all (function 'a' .. 'z' | '0' .. '9' | '-' -> true | _ -> false) label

let is_host_line line =
  let body =
    if String.starts_with ~prefix:"." line then
      String.sub line 1 (String.length line - 1)
    else line
  in
  match String.split_on_char '.' body with
  | _apex :: _tld :: _ as labels -> List.for_all is_label labels
  | _ -> false

let is_fallback_name name =
  let length = String.length name in
  length > 0
  && (match name.[0] with 'a' .. 'z' -> true | _ -> false)
  && String.for_all
       (function 'a' .. 'z' | '0' .. '9' | '_' | '-' -> true | _ -> false)
       name

(* A line answering for a fallback whose host is this deployment's:
   [fallback=<name> <host>] names the host, and a bare [fallback=<name>] says the
   deployment runs no such service. *)
let fallback_claim line =
  if not (String.starts_with ~prefix:"fallback=" line) then None
  else
    let rest = String.sub line 9 (String.length line - 9) in
    match String.index_opt rest ' ' with
    | Some space ->
        let name = String.sub rest 0 space in
        let host = String.trim (String.sub rest (space + 1) (String.length rest - space - 1)) in
        if is_fallback_name name then Some (name, Some host) else None
    | None -> if is_fallback_name rest then Some (rest, None) else None

(* One operator file as this program reads it: the hosts it names, and the
   fallbacks it answers for. A [fallback=<name> <host>] line names a host too — a
   fallback's host belongs on the allow-list like any other. *)
let operator_list path =
  let lines = String.split_on_char '\n' (read_file path) in
  let hosts, answers, _ =
    List.fold_left
      (fun (hosts, answers, number) raw ->
        let number = number + 1 in
        let line = String.trim raw in
        if line = "" || String.starts_with ~prefix:"#" line then (hosts, answers, number)
        else
          match fallback_claim line with
          | Some (name, host) ->
              let hosts =
                match host with
                | None -> hosts
                | Some host ->
                    if not (is_host_line host) then
                      die "%s:%d: %S after `fallback=%s` is not a host line" path number host
                        name;
                    StringSet.add host hosts
              in
              (hosts, StringSet.add name answers, number)
          | None ->
              if not (is_host_line line) then
                die "%s:%d: %S is not a host line" path number line;
              (StringSet.add line hosts, answers, number))
      (StringSet.empty, StringSet.empty, 0) lines
  in
  (hosts, answers)

let fallback_hosts () =
  List.filter_map
    (fun (row : Config.fetch_fallback) ->
      Option.map
        (fun endpoint -> host_of ~what:row.name (Uri.of_string endpoint))
        row.endpoint)
    Config.known_fetch_fallbacks

(* The hosts a strict fetch policy must allow: the operator's own list, checked
   against the ladder. Leaving a fallback's host out does not narrow the tool, it
   breaks it — the ladder walks to a host the deployment's firewall refuses — so
   that is a failure, not a narrower rendering. *)
let fetch_allow_hosts path =
  let hosts, answers = operator_list path in
  let dialled = fallback_hosts () in
  let missing =
    List.sort_uniq String.compare
      (List.filter (fun host -> not (StringSet.mem host hosts)) dialled)
  in
  if missing <> [] then
    die "%s names no fallback host: a strict policy that omits %s breaks `fetch` rather than narrowing it"
      path (String.concat ", " missing);
  let configured =
    List.filter_map
      (fun (row : Config.fetch_fallback) ->
        match row.endpoint with None -> Some row.name | Some _ -> None)
      Config.known_fetch_fallbacks
  in
  let unanswered = List.filter (fun name -> not (StringSet.mem name answers)) configured in
  if unanswered <> [] then
    die "%s says nothing about %s, whose host no constant names: write `fallback=<name> <host>` for the host this deployment dials, or `fallback=<name>` to say it runs none"
      path (String.concat ", " unanswered);
  let unfounded =
    List.filter (fun name -> not (List.mem name configured)) (StringSet.elements answers)
  in
  if unfounded <> [] then
    die "%s answers for %s, which names its own host in a constant or is no fallback this ladder walks"
      path (String.concat ", " unfounded);
  StringSet.elements hosts

(* The metadata pair is a rule of the deployment, not a sink the operator chose:
   the address-side guard ([Policy_net.special_use]) and the reference [nonpublic]
   ACL under [deploy/compose/squid/] cover 169.254.169.254, and these are the names
   some clouds resolve for it. Carried here so an edit to the operator file cannot
   drop the refusal from the generated list. *)
let metadata_names = [ "metadata.google.internal"; "metadata.goog" ]

let fetch_deny_hosts path =
  let hosts, _answers = operator_list path in
  StringSet.elements (StringSet.union hosts (StringSet.of_list metadata_names))

let () =
  let usage =
    "usage: egress_lists.exe search-allow | fetch-allow OPERATOR-FILE | fetch-deny \
     OPERATOR-FILE"
  in
  match Array.to_list Sys.argv with
  | _ :: [ "search-allow" ] -> List.iter print_endline (search_hosts ())
  | _ :: [ "fetch-allow"; path ] -> List.iter print_endline (fetch_allow_hosts path)
  | _ :: [ "fetch-deny"; path ] -> List.iter print_endline (fetch_deny_hosts path)
  | _ -> die "%s" usage
