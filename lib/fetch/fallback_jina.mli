(** Jina Reader — the keyless hosted fallback.

    [GET https://r.jina.ai/<url>] renders the page server-side and answers
    markdown, free and with no credential of any kind, so this module has no
    key field and the only headers it adds are the configured User-Agent and
    [Accept: text/markdown]. The service is metered by IP (≈20 requests per
    60 s), and a burst is {!Fallback.Quota} — one fallback failure among
    others, benched for a cooldown like any spent meter. The default cache is
    left on: re-rendering would spend one of those requests for nothing, so
    [X-No-Cache] is deliberately never sent.

    The two status arms mirror the oracle: 402/429 → Quota, every other ≥400
    — 401/403 included — is {!Fallback.Failed}[ ("HTTP n")], not a rejection,
    because this fallback sends no credential and a 403 is the service
    refusing this address, not a bad key.

    The body carries no schema ({!split_reader_body}): a run of [Key: value]
    lines, the literal line [Markdown Content:], and the page under it. The
    two placeholder bodies the service returns when it has no page —
    [Loading...] and [Please enable JavaScript] — read as {i found nothing}
    (empty text with the title kept), which is what lets the walk continue to
    the next fallback. [status_code] is 200 because that is all the reader
    reports; the origin's status is not in this body. *)

(* [Eio.Net.t]'s resource tag cannot be hidden inside a record type, so the
   config carries the parameter the way [Policy_net]'s confinement does; a
   caller never names it. *)
type 'tag config = {
  net : Fallback.net;
  target : 'tag Remote_target.t;
  max_text_chars : int;
  user_agent : string;
}

val jina_reader_endpoint : string
(** [https://r.jina.ai/] — the target is appended as a suffix, exactly as the
    oracle composes the URL. *)

val split_reader_body : string -> (string * string) list * string
(** [_split_reader_body]: the header block (keys lowercased, as the page
    mapping reads [title] and [url source]) and the page. A body with no
    marker line is returned whole as the page — the service answered with
    markdown it did not label, and dropping it would turn a usable read into
    an empty fallback. Only the keys the page mapping reads matter, so a new
    header line costs nothing here. *)

val fetch :
  'tag config ->
  string ->
  offset:int ->
  max_chars:int option ->
  (Fallback.page, Fallback.error) result
(** [fetch cfg url ~offset ~max_chars]: {!Remote_target.check} the target, GET
    the reader, and map the body. *)
