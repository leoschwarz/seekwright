(** The stdlib extraction backend: the one backend this build can always
    construct.

    Port of [src/seekwright/extractors/stdlib.py]. It implements
    {!Seekwright_fetch.Extractor.S}: HTML through a hand-written
    [html.parser] port (visible text in document order plus the document's
    title), JSON through [Jsondoc], delimited tables through [Tabledoc], and
    plain text passed through after decoding. It claims no PDF type — there is
    no PDF reader in this port, and the contract requires a backend to claim
    only what it can read — so the fetcher refuses a PDF by name before
    spending the body. *)

val name : string
val supported_types : string list
val extract : string -> string option -> Seekwright_fetch.Extractor.extract_result
