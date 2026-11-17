module Caps = Mcp_caps
module Authority = Caps.Authority
module Config = Seekwright.Config
module Engine = Seekwright.Engine
module Policy = Caps.Policy
module Provider = Seekwright.Provider

(* Collision guard: note keys matching fixed fields are prefixed with "note_". *)
let reserved_audit_fields = [ "operation"; "outcome"; "bytes" ]

let audit_fields (event : Caps.Event.t) : (string * Yojson.Safe.t) list =
  let note (key, value) =
    let key = if List.mem key reserved_audit_fields then "note_" ^ key else key in
    (key, `String value)
  in
  ("operation", `String (Caps.Event.operation event))
  :: ("outcome", `String (Caps.Event.outcome_to_string (Caps.Event.outcome event)))
  :: (match Caps.Event.bytes event with None -> [] | Some bytes -> [ ("bytes", `Int bytes) ])
  @ List.map note (Caps.Event.notes event)

let audit_sink (log : Engine.log) (event : Caps.Event.t) : unit =
  log Config.Log_info "caps.operation" (audit_fields event)

let with_audit ?audit grant =
  match audit with Some sink -> Authority.with_log ~sink grant | None -> grant

let grant_of_decision ~mono_clock ~timeout_seconds ?audit decision =
  with_audit ?audit
    (Authority.with_operation_timeout
       (Eio.Time.Timeout.seconds mono_clock timeout_seconds)
       (Authority.Net.of_confinement ~mono_clock decision))

(* The ceiling is the layer's own unless the caller names one, and the only caller
   that does is the CLI dialling its own server: a REST response is a projection of
   the operator's [fetch] caps, which the client process reads no config to know. *)
let grant_of_endpoint ~sw ~net ~mono_clock ~timeout_seconds
    ?(max_response_bytes = Policy.default_max_response_bytes) ?audit (endpoint : Policy.endpoint) =
  match Policy.with_endpoints ~sw ~net ~max_response_bytes [ endpoint ] with
  | Ok decision -> Ok (grant_of_decision ~mono_clock ~timeout_seconds ?audit decision)
  | Error error -> Error (Caps.Error.render error)

let probe_net ~sw ~net ~mono_clock ~timeout_seconds ?audit endpoints =
  match endpoints with
  | [] ->
      {
        Provider.Net.request =
          (fun _request ->
            Error (Caps.Error.make Caps.Error.Unavailable ~message:"no endpoints configured"));
      }
  | endpoints -> (
      match
        Policy.with_endpoints ~sw ~net ~max_response_bytes:Policy.default_max_response_bytes
          endpoints
      with
      | Ok decision ->
          Provider.Net.of_grant (grant_of_decision ~mono_clock ~timeout_seconds ?audit decision)
      | Error _ ->
          {
            Provider.Net.request =
              (fun _request ->
                Error (Caps.Error.make Caps.Error.Unavailable ~message:"no endpoints configured"));
          })

let fs_grant_of_written_root ~sw ~parent ~mono_clock ~max_bytes ~max_entries ?audit dir =
  match
    Policy.with_written_root ~sw ~max_read_bytes:max_bytes ~max_write_bytes:max_bytes ~max_entries
      ~parent dir
  with
  | Ok decision -> Ok (with_audit ?audit (Authority.Fs.of_confinement ~mono_clock decision))
  | Error error -> Error (Caps.Error.render error)
