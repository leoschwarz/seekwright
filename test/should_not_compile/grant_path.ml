(* The positive counterpart: the grant path an application is meant to write,
   compiled by the same toolchain with the same interface mirror as the negative
   programs beside it. Sealing the raw operations is only half of F1.2 — if the
   seal were achieved by hiding something the intended path needs, this file is
   where that would show up as a compile failure.

   Nothing here names a private module: [Policy] hands back a confinement decision
   whose type is never written down, [Authority] turns it into a grant, and the
   grant's bounds are set by the three decorators, all of which take and return a
   grant. Compiled with [-c], so no loop and no socket: the claim is that this
   code type-checks for a consumer of the package. *)

(* A filesystem grant, read through, with every operation reported. *)
let read_under_root
    ~(env :
      < fs : Eio.Fs.dir_ty Eio.Path.t;
        mono_clock : [> Eio.Time.Mono.ty] Eio.Resource.t;
        .. >) ~sw ~name =
  let sink event = ignore (Mcp_caps.Event.render event) in
  match Mcp_caps.Policy.with_root ~sw ~parent:env#fs "src" with
  | Error error -> Error error
  | Ok decision ->
      let grant =
        Mcp_caps.Authority.with_log ~sink
          (Mcp_caps.Authority.Fs.of_confinement ~mono_clock:env#mono_clock decision)
      in
      Ok (Mcp_caps.Authority.Fs.read_file grant name, Mcp_caps.Authority.Fs.list_dir grant "")

(* The one endpoint this server may dial, read through, bounded from config and
   counted by a counter its caller owns. *)
let search_one_endpoint
    ~(env :
      < mono_clock : [> Eio.Time.Mono.ty] Eio.Resource.t;
        net : [> [> `Generic ] Eio.Net.ty] Eio.Resource.t;
        .. >) ~sw ~query =
  let endpoint =
    { Mcp_caps.Policy.scheme = `Https; host = "example.org"; port = None }
  in
  match
    Mcp_caps.Policy.with_endpoints ~sw ~net:env#net
      ~max_response_bytes:Mcp_caps.Policy.default_max_response_bytes [ endpoint ]
  with
  | Error error -> Error error
  | Ok decision ->
      let grant =
        Mcp_caps.Authority.with_operation_budget
          (Mcp_caps.Budget.make 4)
          (Mcp_caps.Authority.with_operation_timeout
             (Eio.Time.Timeout.seconds env#mono_clock 10.)
             (Mcp_caps.Authority.Net.of_confinement ~mono_clock:env#mono_clock decision))
      in
      Mcp_caps.Authority.Net.request grant
        {
          Mcp_caps.Authority.Net.meth = `GET;
          uri = Uri.of_string ("https://example.org/?q=" ^ query);
          headers = [ ("accept", "application/json") ];
          body = None;
        }
