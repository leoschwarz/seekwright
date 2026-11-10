(** The alias module dune generates for the wrapped [mcp-caps] library
    ([mcp_caps.ml-gen]), copied so these snippets can be type-checked against
    the library's interfaces with a plain [ocamlc].

    Keep this in step with [lib/caps]: a module missing here makes a snippet
    fail with [Unbound module], which is a loud failure, not a silent pass. *)

module Authority = Authority
module Budget = Budget
module Controls = Controls
module Error = Error
module Event = Event
module Policy = Policy
module Policy_fs = Policy_fs
module Policy_net = Policy_net
module Registry = Registry
module Server = Server
module Tool = Tool
