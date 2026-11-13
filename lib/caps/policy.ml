(* The public policy surface: the confinement records are Policy_fs's and
   Policy_net's, and this module is the vocabulary an application reaches for
   instead. Splitting the records out of this file is what keeps
   [Authority.Fs.of_confinement] and [Authority.Net.of_confinement] able to name
   their witness types without a module cycle; see policy_fs.mli. *)

let with_root = Policy_fs.with_root

let default_max_read_bytes = Policy_fs.default_max_read_bytes
let default_max_entries = Policy_fs.default_max_entries

type endpoint = Policy_net.endpoint = {
  scheme : [ `Http | `Https ];
  host : string;
  port : int option;
}

let default_max_response_bytes = Policy_net.default_max_response_bytes

type port_policy = Policy_net.port_policy = Default_ports | Any_port

let with_endpoints = Policy_net.with_endpoints
let with_public_web = Policy_net.with_public_web
let with_private_web = Policy_net.with_private_web
