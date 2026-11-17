let with_root = Policy_fs.with_root
let with_written_root = Policy_fs.with_written_root

let default_max_read_bytes = Policy_fs.default_max_read_bytes
let default_max_write_bytes = Policy_fs.default_max_write_bytes
let default_max_entries = Policy_fs.default_max_entries

type endpoint = Policy_net.endpoint = {
  scheme : [ `Http | `Https ];
  host : string;
  port : int option;
}

let endpoint_of_uri = Policy_net.endpoint_of_uri
let default_max_response_bytes = Policy_net.default_max_response_bytes
let max_configurable_response_bytes = Policy_net.max_configurable_response_bytes

type port_policy = Policy_net.port_policy = Default_ports | Any_port

let with_endpoints = Policy_net.with_endpoints
let with_public_web = Policy_net.with_public_web
let with_private_web = Policy_net.with_private_web
