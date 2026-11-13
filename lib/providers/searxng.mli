(** SearXNG — a self-hosted metasearch instance, reached over its JSON API.

    Port of [src/seekwright/providers/searxng.py]. Cost note, unchanged: free,
    because it is the operator's own hardware aggregating other engines' results.
    There is no public endpoint to default to, so the instance URL is config
    ([[providers.searxng] url]) and enabling the name without one is a startup error
    rather than a silently absent backend — which is what {!Seekwright_factory}
    answers with {!Seekwright_factory.Registry.Url_required} for this row.

    The instance must serve [format=json] ([settings.yml]: [search.formats]
    including [json]). An instance without it answers HTML to every request, which
    surfaces here as the standard "malformed JSON response" error rather than a
    guess about what the page said. No SSRF guard sits in front of the URL: it is
    operator-fixed config and no caller input reaches it — the same trust level as an
    [exa] [url] override. Its grant is to the operator's own host and cannot acquire
    a key by accident.

    {b Pagination is the part that costs}: page size is the instance's to choose, so
    more hits are only learned by asking, and each page is another request that the
    instance fans out to its engines behind the scenes. {!max_pages} is the ceiling
    on that fan-out, and a failed {i continuation} page is not an error — the caller
    already holds good results, and a flaky or rate-limited second page must not
    destroy a search that succeeded.

    Constraints: [site:] operators carry the domains, [time_range] is the date
    restriction, [language] is passed as given, and [safesearch] is 0|1|2 with its
    [1] deliberately unreachable — [true] is the strongest on-state a backend has.
    Only the country has no parameter, so only the country is named in [notice]. *)

val name : string
(** ["searxng"], the config key and the [provider] every response names. *)

val max_pages : int
(** The ceiling on pages per search. Each page is another request to the operator's
    instance, which fans it out to its engines behind the scenes; three pages cover
    any [max_results] the tool schema allows (it caps at 20) at the default page
    size, and more when an instance is configured smaller. *)

val search_uri : Uri.t -> Uri.t
(** [search_uri instance] is the instance URL as the JSON API wants it: one trailing
    slash removed, however the operator wrote it, and [/search] appended — so
    [http://host:8080/], [http://host:8080] and [http://host:8080/searx] reach
    [http://host:8080/search] and [http://host:8080/searx/search]. *)

val make :
  ?cost_per_1k:float ->
  ?snippet_chars:int ->
  endpoint:Uri.t ->
  net:Seekwright.Provider.Net.t ->
  unit ->
  Seekwright.Provider.t
(** The adapter as a provider value. [endpoint] is the instance from config, read
    once by the registry and handed here — the adapter never re-reads the config key,
    and the grant this adapter is handed is confined to that destination. *)

val cost_for : cost_per_1k:float -> int -> float
(** Per-query cost in USD. Flat zero: a self-hosted instance bills no one. The
    argument is ignored rather than absent for the reason the freeserp adapter
    gives for its own: callers treat [cost_for] as a duck-typed method. *)

val parse : snippet_chars:int -> Yojson.Safe.t -> limit:int -> Seekwright.Provider.hit list
(** [results[]] (title, url, content, engines, score, publishedDate, ...). A SERP
    backend, so [content] becomes [snippet] and [text] is never filled. Records
    missing a title or URL are dropped rather than invented around; [engines] and
    [infobox] metadata is left where it came from; [publishedDate] is kept only when
    it is a string and [score] only when it is a number. *)
