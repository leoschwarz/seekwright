type image = { media_type : string; body : string }

type page = {
  url : string
; title : string option
; text : string
; content_type : string option
; status_code : int
; truncated : bool
; total_chars : int
; path_addressable : bool
; image : image option
}
