(** Live harness runner: executes selected case, verifies assertions, and returns status. *)

module Cases = Cases
module Checks = Checks
module Config = Seekwright.Config
module Engine = Seekwright.Engine
module Factory = Seekwright_factory.Factory
module Model = Seekwright.Model
module Provider = Seekwright.Provider
module Registry = Seekwright_factory.Registry
module Server = Seekwright.Server

type status = Passed | Skipped of string | Failed of string | Inconclusive of string

val status_exit : status -> int

val run :
  env:
    < net : [> [> `Generic ] Eio.Net.ty ] Eio.Resource.t
    ; fs : Eio.Fs.dir_ty Eio.Path.t
    ; mono_clock : [> Eio.Time.Mono.ty ] Eio.Resource.t
    ; .. > ->
  sw:Eio.Switch.t ->
  selector:Cases.selector ->
  emit:(string -> unit) ->
  status
