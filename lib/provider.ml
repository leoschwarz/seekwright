(* The provider contract, ported from src/seekwright/providers/base.py.

   Two of the helpers here — the caps and the constraint report — exist because
   the proxy is a proxy: it forwards bodies it did not write, and a caller
   cannot tell a filter that was dropped from one that was honoured, or a
   clipped snippet from a short one, unless the adapter says so. *)

module Caps = Mcp_caps

type search_query = Model.search_query
type name = string

type error_kind = Failure | Quota

type error = {
  provider : string;
  kind : error_kind;
  message : string;
  retryable : bool;
}

(* The seven rows of provider-contract.md's Failures table as named values, so
   an adapter writes its own mapping — Python does, and the per-vendor quirks
   (which statuses mean "out of credits", and what that failure is called) stay
   visible at the call site — while the wording itself has one home. *)

let provider_error ?(retryable = true) ~provider message =
  { provider; kind = Failure; message; retryable }

let quota_exhausted ~provider ?(message = "quota exhausted") () =
  { provider; kind = Quota; message; retryable = false }

let render_error e = e.provider ^ ": " ^ e.message

let auth_error ~provider =
  provider_error ~retryable:false ~provider
    "authentication rejected (check API key)"

let http_status_error ~provider code =
  provider_error ~provider (Printf.sprintf "HTTP %d" code)

let timeout_error ~provider = provider_error ~provider "request timed out"
let network_error ~provider = provider_error ~provider "network error"

