module Caps = Mcp_caps
module Utf8 = Seekwright_text.Utf8

type search_query = Model.search_query
type name = string

type error_kind = Failure | Quota

type error = { provider : string; kind : error_kind; message : string; retryable : bool }

let provider_error ?(retryable = true) ~provider message =
  { provider; kind = Failure; message; retryable }

let quota_exhausted ~provider ?(message = "quota exhausted") () =
  { provider; kind = Quota; message; retryable = false }

let render_error e = e.provider ^ ": " ^ e.message

let auth_error ~provider =
  provider_error ~retryable:false ~provider "authentication rejected (check API key)"

let http_status_error ~provider code = provider_error ~provider (Printf.sprintf "HTTP %d" code)

let timeout_error ~provider = provider_error ~provider "request timed out"
let network_error ~provider = provider_error ~provider "network error"

let transport_error ~provider (failure : Caps.Error.t) =
  match Caps.Error.kind failure with
  | Caps.Error.Timeout -> timeout_error ~provider
  | Caps.Error.Denied | Invalid | Unavailable | Failed -> network_error ~provider

let decode_json_object ~provider body =
  let malformed = provider_error ~provider "malformed JSON response" in
  match try Ok (Yojson.Safe.from_string body) with Yojson.Json_error _ -> Error malformed with
  | Error e -> Error e
  | Ok json -> ( match json with `Assoc _ -> Ok json | _ -> Error malformed)

let normalise text = String.concat " " (Utf8.split_whitespace text)

let rstrip text = Utf8.rstrip text

let clip text limit =
  (* Prefer sentence boundary if it covers more than half of limit; otherwise ellipsis. *)
  if Utf8.count text <= limit then text
  else begin
    let chars = Utf8.slices text in
    let n = Array.length chars in
    let window = min (limit + 1) n in
    let is_boundary a b = (a = "." || a = "!" || a = "?") && b = " " in
    let rec last_boundary k found =
      if k + 1 >= window then found
      else if is_boundary chars.(k) chars.(k + 1) then last_boundary (k + 1) (Some k)
      else last_boundary (k + 1) found
    in
    let join count = String.concat "" (Array.to_list (Array.sub chars 0 (min count n))) in
    match last_boundary 0 None with
    | Some k when k > limit / 2 -> join (k + 1)
    | _ -> rstrip (join limit) ^ "…"
  end

let truncate_snippet text limit =
  match text with
  | None -> (None, None)
  | Some text ->
      let normal = normalise text in
      (Some (clip normal limit), Some (Utf8.count normal))

let truncate_text text limit =
  match text with
  | None -> (None, false, None)
  | Some text ->
      let normal = normalise text in
      if normal = "" then (None, false, None)
      else
        let clipped = clip normal limit in
        (Some clipped, clipped <> normal, Some (Utf8.count normal))

let ignored_constraints (q : search_query) ~domains ~dates ~geo ~language ~safety =
  let missing = ref [] in
  let add token = missing := token :: !missing in
  if (not domains) && (q.Model.include_domains <> [] || q.Model.exclude_domains <> []) then
    add "domain";
  if (not dates) && q.Model.recency <> None then add "dates";
  (match language with
  | None ->
      if (not geo) && (q.Model.country <> None || q.Model.language <> None) then
        add "country/language"
  | Some honours_language ->
      if (not geo) && q.Model.country <> None then add "country";
      if (not honours_language) && q.Model.language <> None then add "language");
  if (not safety) && q.Model.safe_search <> None then add "safe-search";
  if !missing = [] then None
  else
    Some
      (Printf.sprintf "cannot filter by %s; that constraint was ignored"
         (String.concat " or " (List.rev !missing)))

let site_filtered_query (q : search_query) =
  let parts =
    if q.include_domains = [] then []
    else
      let joined = String.concat " OR " (List.map (fun d -> "site:" ^ d) q.include_domains) in
      [ (if List.length q.include_domains > 1 then "(" ^ joined ^ ")" else joined) ]
  in
  String.concat " " ((q.Model.query :: parts) @ List.map (fun d -> "-site:" ^ d) q.exclude_domains)

module Json = struct
  let members json = match json with `Assoc fields -> Some fields | _ -> None
  let list json = match json with `List items -> Some items | _ -> None
  let string json = match json with `String text -> Some text | _ -> None

  let number json =
    match json with
    | `Int n -> Some (float_of_int n)
    | `Intlit text -> ( match Float.of_string_opt text with Some f -> Some f | None -> None)
    | `Float f -> Some f
    | _ -> None

  let field key json =
    match members json with
    | Some fields -> ( match List.assoc_opt key fields with Some value -> value | None -> `Null)
    | None -> `Null

  let string_field key json = string (field key json)
  let number_field key json = number (field key json)

  let is_true json = match json with `Bool true -> true | _ -> false
  let is_true_field key json = is_true (field key json)
end

module Net = struct
  type t = {
    request : Caps.Authority.Net.request -> (Caps.Authority.Net.response, Caps.Error.t) result;
  }

  let of_grant grant = { request = (fun req -> Caps.Authority.Net.request grant req) }
end

let policy_of_uri (uri : Uri.t) : Caps.Policy.endpoint =
  {
    Caps.Policy.scheme = (if Uri.scheme uri = Some "https" then `Https else `Http);
    host = (match Uri.host uri with Some host -> host | None -> "");
    port = Uri.port uri;
  }

(* Host extraction for redaction in logs and errors; query parameters may carry credentials. *)
let redact_url (url : string) : string =
  match Uri.host (Uri.of_string url) with Some host when host <> "" -> host | _ -> "?"

let escape_path_segment (value : string) : string =
  let unreserved = function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '.' | '-' | '~' -> true
    | _ -> false
  in
  let out = Buffer.create (String.length value * 3) in
  String.iter
    (fun c ->
      if unreserved c then Buffer.add_char out c
      else Buffer.add_string out (Printf.sprintf "%%%02X" (Char.code c)))
    value;
  Buffer.contents out

type hit = { result : Model.result; uncapped_chars : int option }

type outcome = {
  provider : string;
  results : hit list;
  answer : string option;
  cost_usd : float option;
  notice : string option;
}

let to_provider_result o =
  {
    Model.provider = o.provider;
    results = List.map (fun (h : hit) -> h.result) o.results;
    answer = o.answer;
    cost_usd = o.cost_usd;
    notice = o.notice;
  }

module type S = sig
  val name : string
  val cost_per_1k : float
  val cost_for : int -> float
  val search : search_query -> (outcome, error) result
  val aclose : unit -> unit
end

type t = (module S)

let name (module P : S) = P.name
let cost_per_1k (module P : S) = P.cost_per_1k
let cost_for (module P : S) n = P.cost_for n
let search (module P : S) q = P.search q
let aclose (module P : S) = P.aclose ()

type session = { adapter : t; warmup : unit -> bool }

let project_url = "https://github.com/leoschwarz/seekwright"
