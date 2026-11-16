---
name: comment-discipline
description: Load this when writing, reviewing, or trimming comments in this repo. It gives the wrong-edit (`.ml`) and wrong-call (`.mli`) tests, the comment classes that earn their space, where prose belongs instead, and the red flags to delete on sight. Read it before a comment pass over a module.
---

# Comment discipline

One rule, two forms:

- **`.ml`**: a comment earns its space only by preventing a wrong **edit** that
  the compiler, the tests and the names would let through.
- **`.mli`**: a comment earns its space only by preventing a wrong **call** that
  still type-checks.

Everything else is prose. Prose has owners: the code itself (a name, a type, an
assertion), the test, the `.mli`, `docs/`, or `plans/`. The implementation file
is not one of them.

This file is the operational form of `AGENTS.md`'s "a comment states a
constraint". When the two disagree, this file is the calibration.

## The three-question test (`.ml`)

Ask all three. Anything less than all three is a delete.

1. **Can you name the wrong edit?** "Someone changes X to Y, or deletes this
   guard, because the comment is absent." If you cannot name it, cut.
2. **Would something else catch it?** A type, an assert, a test name, a clearer
   identifier, the `.mli`. If yes, move it there and cut.
3. **Is the cost real?** Money, leaked content, a broken wire or journal
   contract, or a failure only production sees. If the only cost is a slower
   read, cut.

Borderline: delete. A surviving comment is a one-line tripwire, not an
explanation.

## What survives

- **Pins** — a field set, name or value that has to match another file, a suite,
  or the journal/wire contract. Name the enforcement site when one exists ("the
  suite pins it", "the journal contract").
- **Invariants the type cannot hold** — ordering, "never both", "at most once",
  "escaped once", "rebuilt per call".
- **Cost and security asymmetries** — paid-run-last, no dispatch on an
  unreadable selector, a page fetched and billed with its body withheld.
- **Deliberate oddities that look like bugs** — a field name that cannot be
  tidied, an alias, a `begin`/`match` shape.
- **Silent-failure traps** — an unreachable-looking branch that exists for
  tests, a guard that looks redundant.

A kept comment looks like this:

```ocaml
(* [error_name] and not [name]: a [name] field would collide with [fetcher.name]. *)
(* [None] is unbilled, not free: the journal then carries no [cost_usd]. *)
(* The walk continues past an empty page: the paid-run-last rule. *)
```

Form: one line, at the line of danger, naming the break and its cost. No
function-name restatement, no history, no paragraphs, no banners.

## The five slots (`.mli`)

Keep a sentence only if it changes what a caller does. The usable slots:

1. **Units and coordinates** — offsets index the full rendering, not the returned
   window; codepoints, not bytes.
2. **Failure semantics** — which variant, who acts, `Refused` = nothing billed /
   REST 400, `Failed` = 502.
3. **Side effects** — journal line, health board, billing.
4. **Non-obvious defaults and overrides** — a shared board, `~mode:Free` never
   escalates, `~auto_fallback` overrides config for one call.
5. **Sentinel and option meanings** — `None` is "no price to record", not
   "free"; `cap.Default` is *this fetcher's* cap.

Form: one line is the default, three the ceiling. The module header may be one
short paragraph of cross-cutting facts. One fact, one home. `.mli` `{1 …}`
sections are odoc navigation and are allowed; `.ml` banners are not.

## Where prose goes

| Comment | Destination |
|---|---|
| Restates a name, signature or obvious branch | delete |
| Section banners in `.ml` | delete |
| Python/oracle narration | the differential test or `docs/` |
| Design history, alternatives, review IDs, plan phases | `plans/` or git |
| Caller contract: units, errors, allowed values | `.mli`, once |
| A paragraph of rationale | `docs/`; code gets at most a one-line pointer |

## Red flags

- Starts with the enclosing function's name or restates its signature.
- "Ported from", "Python does", "in the Python tree".
- "style review M1", "F1.5", "§5", a date.
- "on purpose" or "deliberately" without the forbidden edit and its cost.
- Two or more sentences of explanation, or a paragraph in a `.ml`.
- A comment on a function with one call site, unless it names a hazard.

## Running a pass

1. `.ml` first: the strict test and the biggest win.
2. `.mli` second: wrong call, five slots.
3. Keep a short per-module log of judgement calls (kept, removed, why) so the
   owner can review them.
4. `dune build @install @doc` after; an unresolved `{!…}` warning shows a
   trimmed doc pointing nowhere.
5. Do not over-cut: the target is no prose, not no comments. A silent
   production failure is worth a line.

## Calibration

`lib/engine.ml` and `lib/engine.mli` are the worked examples: the `.ml` keeps the
cost and wire invariants and nothing else; the `.mli` keeps the units, error
mapping, pricing sentinels and defaults, and drops the layering, review and plan
prose.

The `ocaml` skill owns the toolchain; this one owns comment judgement. Docs never
cite a line — name the symbol.
