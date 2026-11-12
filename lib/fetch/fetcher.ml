(* Fetching a URL safely, behind the Net authority grant. Port of
   [src/seekwright/fetcher.py]'s [HttpFetcher]. See fetcher.mli for the split of
   guardrails between this module and the grant. *)

module Caps = Mcp_caps
module E = Extractor
module J = Jsondoc

type fetched_image = Seekwright_wire.Page.image = {
  media_type : string;
  body : string;
}

type fetched_page = Seekwright_wire.Page.page = {
  url : string;
  title : string option;
  text : string;
  content_type : string option;
  status_code : int;
  truncated : bool;
  total_chars : int;
  path_addressable : bool;
  image : fetched_image option;
}

type refusal =
  | Url_blocked of string
  | Redirect_blocked of string
  | Blocked of string

type error =
  | Refusal of refusal
  | Failed of string

exception Url_blocked of string

let default_user_agent = "seekwright/0.1.1 (+https://github.com/leoschwarz/seekwright)"

let uncapped = 2_147_483_647

let resolved_cap default = function None -> default | Some max_chars -> max_chars

let image_types = [ "image/png"; "image/jpeg"; "image/gif"; "image/webp" ]

let png_signature = "\x89PNG\r\n\x1a\n"

let sniff_image_type (body : string) : string option =
  (* Magic numbers, not a decoder: this process never opens the image. *)

  if String.starts_with ~prefix:png_signature body then Some "image/png"
  else if String.starts_with ~prefix:"\xff\xd8\xff" body then Some "image/jpeg"
  else if
    String.starts_with ~prefix:"GIF87a" body
    || String.starts_with ~prefix:"GIF89a" body
  then Some "image/gif"
  else if
    String.starts_with ~prefix:"RIFF" body
    && String.length body >= 12
    && String.sub body 8 4 = "WEBP"
  then Some "image/webp"
  else None

(* JSON rides at q=0.7 and CSV at q=0.6: both are read here now, and an
   endpoint that negotiates should answer with the document rather than a
   wrapper page. *)

let accept_header =
  "text/html,application/xhtml+xml,application/pdf;q=0.9,"
  ^ "text/plain;q=0.8,application/json;q=0.7,text/csv;q=0.6,*/*;q=0.1"

(* {1 URL validation} *)

let ascii_lower s =
  String.map (fun c -> if c >= 'A' && c <= 'Z' then Char.chr (Char.code c + 32) else c) s

let py_repr s = "'" ^ String.concat "" (List.map (String.make 1) (List.init (String.length s) (String.get s))) ^ "'"