let transport_error ~provider (failure : Caps.Error.t) =
  (* The grant's message is never copied: it may name the peer address it
     dialled, and httpx's equivalent echoed the request that carried the key. *)
  match Caps.Error.kind failure with
  | Caps.Error.Timeout -> timeout_error ~provider
  | (Caps.Error.Denied | Invalid | Unavailable | Failed) -> network_error ~provider

let decode_json_object ~provider body =
  (* An undecodable body and an unshaped one are the same wire failure, which is
     why both arms carry one message. Nothing about the body is reported: the
     redaction rule is that an adapter says what failed, not what it saw. *)
  let malformed = provider_error ~provider "malformed JSON response" in
  match (try Ok (Yojson.Safe.from_string body) with Yojson.Json_error _ -> Error malformed) with
  | Error e -> Error e
  | Ok json -> (
      match json with `Assoc _ -> Ok json | _ -> Error malformed)

(* UTF-8 helpers. The caps count {b characters}, as Python's [len] and slicing
   do, so a cap of 500 does not cut a multibyte token in half and a length
   figure means the same thing on both sides of the port. A lead byte of a
   sequence the encoder would not emit is treated as one character, so a hostile
   payload can neither loop here nor move a cut. *)

let lead_len s i =
  let c = Char.code s.[i] in
  if c < 0x80 then 1
  else if c < 0xc0 then 1
  else if c < 0xe0 then 2
  else if c < 0xf0 then 3
  else 4

let codepoints s =
  let acc = ref [] in
  let i = ref 0 in
  while !i < String.length s do
    let len = lead_len s !i in
    let len = if !i + len > String.length s then String.length s - !i else len in
    acc := String.sub s !i len :: !acc;
    i := !i + len
  done;
  Array.of_list (List.rev !acc)

let codepoint_count s =
  let n = ref 0 in
  let i = ref 0 in
  while !i < String.length s do
    let len = lead_len s !i in
    i := !i + if !i + len > String.length s then String.length s - !i else len;
    n := !n + 1
  done;
  !n

let is_space c =
  match c with ' ' | '\t' | '\n' | '\r' | '\011' | '\012' -> true | _ -> false

(* Python's [" ".join(text.split())]: runs of whitespace collapse to one space
   and the ends are trimmed. Python splits on Unicode whitespace; every
   provider payload in the oracle's fixtures separates on ASCII blanks, and a
   non-ASCII space inside a snippet only costs the collapse, so this keeps the
   ASCII set and says so. *)
let normalise text =
  let words = ref [] in
  let start = ref 0 in
  let flush stop =
    if stop > !start then words := String.sub text !start (stop - !start) :: !words
  in
  String.iteri
    (fun i c ->
      if is_space c then begin
        flush i;
        start := i + 1
      end)
    text;
  flush (String.length text);
  String.concat " " (List.rev !words)

let rstrip text =
  let stop = ref (String.length text) in
  while !stop > 0 && is_space text.[!stop - 1] do
    decr stop
  done;
  String.sub text 0 !stop

let clip text limit =
  (* Prefer a sentence boundary to mid-word, but only one far enough in to be
     worth more than the plain cut — otherwise a two-word snippet ends at its
     first period. *)
  if String.length text <= limit then text
  else begin
    let chars = codepoints text in
    let n = Array.length chars in
    let window = min (limit + 1) n in
    let is_boundary a b = (a = "." || a = "!" || a = "?") && b = " " in
    let rec last_boundary k found =
      if k + 1 >= window then found
      else if is_boundary chars.(k) chars.(k + 1) then last_boundary (k + 1) (Some k)
      else last_boundary (k + 1) found
    in
    let join count =
      String.concat "" (Array.to_list (Array.sub chars 0 (min count n)))
    in
    match last_boundary 0 None with
    | Some k when k > limit / 2 -> join (k + 1)
    | _ -> rstrip (join limit) ^ "…"
  end

let truncate_snippet text limit =
  match text with
  | None -> (None, None)
  | Some text ->
      let normal = normalise text in
      (Some (clip normal limit), Some (codepoint_count normal))

let truncate_text text limit =
  match text with
  | None -> (None, false, None)
  | Some text ->
      let normal = normalise text in
      if normal = "" then (None, false, None)
      else
        let clipped = clip normal limit in
        (Some clipped, clipped <> normal, Some (codepoint_count normal))

let ignored_constraints (q : search_query) ~domains ~dates ~geo ~language ~safety =
  let missing = ref [] in
  let add token = missing := token :: !missing in
  if not domains && (q.Model.include_domains <> [] || q.Model.exclude_domains <> []) then
    add "domain";
  if not dates && q.Model.recency <> None then add "dates";
  (match language with
  | None ->
      if not geo && (q.Model.country <> None || q.Model.language <> None) then
        add "country/language"
  | Some honours_language ->
      if not geo && q.Model.country <> None then add "country";
      if not honours_language && q.Model.language <> None then add "language");
  if not safety && q.Model.safe_search <> None then add "safe-search";
  if !missing = [] then None
  else
    Some
      (Printf.sprintf "cannot filter by %s; that constraint was ignored"
         (String.concat " or " (List.rev !missing)))

let site_filtered_query (q : search_query) =
  let parts =
    if q.include_domains = [] then []
    else
      let joined =
        String.concat " OR " (List.map (fun d -> "site:" ^ d) q.include_domains)
      in
      [ (if List.length q.include_domains > 1 then "(" ^ joined ^ ")" else joined) ]
  in
  String.concat " "
    (q.Model.query :: parts @ List.map (fun d -> "-site:" ^ d) q.exclude_domains)

module Json = struct
  (* The upstream payload is untrusted: a field documented as a string and sent
     as an object is dropped, not raised, exactly as Python's [isinstance]
     guards do — an [AttributeError] there would escape the engine's
     provider-error handling as an internal error. Every reader here answers
     [None] for "absent or not that shape", which is the same rule the adapters
     state in their docstrings. *)

  let members json = match json with `Assoc fields -> Some fields | _ -> None
  let list json = match json with `List items -> Some items | _ -> None
  let string json = match json with `String text -> Some text | _ -> None

  let number json =
    match json with
    | `Int n -> Some (float_of_int n)
    | `Intlit text -> (match Float.of_string_opt text with Some f -> Some f | None -> None)
    | `Float f -> Some f
    | _ -> None

  (* [field] hands back [Null] for a missing key, so a reader chains without an
     option in between, the way [item.get(key)] does. *)
  let field key json =
    match members json with
    | Some fields ->
        (match List.assoc_opt key fields with Some value -> value | None -> `Null)
    | None -> `Null

  let string_field key json = string (field key json)
  let number_field key json = number (field key json)

  (* [engine_fallback] is only a refusal in its present-and-[true] form; [1] is
     not [true], as in Python's [is True]. *)
  let is_true json = match json with `Bool true -> true | _ -> false
  let is_true_field key json = is_true (field key json)
end

module Net = struct
  type t = {
    request :
      Caps.Authority.Net.request -> (Caps.Authority.Net.response, Caps.Error.t) result
  }

  (* The grant's own per-call byte ceiling is left out on purpose: an adapter
     has no business widening or narrowing what the operator set, and Python's
     adapters pass no timeout either — httpx's is the client's, and here the
     bound is the grant's, set once by [Authority.with_operation_timeout]. *)
  let of_grant grant = { request = (fun req -> Caps.Authority.Net.request grant req) }
end

type hit = {
  result : Model.result;
  uncapped_chars : int option
}

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

let project_url = "https://github.com/leoschwarz/seekwright"
