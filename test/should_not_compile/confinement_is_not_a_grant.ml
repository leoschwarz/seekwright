(* A confinement decision is not a grant. [Policy.with_endpoints] answers the
   question "which destinations may this reach" — the same shape as
   [Policy.with_root] for the filesystem — and the grant a tool is registered
   with is the decision wrapped by [Authority.Net.of_confinement], which is also
   where the operation's time bound is put on it
   (plans/capability-gated-mcp-server.md §4, §5).

   Registering the decision directly is what must not compile: it would let a
   server wire a tool to a policy value that no [of_confinement] ever bounded.

   Expected: the grant argument's type is the grant, not the decision. *)

let search_web =
  Mcp_caps.Tool.make
    ~input_schema:(`Assoc [ ("type", `String "object") ])
    ~decode:(fun json -> Ok json)
    ~run:(fun grant _json ->
      let request =
        {
          Mcp_caps.Authority.Net.meth = `GET;
          uri = Uri.of_string "https://api.example.com/search";
          headers = [];
          body = None;
        }
      in
      match Mcp_caps.Authority.Net.request grant request with
      | Ok response -> Ok (Mcp_caps.Tool.Output.text response.body)
      | Error error -> Error error)
    "search_web"

let registry ~sw ~net =
  let decision =
    Mcp_caps.Policy.with_endpoints ~sw ~net ~max_response_bytes:4096
      [{ Mcp_caps.Policy.scheme = `Https; host = "api.example.com"; port = None }]
  in
  Mcp_caps.Registry.add Mcp_caps.Registry.empty search_web ~grant:decision
