(** The alias module dune generates for the wrapped [mcp-caps] library
    ([mcp_caps.ml-gen]), copied so these snippets can be type-checked against
    the library's interfaces with a plain [ocamlc].

    {b This mirror is the package's view, not the workspace's.} [lib/caps/dune]
    puts [policy_fs] and [controls_raw] in [private_modules], so [dune build
    @install] files their interfaces under [.private/] rather than where a
    consumer's search path reaches them: the error a consumer of the installed
    [mcp-caps] gets for either name is the alias resolving to a module it cannot
    see, which is a compile failure either way. The mirror drops the two aliases
    for the same reason, so a snippet that reaches for one fails here for the
    same reason it fails there — which is the guarantee
    [plans/ocaml-finalisation.md] F1.2 asks for.

    What the mirror does {e not} model: dune's generated alias module still
    re-exports private modules inside this workspace, so a stanza in [test/]
    could resolve [Mcp_caps.Policy_fs] — [private_modules] is not a workspace
    wall, and no dune field makes it one ([root_module] aliases {e dependency}
    libraries, not this library's own modules). Inside the checkout the seal is
    therefore a rule, and [test/test_caps_audit.ml] is the guard that keeps it:
    nothing under [lib/], [bin/] or [examples/] outside [lib/caps] may name
    [Policy_fs] or the bounds record. The bounds record is the second line of
    defence in both views: it has no interface file, so its type is what
    [ocamlc -i] infers here and what the package does not ship either.

    Keep this in step with [lib/caps]: a module missing here makes a snippet fail
    with [Unbound module], which is a loud failure, not a silent pass. *)

module Authority = Authority
module Budget = Budget
module Error = Error
module Event = Event
module Policy = Policy
module Policy_net = Policy_net
module Registry = Registry
module Server = Server
module Tool = Tool