(* [validate_url] without the exception: the fetch chain turns a hop-0 refusal
   into [Url_blocked] and a later hop's into [Redirect_blocked]. *)

let validate_url_opt (raw : string) : (string, string) result =
  let s = String.trim raw in
  let n = String.length s in
  let scheme, rest =
    match String.index_opt s ':' with
    | Some i -> (String.sub s 0 i, String.sub s (i + 1) (n - i - 1))
    | None -> ("", s)
  in
  let scheme_l = ascii_lower scheme in
  if scheme_l <> "http" && scheme_l <> "https" then
    let shown = if scheme = "" then "(none)" else scheme in
    Error
      (Printf.sprintf "scheme %s is not fetchable; only http and https are allowed"
         (py_repr shown))
  else
    let after =
      if String.starts_with ~prefix:"//" rest then
        String.sub rest 2 (String.length rest - 2)
      else rest
    in
    let netloc_end =
      let rec go i =
        if i >= String.length after then String.length after
        else
          match after.[i] with '/' | '?' | '#' -> i | _ -> go (i + 1)
      in
      go 0
    in
    let netloc = String.sub after 0 netloc_end in
    let tail = String.sub after netloc_end (String.length after - netloc_end) in
    (* Credentials: refused, not stripped. [rpartition('@')] like urlsplit, and
       a refusal only when a username or a password is actually present. *)

    let hostinfo =
      match String.rindex_opt netloc '@' with
      | Some at ->
          let userinfo = String.sub netloc 0 at in
          let user, password =
            match String.index_opt userinfo ':' with
            | Some i ->
                ( String.sub userinfo 0 i,
                  Some (String.sub userinfo (i + 1) (String.length userinfo - i - 1)) )
            | None -> (userinfo, None)
          in
          if user <> "" || password <> Some "" && password <> None then
            Error "URLs with embedded credentials are refused"
          else Ok (String.sub netloc (at + 1) (String.length netloc - at - 1))
      | None -> Ok netloc
    in
    match hostinfo with
    | Error message -> Error message
    | Ok hostinfo ->
        (* Host and port: a bracketed IPv6 literal ends at []], anything else
           splits at the last [:]. *)

        let host, port_text =
          if String.length hostinfo > 0 && hostinfo.[0] = '[' then
            match String.index_opt hostinfo ']' with
            | Some close ->
                let host = String.sub hostinfo 1 (close - 1) in
                let rest = String.sub hostinfo (close + 1) (String.length hostinfo - close - 1) in
                let port_text =
                  if String.starts_with ~prefix:":" rest then
                    Some (String.sub rest 1 (String.length rest - 1))
                  else None
                in
                (host, port_text)
            | None -> (hostinfo, None)
          else
            match String.rindex_opt hostinfo ':' with
            | Some i ->
                (String.sub hostinfo 0 i, Some (String.sub hostinfo (i + 1) (String.length hostinfo - i - 1)))
            | None -> (hostinfo, None)
        in
        if host = "" then Error "URL has no host"
        else
          let port_ok =
            match port_text with
            | None | Some "" -> Ok ()
            | Some p ->
                if
                  String.for_all (fun c -> c >= '0' && c <= '9') p
                  && String.length p <= 5
                  && int_of_string p <= 65535
                then
                  if int_of_string p = 0 then Error "port 0 is not fetchable"
                  else Ok ()
                else
                  Error (Printf.sprintf "invalid port: %s is not a port in 1-65535" p)
          in
          match port_ok with
          | Error _ as e -> e
          | Ok () ->
              (* Path and query, fragment dropped: never sent to the server. *)

              let no_fragment =
                match String.index_opt tail '#' with
                | Some i -> String.sub tail 0 i
                | None -> tail
              in
              let path, query =
                match String.index_opt no_fragment '?' with
                | Some i ->
                    ( String.sub no_fragment 0 i,
                      Some
                        (String.sub no_fragment (i + 1) (String.length no_fragment - i - 1)) )
                | None -> (no_fragment, None)
              in
              let path = if path = "" then "/" else path in
              let query = match query with Some q when q <> "" -> "?" ^ q | _ -> "" in
              Ok (scheme_l ^ "://" ^ netloc ^ path ^ query)

let validate_url raw =
  match validate_url_opt raw with
  | Ok url -> url
  | Error message -> raise (Url_blocked message)

(* {1 The response window} *)

let rstrip_py (s : string) : string =
  let a = Utf8.of_string s in
  let n = Array.length a in
  let j = ref (n - 1) in
  while !j >= 0 && Utf8.is_python_space a.(!j) do
    decr j
  done;
  if !j < 0 then "" else Utf8.to_string (Array.sub a 0 (!j + 1))

