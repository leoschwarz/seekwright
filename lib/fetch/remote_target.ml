(* remote_target.mli states the composition; this file is the two calls in
   the order the oracle writes them, with the host taken from the URL
   [Fetcher.validate_url] just normalised. *)

(* [Eio.Net.t] is parameterised by the backend's resource tag, and a signature
   cannot existentially hide that tag any more than a record type can — the
   same reason [Policy_net] parameterises its confinement record. The check
   holds nothing but the resolver, so [t] is the network itself. *)
type 'tag t = 'tag Eio.Net.t

let make (net : 'tag Eio.Net.t) : 'tag t = net

let host_of url =
  (* [validate_url] has already refused the shapes whose host a parser could
     get wrong (embedded credentials, a bracketed netloc that does not close,
     an empty host), so the URI library's host — brackets and any port
     dropped — is the same hostname [urlsplit] hands the oracle. *)
  Uri.host (Uri.of_string url)

let check net raw =
  match Fetcher.validate_url raw with
  | Error message -> Error message
  | Ok target -> (
      (* The vet runs on every remote route whatever
         [fetch.allow_private_addresses] says: it is the vendor's egress that
         reaches the private network, and this deployment does not own what a
         vendor does with a target it is handed. *)
      match host_of target with
      | None -> Error "URL has no host"
      | Some host -> (
          match Mcp_caps.Policy_net.vet_public_host ~net ~host with
          | Ok () -> Ok target
          | Error error -> Error (Mcp_caps.Error.render error)))
