(** Live assertions ported per adapter. *)

module Model = Seekwright.Model

type check = { label : string; failure : string option }

val passing : string -> check

val expect : string -> bool -> string -> check

val provider_step : name:string -> step:int -> Model.search_response -> check list

val fetch_url : string

val verify_fetch : Cases.fetch_case -> Model.fetch_response -> check list

val verify_agent : depth:Model.depth -> model:string -> Model.answer_response -> check list

val quota_limited : string -> bool
(** Whether a failed live call was refused by quota or a rate limit. *)

val failed_count : check list -> int

val summary : check list -> string
