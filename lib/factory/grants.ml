(* The one place this library turns a confinement decision into a running grant,
   and the audit trail every such grant carries. Port of the construction of
   Python's per-adapter HTTP clients: where the oracle builds a client per
   provider, this builds one bounded, audited network grant per provider.

   [grant_of_decision] is the funnel for the network grants, and
   [fs_grant_of_written_root] the same funnel for the one filesystem grant the
   server runs — the page cache's written root. The section below them — the
   endpoint-scoped grant an adapter or the agent's model gets, and the union
   grant the readiness probes share — is every grant this library builds, which
   is why the audit decoration and each [of_confinement] appear here and nowhere
   else. *)

module Caps = Mcp_caps
module Authority = Caps.Authority
module Config = Seekwright.Config
module Engine = Seekwright.Engine
module Policy = Caps.Policy
module Provider = Seekwright.Provider


(* {1 The audit trail} *)

(* The field names the audit line owns. A note from an operation is written under
   its own key, except when that key would collide with one of these — the fixed
   fields are what the line's shape is pinned on, so a note never replaces one.
   [Event.add_note] already sanitises both halves and caps the list, so the line's
   length comes from the layer's field set, not from what a provider sent. *)
let reserved_audit_fields = [ "operation"; "outcome"; "bytes" ]

let audit_fields (event : Caps.Event.t) : (string * Yojson.Safe.t) list =
  let note (key, value) =
    let key =
      if List.mem key reserved_audit_fields then "note_" ^ key else key
    in
    (key, `String value)
  in
  ("operation", `String (Caps.Event.operation event))
  :: ("outcome", `String (Caps.Event.outcome_to_string (Caps.Event.outcome event)))
  :: (match Caps.Event.bytes event with
      | None -> []
      | Some bytes -> [ ("bytes", `Int bytes) ])
  @ List.map note (Caps.Event.notes event)

(* One line per authority operation, through the application's sink: stderr, never
   stdout, and a constant dotted event name with every value a named field, which
   is the rule the rest of the log follows. [Event.t] cannot carry a URL, a query,
   a header or a body — its payload is an operation name, an outcome, a byte count
   and bounded notes — so this is the whole of what a deployment learns about a
   grant's work, and it is what makes "which tool reached the network, and did it
   succeed" answerable from the log without a page in it. *)
let audit_sink (log : Engine.log) (event : Caps.Event.t) : unit =
  log Config.Log_info "caps.operation" (audit_fields event)

(* The one audit decoration in this library. Both funnels below — the endpoint
   grant a route runs on, and the written root the page cache runs on — pass
   through here, so the audit wrapper occurs once across [lib/factory] however
   many kinds of grant the factory learns to build, and a second funnel cannot
   arrive without the audit trail. [test/test_caps_audit.ml] counts that total
   over the whole library.

   An absent [?audit] is the [--check] diagnostic path, which probes a deployment
   without serving a request and so has no operation line to write; [build_app]
   always supplies it. *)
let with_audit ?audit grant =
  match audit with Some sink -> Authority.with_log ~sink grant | None -> grant

(* The one place this file turns a confinement decision into a serving grant: the
   config's per-operation bound, and the audit trail above. Every network grant
   the server runs on is built here, so [of_confinement] appears once in this file
   — a grant that forgets the audit trail is a compile error in review, not a
   forgotten line, and [test/test_caps_audit.ml] pins the count. *)
let grant_of_decision ~mono_clock ~timeout_seconds ?audit decision =
  with_audit ?audit
    (Authority.with_operation_timeout
       (Eio.Time.Timeout.seconds mono_clock timeout_seconds)
       (Authority.Net.of_confinement ~mono_clock decision))

(* One endpoint-scoped grant per adapter: the only network path a provider
   has. The operation bound is the config's, not the capability layer's
   default: [policy.provider_timeout_seconds] bounds a provider call,
   [fetch.timeout_seconds] a fetch, and [agent.model_timeout_seconds] the model
   request — the three keys Python feeds its clients.

   No [Authority.with_operation_budget] here, on purpose: a counter attached at
   startup is a server-lifetime budget wearing a request's name, which
   plans/capability-gated-mcp-server.md §6 refuses. A budget belongs to a caller
   that has a scope, and nothing in server construction has one. *)
let grant_of_endpoint ~sw ~net ~mono_clock ~timeout_seconds ?audit
    (endpoint : Policy.endpoint) =
  match
    Policy.with_endpoints ~sw ~net
      ~max_response_bytes:Policy.default_max_response_bytes
      [ endpoint ]
  with
  | Ok decision ->
      Ok (grant_of_decision ~mono_clock ~timeout_seconds ?audit decision)
  | Error error -> Error (Caps.Error.render error)

(* The network seam the readiness probes share: one grant over the union of the
   built vendors' endpoints. With no endpoint there is nothing to allow, so
   every request answers [Unavailable] instead of building an empty grant. *)
let probe_net ~sw ~net ~mono_clock ~timeout_seconds ?audit endpoints =
  match endpoints with
  | [] ->
      {
        Provider.Net.request =
          (fun _request ->
            Error
              (Caps.Error.make Caps.Error.Unavailable
                 ~message:"no endpoints configured"));
      }
  | endpoints -> (
      match
        Policy.with_endpoints ~sw ~net
          ~max_response_bytes:Policy.default_max_response_bytes endpoints
      with
      | Ok decision ->
          Provider.Net.of_grant
            (grant_of_decision ~mono_clock ~timeout_seconds ?audit decision)
      | Error _ ->
          {
            Provider.Net.request =
              (fun _request ->
                Error
                  (Caps.Error.make Caps.Error.Unavailable
                     ~message:"no endpoints configured"));
          })

(* {1 The one filesystem grant: the page cache's written root} *)

(* A directory this server writes into is as much an authority as an endpoint it
   dials, so the written root is minted here and nowhere else: the same
   [with_log] decoration every network grant carries, which is what makes
   "which tool touched the disk, and did it succeed" answerable from the same log
   line as the network answer. [Policy.with_written_root] opens the operator's
   directory, creating it (mode [0o700]) when it is absent, so a cache the config
   points at that this process cannot use is a construction failure naming the
   reason rather than a miss every day the server runs.

   One [max_bytes] figure for reads and writes because they are the same body: a
   page the cache may store has to be a page it can read back. The operation
   bound stays the layer's own default: [fetch.timeout_seconds] bounds a network
   read, and putting that number on a local file read borrows a vendor's latency
   budget for the host's own disk. *)
let fs_grant_of_written_root ~sw ~parent ~mono_clock ~max_bytes ~max_entries ?audit dir =
  match
    Policy.with_written_root ~sw ~max_read_bytes:max_bytes ~max_write_bytes:max_bytes
      ~max_entries ~parent dir
  with
  | Ok decision -> Ok (with_audit ?audit (Authority.Fs.of_confinement ~mono_clock decision))
  | Error error -> Error (Caps.Error.render error)
