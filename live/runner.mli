(** The running half of the live harness: build exactly what the case needs,
    print the route and the spend class before dialling, run the ported
    assertions, and answer a status for the process's exit code.

    Construction follows the case kind:

    - a provider case builds one provider through {!Seekwright_factory.Factory.build_providers}
      and one {!Seekwright.Engine.Search} over it, so the call takes the route
      the served process takes (named provider, terminal: no ladder follows a
      name the caller asked for);
    - a fetch case builds the one fetch stack the config yields and closes it
      again, so a selected case cannot leave a reader or a worker pool behind
      between runs;
    - an agent case builds the whole app through {!Seekwright_factory.Factory.build_app},
      because the model endpoint's grant and the retrieval plan are assembled
      together there; its agent engine answers the question.

    Nothing here reads a secret: the key is read by the provider construction
    that has always read it, and the printed header names the *variable*.

    The cloud-metadata case is the one that expects a refusal: the public-web
    grant must reject [169.254.169.254] before a request leaves, so an answer
    there is a failed run, not a pass. *)

module Cases = Cases
module Checks = Checks
module Config = Seekwright.Config
module Engine = Seekwright.Engine
module Factory = Seekwright_factory.Factory
module Model = Seekwright.Model
module Provider = Seekwright.Provider
module Registry = Seekwright_factory.Registry
module Server = Seekwright.Server

(** What one case did. [Skipped] and [Passed] both exit zero; a skip is not a
    hidden pass — the reason is printed. *)
type status =
  | Passed
  | Skipped of string
  | Failed of string
  | Inconclusive of string

val status_exit : status -> int
(** [0] passed, [0] skipped, [1] failed, [3] inconclusive. Inconclusive has its
    own code so a maintainer's loop can tell "the provider rate-limited us" from
    "the parser broke". *)

val run :
  env:< net : [> [> `Generic ] Eio.Net.ty] Eio.Resource.t;
        fs : Eio.Fs.dir_ty Eio.Path.t;
        mono_clock : [> Eio.Time.Mono.ty] Eio.Resource.t;
        .. > ->
  sw:Eio.Switch.t ->
  selector:Cases.selector ->
  emit:(string -> unit) ->
  status
(** Run the one selected case. The gate variable is [main]'s check, not this
    function's: the runner is also what a future in-process caller drives. *)