let window_text (text : string) ~offset ~max_chars : string * bool =
  (* Slice the window [[offset, offset + max_chars)] out of an extraction, in
     codepoints — Python indexes strings by character, and so does every offset
     this module carries. *)

  let t = Utf8.of_string text in
  let n = Array.length t in
  let slice a b =
    (* [text[a:b]] with Python's clamping: past-the-end reads are empty. *)

    if a >= n || b <= a then ""
    else Utf8.to_string (Array.sub t a (min n b - a))
  in
  let remainder = if offset <= n then slice offset n else "" in
  if Utf8.count remainder <= max_chars && offset <= n then (remainder, false)
  else
    let window = slice offset (offset + max_chars + 1) in
    let w = Utf8.of_string window in
    let wn = Array.length w in
    (* [window.rfind("\n\n")]: the last paragraph break in the window. *)

    let found = ref (-1) in
    let i = ref 0 in
    while !i + 2 <= wn do
      if w.(!i) = 0x0A && w.(!i + 1) = 0x0A then found := !i;
      incr i
    done;
    let cut = if !found <= max_chars / 2 then max_chars else !found in
    let more_remains = offset + cut < n || offset > n in
    let sliced = rstrip_py (slice offset (offset + cut)) in
    let sliced =
      if sliced <> "" && more_remains then sliced ^ "\n\n[...]" else sliced
    in
    (sliced, more_remains)

(* {1 The fetcher} *)

type t = {
  net : Caps.Authority.Net.t;
  extractor : E.backend;
  max_download_bytes : int;
  max_text_chars : int;
  max_redirects : int;
  allow_images : bool;
  user_agent : string;
}

let make ~net ~extractor ?(max_download_bytes = 8_388_608) ?(max_text_chars = 40_000)
    ?(max_redirects = 3) ?(allow_images = false) ?(user_agent = default_user_agent) () =
  {
    net;
    extractor;
    max_download_bytes;
    max_text_chars;
    max_redirects;
    allow_images;
    user_agent;
  }

let contains_substring hay needle =
  let n = String.length hay and m = String.length needle in
  let rec go i =
    if i + m > n then false
    else String.sub hay i m = needle || go (i + 1)
  in
  m = 0 || go 0

let header name (headers : (string * string) list) : string option =
  let name = ascii_lower name in
  List.find_map
    (fun (k, v) -> if ascii_lower k = name then Some v else None)
    headers

let is_redirect status =
  List.mem status [ 301; 302; 303; 307; 308 ]

let type_refusal kind (extractor : E.backend) : string =
  (* Derived from the backend's supported set, so a backend swap cannot leave
     the sentence claiming a type the new backend does not have. *)

  let message =
    Printf.sprintf "cannot extract text from %s; this tool reads %s" kind
      (E.describe_types extractor.supported_types)
  in
  if List.mem kind image_types then
    message
    ^ "; set fetch.allow_images = true to return image bytes to a caller that \
       can read them"
  else message

(* The download cap, enforced on the grant-delivered body: the grant's own
   ceiling is the streaming bound (set where the grant is built), and this cap
   is the page bound, sliced exactly as the Python reader's buffer is. *)

let cap_body max_download_bytes (body : string) : string * bool =
  if String.length body > max_download_bytes then
    (String.sub body 0 max_download_bytes, true)
  else (body, false)

let rec fetch (t : t) (url : string) ~offset ~max_chars : (fetched_page, error) result =
  match validate_url_opt url with
  | Error message -> Error (Refusal (Url_blocked message))
  | Ok current ->
      let rec chain current hop =
        let request =
          {
            Caps.Authority.Net.meth = `GET;
            uri = Uri.of_string current;
            headers = [ ("user-agent", t.user_agent); ("accept", accept_header) ];
            body = None;
          }
        in
        match Caps.Authority.Net.request t.net request with
        | Error err -> (
            let message = Caps.Error.message err in
            match Caps.Error.kind err with
            | Caps.Error.Denied ->
                (* The grant's address/scheme policy refused this hop. A denial
                   of the requested URL at hop 0 is the URL as written
                   ([Url_blocked]); a denial of a redirect's Location — the grant
                   answers a 3xx with a [Denied] when the target is off-list,
                   with the pinned "with a redirect to a host this grant does
                   not allow" message — is a mid-flight refusal
                   ([Redirect_blocked]), as is any denial on a later hop. *)
                if
                  hop = 0
                  && not (contains_substring message "with a redirect to a host")
                then Error (Refusal (Url_blocked message))
                else Error (Refusal (Redirect_blocked message))
            | Caps.Error.Timeout -> Error (Failed "request timed out")
            | _ -> Error (Failed "network error"))
        | Ok response ->
            if is_redirect response.status then
              if hop >= t.max_redirects then
                Error
                  (Refusal
                     (Blocked
                        (Printf.sprintf "more than %d redirects" t.max_redirects)))
              else
                match header "location" response.headers with
                | None | Some "" ->
                    Error (Failed "redirect without a Location header")
                | Some location ->
                    let target =
                      Uri.to_string
                        (Uri.resolve "" (Uri.of_string current) (Uri.of_string location))
                    in
                    (match validate_url_opt target with
                    | Error message -> Error (Refusal (Redirect_blocked message))
                    | Ok target ->
                        (* A redirect from https to http is either a
                           misconfiguration or an active downgrade; either way
                           the caller asked for the secure one. *)

                        let scheme_of u =
                          match Uri.scheme (Uri.of_string u) with
                          | Some s -> ascii_lower s
                          | None -> ""
                        in
                        if scheme_of current = "https" && scheme_of target = "http" then
                          Error (Refusal (Blocked "refused a redirect from https to http"))
                        else chain target (hop + 1))
            else read t current response ~offset ~max_chars
      in
      chain current 0

and read (t : t) (url : string) (response : Caps.Authority.Net.response) ~offset ~max_chars :
    (fetched_page, error) result =
  if response.status >= 400 then
    (* An error page's body is not content. Returning it would hand the model a
       404 page to summarise as though it were the article. *)

    Error (Failed (Printf.sprintf "HTTP %d" response.status))
  else
    let content_type = header "content-type" response.headers in
    let kind = E.media_type content_type in
    (* An admitted image is handed over whole before any extraction question is
       asked: no backend extracts text from a picture. *)

    if List.mem kind image_types && t.allow_images then read_image t url response kind
    else if kind <> "" && not (E.is_supported t.extractor.supported_types kind) then
      Error (Refusal (Blocked (type_refusal kind t.extractor)))
    else
      let body, capped = cap_body t.max_download_bytes response.body in
      let limit_kib = t.max_download_bytes / 1024 in
      if capped && List.mem kind E.pdf_types then
        (* A PDF's cross-reference table lives at the end: a cut one is
           unreadable, not merely shorter. *)

        Error
          (Refusal
             (Blocked
                (Printf.sprintf
                   "PDF exceeds the %d KiB download limit and cannot be read in \
                    part; raise fetch.max_download_bytes to read it"
                   limit_kib)))
      else if capped && J.is_json_document_media kind then
        Error
          (Refusal
             (Blocked
                (Printf.sprintf
                   "JSON document exceeds the %d KiB download limit, and one cut \
                    in the middle cannot be read as one; raise \
                    fetch.max_download_bytes to read it"
                   limit_kib)))
      else if capped && List.mem kind image_types then
        Error
          (Refusal
             (Blocked
                (Printf.sprintf
                   "%s image exceeds the %d KiB download limit and cannot be \
                    returned in part; raise fetch.max_download_bytes to return it"
                   kind limit_kib)))
      else
        let extracted =
          try Ok (t.extractor.extract body content_type)
          with E.Extraction_failed message ->
            Error (Refusal (Blocked ("cannot extract text: " ^ message)))
        in
        match extracted with
        | Error _ as e -> e
        | Ok extracted ->
            let text, truncated =
              window_text extracted.text ~offset
                ~max_chars:(resolved_cap t.max_text_chars max_chars)
            in
            Ok
              {
                url;
                title = extracted.title;
                text;
                content_type = (if kind = "" then None else Some kind);
                status_code = response.status;
                truncated;
                total_chars = extracted.total_chars;
                path_addressable = extracted.path_addressable;
                image = None;
              }

and read_image (t : t) (url : string) (response : Caps.Authority.Net.response) (kind : string) :
    (fetched_page, error) result =
  (* The image is handed back whole, and only when its bytes agree with its
     header: the type was checked against the first bytes, not taken from the
     server's word. *)

  let body, capped = cap_body t.max_download_bytes response.body in
  let limit_kib = t.max_download_bytes / 1024 in
  if capped then
    Error
      (Refusal
         (Blocked
            (Printf.sprintf
               "%s image exceeds the %d KiB download limit and cannot be returned \
                in part; raise fetch.max_download_bytes to return it"
               kind limit_kib)))
  else if sniff_image_type body <> Some kind then
    Error
      (Refusal
         (Blocked
            (Printf.sprintf
               "the response is served as %s, but its first bytes are not that \
                image type"
               kind)))
  else
    (* Nothing is extracted, so the empty [text] is what makes the response's
       paging fields read correctly, and [total_chars] stays 0 because the
       character coordinate system has nothing in it. *)

    Ok
      {
        url;
        title = None;
        text = "";
        content_type = Some kind;
        status_code = response.status;
        truncated = false;
        total_chars = 0;
        path_addressable = false;
        image = Some { media_type = kind; body };
      }
