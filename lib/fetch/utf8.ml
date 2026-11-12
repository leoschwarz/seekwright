(* The fetch path's name for the port's one codepoint walk. It stays a module of
   this library because [tabledoc.ml], [jsondoc.ml], [extractor.ml] and
   [fetcher.ml] all say [Utf8.], and the walk itself cannot live here:
   [seekwright] consumes what this library produces and may not link it, so the
   copies sat on both sides of that direction (style review H2). See
   [seekwright.text]'s own [utf8.mli] for the walk and the two constraints its
   lead-byte test carries. *)

include Seekwright_text.Utf8
