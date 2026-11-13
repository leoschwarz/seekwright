(** The target check every remote fallback runs before it spends a vendor.

    The oracle composes the same two guards in the same order inside every
    remote fallback class ([HttpFetcher.validate_url] + the SSRF pin, then
    [resolve_public] of the host): the syntax/scheme/length guard from
    {!Fetcher.validate_url}, then the public-address vet
    ({!Mcp_caps.Policy_net.vet_public_host}) that refuses loopback, private,
    link-local and multicast — always, even when
    [fetch.allow_private_addresses] is true, because it is the {i vendor}
    that would dial a private target and a deployment cannot audit what it
    does with that. The two sentences (the syntax one from
    [request_guard.validate_url], the address one from the vet) are the
    caller's, verbatim from the oracle.

    This module lives beside the fetch modules rather than in the factory so
    each fallback can guard its target with one call and no dependency on
    [Config]; the factory pins the grant's endpoint separately at build
    time. *)

(* [Eio.Net.t] is parameterised by the backend's resource tag, and a signature
   cannot existentially hide that tag any more than a record type can — the
   same reason [Policy_net] parameterises its confinement record. The
   parameter is never named by a caller: [make] fixes it from the network
   handed in. *)
type 'tag t = 'tag Eio.Net.t

val make : 'tag Eio.Net.t -> 'tag t
(** [make net] closes over the network the address vet queries. The check
    never opens a socket; [net] is only the name resolver. *)

val check : 'tag t -> string -> (string, string) result
(** [check t target]: [Ok target] when both guards pass, [Error sentence]
    otherwise. Each fallback turns the error into
    {!Fallback.Url_blocked} before it composes a request or touches a
    credential. *)
