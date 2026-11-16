(** Page and image records shared across the fetch path and engine. *)

type image = {
  media_type : string;  (** The media type verified by the body's initial bytes. *)
  body : string;  (** Raw image bytes. *)
}

type page = {
  url : string;  (** Final destination URL after following redirects. *)
  title : string option;
  text : string;
      (** Extracted text, unescaped (sanitization occurs at the serialisation boundary). *)
  content_type : string option;
  status_code : int;
  truncated : bool;
  total_chars : int;  (** Total codepoint count of the full extracted text. *)
  path_addressable : bool;  (** Whether [text] is a line-addressable JSON or CSV structure. *)
  image : image option;
}
