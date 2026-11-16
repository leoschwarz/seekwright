(** The live harness case inventory: selector vocabulary, prerequisites, cost class, and search
    specifications. *)

module Config = Seekwright.Config
module Model = Seekwright.Model

type fetch_case = Local | Metadata | Jina | Scrappa | Tavily | Linkup

(** What one invocation selects: exactly one of these, never a set. *)
type selector = Provider of Config.name | Fetch of fetch_case | Agent of Model.depth

type query_spec = {
  query : string;
  max_results : int;
  include_domains : string list;
  exclude_domains : string list;
  country : string option;
  recency : Model.recency option;
}
(** One search a provider case issues. *)

type step = { label : string; spec : query_spec }

type cost_class = Unbilled | Billed

type build_status = Runnable | Deferred of string

val all : selector list

val name : selector -> string

val parse : string -> (selector, string) result

val provider_steps : Config.name -> step list

val provider_config : Config.name -> (Config.provider_config, string) result

val build_status : selector -> build_status

val cost_class : selector -> cost_class

val cost_prose : selector -> string

val needs : selector -> string list

val route : selector -> string

val credential : selector -> string

val call_count : selector -> int

val live_status : selector -> [ `Tested | `Untested ]

val usage : string

val recorded_non_provider_runs : string list
