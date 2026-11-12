(** The fetch path's name for the port's one codepoint walk.

    The walk lives in [seekwright.text] — [Seekwright_text.Utf8] — and this
    module is that module, so the fetch stack keeps saying [Utf8.]. It could not
    stay here: [seekwright] consumes the page this library produces and may not
    link it, so [engine.ml], [provider.ml], [agent.ml], [model.ml] and
    [sanitize.ml] each carried their own copy, in three spellings of the same
    byte test that disagreed about a five-byte lead byte and about clamping the
    last step (style review H1 and H2).

    Read {!Seekwright_text.Utf8} for the signature and for the two constraints on
    the lead-byte test. The short version: every length and offset the fetch
    stack carries — [total_chars], a window's [offset], a [select_paths] span —
    is a codepoint offset, a byte the encoder would not emit is one character,
    and a step never runs past the end of the string. *)

include module type of Seekwright_text.Utf8
