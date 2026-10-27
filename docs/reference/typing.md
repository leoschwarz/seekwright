# Typing policy

One type checker runs over this tree: `ty`, pinned in the dev group, reading the
`[tool.ty.rules]` block in `pyproject.toml`. It has no config of its own. This
file is the rationale for that block, which exists to stay a short list of values
rather than a wall of prose.

## The baseline

The baseline is `ty`'s default rule set, narrower than the pyright fork it
replaced — see [what the old gate caught](#what-the-old-gate-caught) for the
checks that left the tree with it. The two rules turned back on below are
real and get fixed, not silenced. `ty` exits non-zero on warnings too, so
`missing-override-decorator` — raised from `ignore` to `warn` — is must-fix,
which is the point: `terminal.error-on-warning = false` is deliberately not
set.

## Turned on, and why

`ty` leaves both of these rules at `ignore`, so the block is what enables them.

- **`missing-type-argument = "error"`**. The four `ctx: Context` parameters in
  `server.py` carry an inline `# ty: ignore[missing-type-argument]` instead,
  because FastMCP detects the injected context parameter from the bare class at
  runtime — `Context` cannot be subscripted there even though it is generic.
  They are the only sites in the tree: `ty` does not read pyright's
  `# pyright: ignore[...]` pragma, and its `unused-ignore-comment` rule (on by
  default) flags a pragma that suppresses nothing, so a converted site that no
  longer needs the comment fails the gate rather than rotting.
- **`missing-override-decorator = "warn"`**. Real: an override gets `@override`.

## What the old gate caught

The gate ran `basedpyright` until 2026-10-26, with a `[tool.pyright]` block that
relaxed rules to `"none"`. `ty` has no rule for any of them; the classes they
covered are still in the code, so a checker that offers them again wants these
answers first:

- **The untyped-boundary family** (`reportAny`, `reportExplicitAny`, the
  `reportUnknown*` group, `reportMissingParameterType`) — `json.loads` returns
  `Any`, and the values crossing those boundaries are narrowed by hand, which is
  exactly what the code does. An annotation there would invent a type the data
  does not have.
- **`reportMissingTypeStubs`** — relaxed for a stubless dependency that has left
  the tree; nothing imports lxml any more.
- **`reportImplicitStringConcatenation`** — adjacent SQL string literals split
  for readability.
- **`reportUnusedCallResult`** — discarded `Cursor` results from best-effort
  writes.
- **`reportUnannotatedClassAttribute`** — attributes where the annotation would
  be a restatement.
- **`reportPrivateUsage`** — tests reach into privates on purpose; that is what
  pins the behaviour they assert.
- **`reportImportCycles`** — the lazy import in `__init__.py`, which exists so
  `import seekwright` stays cheap.
- **`reportUnusedParameter`** — interface-uniform parameters: an implementation
  of a protocol keeps the signature even where it ignores an argument.
- **`reportCallInDefaultInitializer`** — the `Field(default_factory=...)` idiom.

One check is lost outright rather than traded: **`reportUnnecessaryComparison`**
was at `"warning"` and real, and `ty` implements no rule for it. That, plus the
untyped-boundary family, is what dropping the pyright fork gives up — deliberately:
in the agent container a full `basedpyright` run did not finish in 600 s (its Node
process at ~2 GB RSS), while `ty` checked the same head in 0.489 s. The
measurements are in [the decisions log](../decisions.md).
