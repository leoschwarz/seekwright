# OCaml style & architecture review — the seekwright port

**Branch:** `ocaml-style-review` · **Tree reviewed:** all OCaml — `lib/` (incl. `lib/caps/`, `lib/providers/`, `lib/fetch/`, `lib/factory/`), `bin/`, `test/` (incl. `test/should_not_compile/`, `test/conformance/`), `examples/`, `ocaml-tools/`, `dune-project`, every `dune`, the generated `*.opam`.
**Method:** `dune build` once (clean, exit 0, no warnings). No `dune runtest`, no live or network tests, no `dune promote`, no edits — the worktree is unchanged. OCaml 5.3.0, `(lang dune 3.11)`. 36,670 lines of OCaml: 17,928 in `lib/`, 16,954 in `test/`, ~1,800 in `bin/`, `examples/`, `ocaml-tools/`.
**Reader:** written for someone reading this codebase's first OCaml. Every finding quotes code that was re-read from disk while writing this, and says whether it is *wrong* or merely *different from what I would write*. Where the port's plans (`.agents/skills/ocaml/SKILL.md`, `plans/capability-gated-mcp-server.md`, `plans/seekwright-ocaml-port.md`, `plans/project-structure.md`) record a decision, that decision is contested as a **design question**, not reported as a bug.
**Counts:** 2 HIGH · 11 MEDIUM · 14 LOW/NIT = 27 findings. Findings already owned by the earlier review are listed at the end and not repeated.

---

## 1. Executive summary

This is an unusually good OCaml codebase, and the parts of it that are hard are the parts that are best. The `mcp-caps` layer is the exemplar of the tree: `Tool.t` is `('caps, 'input) t` abstract, `Authority.t` is `type _ t` with `fs`/`net` phantom kinds and `type nonrec t = fs t` in each submodule, and the layer's structural claims — that a tool cannot be registered without naming its grant, that a grant cannot be minted outside `Policy`, that a confinement *decision* is not a *grant* — are pinned by six programs in `test/should_not_compile/` that must **fail** to compile, each diffed against its expected full diagnostic. Most ports of Python services to OCaml get the types right and the build wrong; this one gets both mostly right. Library direction is stated in prose and enforced by rules (`ocamldep` diff in `test/dune`, the `surface.expected` golden), no library calls `Eio_main.run`, no file `open`s a library globally, and all 33 `lib/` interfaces open with an ocamldoc comment that explains *why*, not *what*.

The findings cluster into three themes, and one of them is a real crash:

1. **A primitive that Python gave you for free — codepoint-indexed strings — is re-implemented at least eight times here, with three different encodings of the same byte test, and one copy is wrong.** `Engine.take` is the only copy that does not clamp its final slice, so it raises `Invalid_argument "String.sub / Bytes.sub"` out of a module whose own docstring says failure is a returned value. That is the single HIGH headline, and the architecture around it (there is no owner for the walk, and the one real module, `Fetch.Utf8`, is unreachable from `lib/` because of the recorded library-direction rule) is the second.
2. **Facts the tree states three or six times in prose are not pinned by the build.** The log-sink arrow type is written out identically in three `.mli` files and three `.ml` files with a sentence at each claiming they are the same. The server flags' names live in one module and their parser in another with nothing between them. Six embedded oracle strings are byte-identical to `src/seekwright/resources/` today (I verified each with `diff`) and nothing keeps them so — while the same tree already runs six dune `diff` rules to pin other prose claims.
3. **Idioms are inconsistent where consistency is cheap.** Three dependency-injection shapes (`(module S)` + accessors, `S` + a record + `of_module`, plain record-of-functions), three spellings of `Result` bind, `String.starts_with` in `lib/` but hand-rolled prefix tests in `test/`, `bin/` and `ocaml-tools/`, twenty hand-rolled substring scanners across the test files with **two different argument orders**, and no `(env)` stanza anywhere, so the compiler's warning policy is ambient dune default rather than a pinned property of the project.

**What to praise specifically, and why:** the `caps` grant types and their negative-compilation pins; `Provider.Net.t` as a deliberate plain-record network seam ("the same position `httpx.MockTransport` holds in Python"), which is why every adapter suite asserts on a request instead of opening a socket; injected `~clock`/`~now` in `Engine`, `Health` and `Usage` so a test asserts an exact `ms` rather than a range; `test_core_no_mcp_kit.ml` deriving its module list from the directory and failing when the glob is empty, so a new sibling cannot pass by not being named; `model.mli` writing `(search_response, string) Stdlib.result` because the module defines a wire model literally called `result`; the per-operation `Eio.Switch.run` in `Policy_net`'s send, with the comment naming the two ways out of its body; `Config.section`'s "I recorded which keys I read, and the unread one is an error"; the defensive arms around `cohttp-eio`'s `failwith`; and `Log.sink`'s rule that a message is a constant dotted event name and every value is a named field, which is what makes the no-secrets rule checkable at all.

---

## 2. Findings

Verdict tags: **[wrong]** — I would fix this. **[different]** — works, but I would write it another way. **[design question]** — the plans or a module doc record a choice; this is the trade-off, not a defect.

---

### HIGH

#### H1. `Engine.take` raises `Invalid_argument` on a truncated trailing lead byte · `lib/engine.ml` · **[wrong]**

**Evidence.** `Engine.take` walks codepoints and then slices by bytes, without clamping the last step:

```ocaml
let take (limit : int) (text : string) : string =
  (* Python's [text[:limit]], which counts codepoints. [String.sub] counts bytes,
     and a byte slice can cut a character in half. *)
  let target = max limit 0 in
  let seen = ref 0 in
  let i = ref 0 in
  while !i < String.length text && !seen < target do
    i := !i + utf8_width text.[!i];
    incr seen
  done;
  String.sub text 0 !i
```

`utf8_width` classifies a lead byte by its value (`0xE0 ≤ c < 0xF0` → width 3), so for a string that *ends* mid-character the walk steps past the end. `take` has exactly one caller, `Engine.safe`, which is how it reaches the log field builders:

```ocaml
let safe ?(limit = 120) (value : string option) : string =
  py_repr (take limit (match value with None -> "" | Some text -> text))
```

Reproduced against a verbatim copy of the two functions (see the appendix): for `"a\xe2\x80"` — three bytes, two codepoints by the module's own count — `take 2` raises `Invalid_argument "String.sub / Bytes.sub"`.

Reachability is what makes this HIGH rather than a latent nit. `Engine.Search.resolve_or_reject` builds its refusal event with `safe`, ungated by any config flag:

```ocaml
        "search.rejected"
        [
          ("requested", `String (safe ~limit:40 requested))
```

`requested` is the caller-supplied `provider` string, and the wire model does not constrain it — `Model.search_request_of_yojson` runs `let* provider = opt_string "provider" kvs in`, with no membership test against `Config.known_providers`; the name is refused later, by `Router.resolve_search`, which is precisely the path that logs this line. The MCP tool declares `("provider", provider_enum)` so mcp-kit validates that door; the REST projection (`Server.api_search`) validates only through `Model`. `Model.check_length` counts codepoints and never validates well-formedness, so a body carrying a truncated lead byte reaches `safe`. Two more paths (`Engine.Search.log_content`'s `result_fields` over title/url/snippet/text, and the `fetch.content` block in `Engine.Fetch`) reach it from provider and page text, gated by `[logging] log_content`. `lib/engine.ml` contains two `try` forms, both for `Router.Route_refused`, so nothing turns this into a returned value; it leaves `Engine.Search.search` as an OCaml exception.

The other four copies of the same helper clamp — `lib/fetch/utf8.ml` (`let step = if !i + step > len then len - !i else step in`), `lib/provider.ml` (`let len = if !i + len > String.length s then String.length s - !i else len in`), `lib/agent.ml`'s `cp_take`, and `lib/model.ml`'s `utf8_length` (`i := min len (!i + 2)`). The clamping-free copy is the one on the search path.

**Impact.** A malformed byte sequence in an unknown provider name, a provider title, a snippet or page text raises out of a module documented as value-typed, on the path that is supposed to *report* a refusal.

**Direction.** Two edits, and do the second one: clamp in place (`i := !i + min (utf8_width text.[!i]) (String.length text - !i)`), then give the walk an owner so the clamp exists once (H2). If you keep a boundary check anywhere, put it where the string enters the process — `Model`'s string readers — so "is this text well-formed UTF-8" stops being each helper's problem.

**Learning note.** In OCaml, `String.t` is bytes and `String.sub` **raises** rather than truncating; there is no stdlib UTF-8 at all (no `String.length` in codepoints, no substring `contains`, no `Uutf` in the default set). Porting Python string code means porting Python's *leniency* too, because `s[:n]` in Python never fails on a truncated character — it slices codepoints and cannot land inside one. The tell that a port has lost this is an exception escaping a module whose docstring promises values: `lib/engine.ml` opens with "failure is a returned value rather than an exception", and `take` is the one line in the file that breaks that promise.

---

#### H2. The codepoint walk has no owner; `Fetch.Utf8` is the right module and is unreachable · `lib/engine.ml`, `lib/provider.ml`, `lib/agent.ml`, `lib/model.ml`, `lib/sanitize.ml`, `lib/caps/error.ml`, `lib/fetch/utf8.ml` · **[wrong]** (as architecture) / **[design question]** (about the constraint that forces it)

**Evidence.** The same primitive, eight times, in three encodings of the same test:

| Symbol | File | Shape |
|---|---|---|
| `Utf8.lead_len`, `Utf8.count`, `Utf8.of_string` | `lib/fetch/utf8.ml` | range test (`c < 0xc0`), clamps |
| `Engine.utf8_width`, `Engine.codepoints`, `Engine.take` | `lib/engine.ml` | range test, one copy does **not** clamp (H1) |
| `Provider.lead_len`, `Provider.codepoints`, `Provider.codepoint_count` | `lib/provider.ml` | range test, clamps |
| `Agent.cp_take` (+ its count loop) | `lib/agent.ml` | range test, clamps |
| `Model.utf8_length` | `lib/model.ml` | mask test (`c land 0xe0 = 0xc0`), `min len` |
| `Sanitize.next_index` | `lib/sanitize.ml` | mask test, `min len` |
| `Caps.Error.utf8_start` | `lib/caps/error.ml` | different algorithm: backs up from a continuation byte to its lead byte |
| byte↔codepoint mapping in `Extractors` | `lib/fetch/extractor.ml` | via `Utf8.of_string` |

Two of the "advance one codepoint" spellings differ in behaviour, not just style: the range form treats a stray continuation byte as width 1 (`else if c < 0xC0 then 1 (* a continuation byte: counted, never skipped *)`), the mask form only advances by a mask-matching width and falls through to 1 otherwise. Both are defensible; having both is not.

Whitespace sets have already diverged the same way. `Fetch.Utf8.is_python_space` carries the set Python's `str.strip()` actually uses:

```ocaml
let is_python_space cp =
  match cp with
  | 0x09 | 0x0a | 0x0b | 0x0c | 0x0d | 0x20 | 0x1c | 0x1d | 0x1e | 0x1f | 0x85
  | 0xa0 | 0x1680 | 0x2028 | 0x2029 | 0x202f | 0x205f | 0x3000 -> true
  | cp -> cp >= 0x2000 && cp <= 0x200a
```

`Agent.is_space`, `Provider.is_space` and `Engine.strip`'s nested `is_space` are three copies of one line — `match c with ' ' | '\t' | '\n' | '\r' | '\011' | '\012' -> true | _ -> false` — over the ASCII subset, over `char` rather than codepoint. `Provider.is_space` feeds the helper whose comment says it implements Python's `" ".join(text.split())`; `str.split()` uses the wide set. `Engine.strip` at least argues for its narrow set ("over the whitespace an extraction actually leaves behind"), which is a defence of one call site, not of the three copies. *Which* set is correct for `strip` is the earlier review's `Engine.strip` finding; what I am reporting is that the answer to that question is currently written down in four places, two coordinate systems, and no owner.

The one module that is a real home for this, `lib/fetch/utf8.ml` (+ `.mli`, the only one of the eight with a documented interface and the only one used by its neighbours — `Extractors` calls `Utf8.of_string`, `Utf8.count`, `Utf8.is_python_space`, `Utf8.ascii_lower`), cannot be reached from `lib/`: `lib/fetch/dune` gives `seekwright.fetch` the libraries `mcp-caps uri yojson` and `lib/dune` gives `seekwright` no dependency on it, so `Engine`, `Provider`, `Agent`, `Model` and `Sanitize` must each write their own. `lib/caps/error.ml` writes a ninth variant for the same reason.

**Impact.** H1. And the next one: a rule that exists in one copy is a rule the other copies do not have, and only the clamped copies have tests.

**Direction.** `seekwright.text` (or `seekwright.wire`) as its own stanza — `lib/text/` — linked by both `seekwright` and `seekwright.fetch`, holding the walk, `take`, `count`, the two whitespace sets under their Python names (`strip_space`, `split_space`), and the `py_repr` that `Engine`, `Provider` and `Agent` each want. This *preserves* the recorded rule ("nothing in `lib/` may name a fetch backend", `lib/dune`'s comment) because neither library gains a dependency on a backend. Alternative that is worse but cheaper: pick one file in `seekwright` and delete the other copies, accepting that `seekwright.fetch` re-implements the two helpers it needs. Do not "fix" this by adding `seekwright.fetch` to `lib/dune`'s libraries — that inverts a direction the dune comments and the plan both state.

**Learning note.** OCaml has no prelude for this, so *where a helper lives* is an API decision in OCaml in a way it is not in Python. The pattern to look for when reviewing: grep for the magic numbers (`0x80`, `0xc0`, `land 0xe0`) — if a constant that encodes a rule appears in more than one file, the files disagree the first time someone fixes one of them. And a duplicated helper is only interesting when the copies differ; two of these differ in behaviour today.

---

### MEDIUM

#### M1. The log-sink type is written out six times and named in three of them · `lib/engine.mli`, `lib/health.mli`, `lib/usage.mli` (+ the three `.ml` files), `lib/log.mli` · **[different]**

**Evidence.** Identical declaration in three interfaces (and, necessarily, in the three implementations):

```ocaml
type log =
  Config.log_level -> string -> (string * Yojson.Safe.t) list -> unit
```

Each copy carries its own prose pinning the equivalence: `engine.mli` — "The same sink type {!Usage} and {!Health} take, so P8 hands one function to all three"; `health.mli` — "The sink type is the one {!Usage} and {!Engine} take"; `usage.mli` — "The sink type, identical in shape to the one [Health] and [Engine] take". The module that *renders* the line, `Log`, takes the type from the engine: `val sink : t -> Engine.log` in `lib/log.mli`.

**Impact.** Because these are transparent aliases of an arrow type, they are interchangeable and nothing breaks today. The cost is the failure mode: add a parameter (say `?run` for the correlation id the usage journal already carries) and you edit six declarations plus three doc comments, and `Server`'s single wiring call reports the mismatch in a place far from the cause. Naming the type `Log.log` also puts a general concern inside the port's largest module (`lib/engine.ml`, 1378 lines), so `Engine` cannot be read without learning that it owns the logging vocabulary too.

**Direction.** Declare it once — `lib/log.mli` is the natural owner, since `Config.log_level` is already its vocabulary — and write `type log = Log.log` in the three interfaces, keeping one explanatory comment. If `Log` must stay a leaf, put the alias in `Config` next to `log_level`/`log_format`, which it already defines.

**Learning note.** In OCaml, "identical in shape" is not a fact the compiler checks for you across modules *when it is a documentation claim*; it is only a fact while nobody edits one alias. Repeating a type alias is the duplicated-contract smell exactly like repeating a record (M5): write it once, name it everywhere else. A cheap pin if you want one: a one-line test asserting `Engine.quiet : Usage.log` and `Log.sink (Log.make c) : Health.log` compiles — that is a type-level assertion, which costs nothing and fails at build time, not at the wiring site.

#### M2. The test tree has no support library, so its helpers are re-typed 20 times with two argument orders · `test/*.ml` · **[wrong]** (the argument-order half) / **[different]** (the duplication)

**Evidence.** There are 30 test executables and no shared test library stanza in `test/dune`. Each file re-implements substring search:

```
test/test_anysearch.ml        let contains text needle =
test/test_authority_fs.ml     let contains text needle =
test/test_authority_net.ml    let contains text needle =
test/test_config.ml           let contains needle haystack = find_index needle haystack <> None
test/test_core_no_mcp_kit.ml  let contains text needle =
test/test_fetch.ml            let contains_substring hay needle =
test/test_fetch_http.ml       let contains_substring hay needle =
test/test_freeserp.ml         let contains text needle =
test/test_grant_wiring.ml     let contains text needle =
test/test_http_transport.ml   let contains text needle =
test/test_jsondoc.ml          let contains_substring hay needle = find_at hay needle <> None
test/test_p8_server.ml        let contains text needle =
test/test_provider.ml         let contains text needle =
test/test_router.ml           let contains text needle =
test/test_server.ml           let contains text needle =
test/test_tabledoc.ml         contains_substring … find_at …
```

plus `find_index` (`test_config.ml`), `find_at` (`test_jsondoc.ml`, `test_tabledoc.ml`), `starts_with` (`test_grant_wiring.ml`), and `test_engine.ml`/`test_fetch_engine.ml`'s `is_prefix`/`is_suffix`:

```ocaml
let is_prefix prefix text =
  (* [String.prefix] and [String.is_suffix] are not in this stdlib; the two
     helpers are the prefix test the walk-coverage case needs. *)
  let length = String.length prefix in
  String.length text >= length && String.sub text 0 length = prefix
```

Two points of fact. First, the comment is right about those names — OCaml 5.3 has no `String.prefix`/`String.is_suffix`, `String.contains` takes a `char`, and `String.index_opt` takes a `char`: there is genuinely no stdlib substring search, so a helper is legitimate. Second, `lib/` already uses the functions that *do* exist: `String.starts_with ~prefix:` in `lib/fetch/fetcher.ml` and `lib/fetch/jsondoc.ml`, `String.ends_with ~suffix:` in `lib/fetch/extractors/stdlib.ml`. So `is_prefix`/`is_suffix` are not filling a gap. And `test_config.ml`'s `contains needle haystack` is the mirror image of the other fifteen `contains text needle`: both arguments are `string`, so swapping them compiles and silently changes the assertion. The file also duplicates the sandbox-read helper (`read path`, with its "missing from the test sandbox (test/dune declares it)" message) in `test_config.ml` and `test_core_no_mcp_kit.ml`.

**Impact.** Mostly maintenance. One real hazard: the reversed parameter pair, which no type error will catch.

**Direction.** One stanza in `test/dune`, a `test/support/` library (say `seekwright_test_support`) exporting `contains`, `starts_with`, `ends_with`, `read_file`, `check_string` and the alcotest aliases the files each redefine (`let check_int = A.(check int)` and friends), and delete the copies. Decide the argument order once — `contains ~haystack ~needle` makes the reversal impossible.

**Learning note.** "Every test file is self-contained" reads as a virtue until the day you want to change an assertion helper across the suite. OCaml makes a shared test library one extra stanza; there is no reason not to. And the general review question here is not "is there a helper?" but "does every copy of this helper take its arguments in the same order, and are they distinguishable types?" Two `string`s is the classic pair that can't be.

#### M3. `<> None` followed by `Option.get` — four sites where the type checker is being asked to trust a comment · `lib/engine.ml`, `lib/agent.ml`, `lib/fetch/jsondoc.ml` · **[different]**

**Evidence.**

```ocaml
      if page.image <> None
      then Ok (finish_image t ~url page (Option.get page.image) ~fallback base ~started !notices ~run)
```
(`Engine.Fetch.serve`.) `Agent.answer`, twice:

```ocaml
    if responses = [] && !first_failure <> None then
      Error (Agent_failed (Option.get !first_failure))
```
```ocaml
           (match List.find_opt (fun (r : Model.search_response) -> r.Model.notice <> None) responses with
           | Some r -> Option.get r.Model.notice
           | None -> "No results were returned for this question; retry or rephrase."))
```
and `Jsondoc`, which also computes the same parse twice:

```ocaml
      | Some i when python_int (String.sub rest 0 i) <> None -> (
          let size = Option.get (python_int (String.sub rest 0 i)) in
```

**Impact.** None today — each is guarded. The cost is review burden and edit risk: a reader must connect the test to the force, and the second `Agent` site is a `filter`+`map` expressed as `find_opt`+`get` where the compiler could have done it. The `Jsondoc` guard evaluates `python_int` on the same slice twice and re-slices it a third time.

**Direction.** `match page.image with Some kind -> … | None -> …` at the first; `Option.value ~default:…` or a `ref` of `string` with an explicit flag at the second; `List.find_map (fun r -> r.Model.notice) responses` for the third (one call, no force); and bind the parse in the guard — OCaml's `when` clause cannot bind, so either restructure to `match python_int … with Some size -> … | None -> …` inside, or use a `let rec` helper.

**Learning note.** `Option.get` is the OCaml equivalent of an unchecked cast: legal, total-looking, and it raises `Option.Not_found` on the input you didn't think about. The idiom that keeps totality is *destructuring in the place where the value appears* (`match`, `Option.map`, `Option.value ~default`, `List.find_map`, `Option.filter_map`). When you see `x <> None` and `Option.get x` in the same function, that is a match written as two statements. `lib/agent.ml`'s first site is a `ref` + a flag, which is the mutation-shaped version of the same thing: prefer `ref (Agent_failed "" : failure)` plus a boolean, or an option-ref with `match` — then no force exists.

#### M4. `Jsondoc.normalize`/`dedupe` are quadratic on the parse path, in a file whose walk is written with a measured number in its comment · `lib/fetch/jsondoc.ml` · **[wrong]**

**Evidence.**

```ocaml
  and dedupe kvs =
    List.fold_left
      (fun acc (k, v) ->
        if List.mem_assoc k acc then
          List.map (fun (k', v') -> if k' = k then (k, v) else (k', v')) acc
        else acc @ [ (k, v) ])
      [] kvs
```

Per member of every object: a linear `mem_assoc` scan, an append that copies the accumulator, and on a duplicate a full rebuild. That runs inside `parse_one`, which every `path`, `structure` and rendered-document read calls. Fifteen lines below it, the same file explains its own cost discipline:

```ocaml
(* One step of the walk's stack. A container comes back as a [Frame] over its
   unread members rather than as one entry per member, so what the walk holds
   is one entry per level it is inside — the rendering's own budget bounds the
   walk with it. An eager walk of a wide container cost a stack entry and a
   path string per member before any of them were printed — 2.3 GB for one
   8 MB page, measured at the Python tree. *)
```

**Impact.** An object with tens of thousands of keys — the exact shape `render_json`'s budget exists for — makes `normalize` quadratic before rendering starts. `max_download_bytes` caps the bytes, not the key count, so a small body of thin `{"k":1}` pairs is the worst input.

**Direction.** One pass with a `Hashtbl string int` of positions plus an array of values: first occurrence fixes the index, later ones overwrite the slot, then rebuild in index order — that preserves the stated semantic ("duplicate keys keep the first position and the last value") in linear time. `List.rev` accumulation instead of `acc @ [..]` alone removes the append copy but not the scan.

**Learning note.** OCaml lists make "build a list by appending" look free and make it quadratic; the idiom is accumulate-then-`List.rev`. But the sharper lesson is a review heuristic: when one function in a file cites a measured cost and its neighbour does not, ask which one the file is right about. Here the author clearly knew the cost of a walk — the omission is that `normalize` is a second walk.

#### M5. Two identical records and a hand-written copier across a library boundary, while the tree already knows the alias that avoids it · `lib/engine.mli` · `Engine.Fetch.page`/`Engine.Fetch.image`; `lib/fetch/fetcher.mli` · `Fetcher.fetched_page`/`Fetcher.fetched_image`; `lib/factory/factory.ml` · `page_of` · **[design question]**

**Evidence.** `Engine.Fetch.page` and `Fetcher.fetched_page` are field-for-field the same (`url`, `title`, `text`, `content_type`, `status_code`, `truncated`, `total_chars`, `path_addressable`, `image`), as are the two image records, and `Engine.Fetch.image`'s doc comment says so itself ("[fetcher.FetchedPage]: one fetched and extracted page, before response metadata is attached"). The bridge is `lib/factory/factory.ml`:

```ocaml
let page_of (page : Fetcher.fetched_page) : Engine.Fetch.page =
  {
    Engine.Fetch.url = page.Fetcher.url;
    title = page.Fetcher.title;
    text = page.Fetcher.text;
    ...
```

Nine qualified fields, plus a nested copy for `image`. Meanwhile `lib/caps/policy.mli` and `lib/caps/policy.ml` carry the pattern that removes this entirely:

```ocaml
type endpoint = Policy_net.endpoint = {
```

an *equated* alias: one record type, two names, the fields visible in both interfaces, no conversion function. (`Factory.error_of`, by contrast, is a genuine translation — `Fetcher.Blocked` → `Engine.Fetch.Fetch_blocked`, `Fetcher.Failed` → wrapping into a provider error — and should stay.)

**Impact.** Any field added to a page must be added three times (two records, one copier), and a field added to one and not the other compiles fine because `page_of` writes the second by hand.

**Direction.** Not "import it": `lib/dune`'s comment states the direction (`nothing in [lib/] may name a fetch backend`), and adding `seekwright.fetch` to `seekwright` breaks it. The fix is the same shared-type library H2 argues for: put `page`, `image` and `fetch_error` in `seekwright.wire` (or fold them into the `seekwright.text`-style helper library), have both libraries link it, and use the equated alias in whichever interface wants a local name. `page_of` and the image copy then delete themselves.

**Learning note.** "Two records with the same fields and a function between them" is the OCaml-specific signal for a type that wants to be shared. Read `page_of`'s body: if every field is `Module.field` with no logic, the copier is ceremony. `type x = Other.x = { … }` is the tool for "same type, two vocabularies"; `type x = Other.x` is the tool for "same type, one vocabulary". Both are used correctly in `lib/caps/`; `Engine.Fetch`/`Fetcher` need them.

#### M6. The server-flag vocabulary has no single source · `lib/server.ml` · `Server.server_flags`; `bin/main.ml` · `parse_server_flags`/`server_opts` · **[wrong]** (as a guard gap)

**Evidence.** The frozen manifest prints flags from a list in the library — `Server.server_flags` — which `ocaml-tools/surface.ml` renders and `surface.expected` pins. The flags themselves are string-matched in `bin/main.ml`:

```ocaml
    | "--check" :: rest -> go { opts with check = true } flags rest
    | "--live" :: rest -> go { opts with live = true } flags rest
    ...
    | ("--host" | "--port" | "--allowed-host" | "--log-level" | "--log-format") as flag
      :: rest -> (
```

and the parsed shape is a third list — the `server_opts` record — whose fields are then filled by name lookup out of the collected assoc list (`let value flag = List.assoc_opt flag flags in`, `opts with host = value "--host"`, and for repeats, `List.concat_map (fun (flag, v) -> if flag = "--allowed-host" then [ v ] else []) flags` — which is `List.filter_map` written as a fold). Nothing compares `Server.server_flags` to the scanner, and `bin/` has no test suite (a gap the earlier review records; the point here is the *mechanism*).

**Impact.** Rename a flag in `bin/main.ml` and the manifest keeps advertising the old name — the manifest is the thing the 0.1.0 freeze promises, and this is the one frozen table whose producer is unguarded. (The config-key half of the same manifest *is* guarded, and verified correct — see "Checked and clean".)

**Direction.** Either derive: expose the flag table as data in `Server` (name, arity, whether it repeats) and have `main.ml` drive its scanner off that table and `server_flags` be `List.map fst` of it; or pin: one test that reads `bin/main.ml` (the tree already reads source text with `deps`-declared globs in `test_provider.ml` and `test_core_no_mcp_kit.ml`) and asserts the two name sets are equal. Deriving is better and makes the third copy — `server_opts` — the only one left.

**Learning note.** A frozen surface wants to be *one* value that several consumers read. When the same vocabulary is written as a list in one module, a pattern-match in another and a record in a third, the OCaml way to make the agreement structural is to put the table where the schema lives and generate the rest. Ask of any manifest-like list in a review: which code reads it, and is that the same code that must honour it?

#### M7. One HTTP refusal spelled twice, once as hand-counted bytes, and a hand-rolled header parse where `Http_headers` is linked · `lib/server.ml` · `custom_handler`, `serve_http` · **[wrong]** (the length literal) / **[different]** (the rest)

**Evidence.** Inside the custom-route handler:

```ocaml
    if path <> "/healthz" && not host_ok then
      text_response 421 "Invalid Host header"
    else if path <> "/healthz" && not origin_ok then
      text_response 403 "Invalid Origin header"
```

In the transport-level route, the same refusal written as bytes:

```ocaml
      if path <> "/healthz" && not host_ok then
        Eio.Buf_write.string oc
          ("HTTP/1.1 421 Misdirected Request\r\ncontent-type: text/plain\r\ncontent-length: 19\r\nconnection: close\r\n\r\nInvalid Host header")
```

The position is legitimate — below that point the code is talking to `Cohttp_eio.Server.callback` through a `Buf_read`/`Buf_write` pair over a tapped socket, so it must write an HTTP framing itself, and the peek/`Tap`/`Replay` machinery around it is careful and well-commented. The `content-length: 19` is not: it is the byte count of a message that appears twenty lines away, and if the sentence changes, the response is a protocol lie (truncated body or a client waiting for bytes). The same file's header extraction is also hand-rolled while `http` is a linked dependency and `Http_headers.of_string` is used elsewhere in it:

```ocaml
            let lower = String.lowercase_ascii line in
            if String.length lower > 5 && String.sub lower 0 5 = "host:" then
              Some (String.trim (String.sub line 5 (String.length line - 5)))
```

and the guard condition `path <> "/healthz" && not host_ok` is written identically in both layers.

**Impact.** A silent wire bug on message edit; a reader has to check the arithmetic to believe the code. The duplicated guard is a drift risk for the `/healthz` exemption rule (`AGENTS.md`: `/healthz` is outside the Host allowlist and must stay secret-free).

**Direction.** A tiny local `write_text_response oc status body` that computes `string_of_int (String.length body)`; `Http_headers.of_string (String.concat "\r\n" headers @ "\r\n")` then `Http_headers.get "host" headers` for the parse (the `http` package is already in `lib/dune`); hoist the `host_ok` decision into one `host_gate path headers` used by both layers.

**Learning note.** Two reviewable tells in OCaml HTTP plumbing: a length or offset that a human computed, and a prefix test done with `String.sub` (`String.length lower > 5 && String.sub lower 0 5 = "host:"` — `String.starts_with ~prefix:"host:" lower` says it and cannot be off by one). Hand-written framing is sometimes forced by position, as it is here; when it is, the values inside it should still be computed.

#### M8. Six embedded oracle strings are byte-identical today and nothing pins them · `lib/prompts.ml`, `lib/agent.ml` · `answer_system_prompt`, `lib/dashboard_html.ml` · `dashboard_html` · **[design question]**

**Evidence.** `lib/prompts.ml` states the arrangement — "this port has no package-data directory, so the same bytes are embedded verbatim in quoted literals here (generated from the resource files, byte for byte, trailing newline included where the file has one)". I verified the claim: `server_instructions`, `search_description`, `fetch_description`, `answer_description`, `Agent.answer_system_prompt` and `Dashboard_html.dashboard_html` (1,204 lines, one `{|…|}` literal wrapping the whole page) diff **identical** against `src/seekwright/resources/`. Nothing keeps them that way. The tree pins comparably brittle prose everywhere else: `surface.expected`, the `py_body.out`/`our_body.out` pair against `docs/reference/surface.md`, `router_dependencies.expected`, six `should_not_compile/*.expected` diagnostics, and `test_config.ml` which *loads* `docs/reference/configuration.md` and `deploying.md` as `test/dune` `(deps)` so "a renamed key fails here instead of at an operator's first start".

**Impact.** The Python tree is the read-only differential oracle for this port and its `resources/` files are the model-facing contract (tool descriptions are what a client model reads). A drift in either direction is invisible until someone notices the two deployments phrase the same rule differently — and `Prompts` has no test suite at all.

**Direction.** Pick one and say why. (a) Pin: a `(rule)`/`(test)` pair with `(deps ../src/seekwright/resources/*.txt)` that diffs the literals against the files — this matches the tree's own idiom and fails loudly. (b) Freeze deliberately: write in the module comment that the port's texts are now its own and may diverge, and delete the "byte for byte" claim, which otherwise promises a guarantee nothing enforces. I would choose (a) for the four descriptions and `answer_system.txt` (they are the agent-facing contract) and (b) for `dashboard.html` (a generated asset nobody hand-edits from both sides).

**Learning note.** OCaml has no package-data convention, so embedding is normal; what matters is whether an embedded copy of an external document is *pinned* or *forked*. When you find a literal comment saying "generated from X", ask which build step re-runs that generation — if the answer is "a human did it once", the file is a fork with a comment claiming it is a copy. `test/dune`'s `(deps …)` lines are the tool for this, and this repo already uses them.

#### M9. The suite map has named holes · `test/dune`, `lib/` · **[different]** (and partly held by the earlier review)

**Evidence.** Thirty suites cover most modules. No test file names `Factory`, `Utf8`, `Log`, `Prompts`, `Controls`, `Budget`, or `Dashboard_html`:

```
Factory          (no suite)
Utf8             (no suite)
Log\.            (no suite)
Prompts          (no suite)
Controls         (no suite)
Budget           test/test_authority_net.ml
Dashboard_html   (no suite)
```

`Caps.Budget` is exercised indirectly through the net-authority suite; the others are reached, if at all, only through `Server`/`Engine` suites that build their own stubs rather than the real construction layer. The consequence for `Factory` is the shape layer (`page_of`, `cap_of`, `error_of`, the `readers` packing) — M5 — sitting untested between two record types that can drift apart. (The behavioural "factory drops names it cannot build" problem is the earlier review's finding; I am only reporting the map.)

**Direction.** Cheapest first: `Utf8` (pure, one module, the clamping rule at issue in H1 deserves a test on the copy that clamps), `Factory`'s shape conversions (pure, no loop needed for `page_of`/`cap_of`/`error_of`), and `Prompts`/`Dashboard_html` length-and-shape pins, which double as the M8 guard.

**Learning note.** In a per-module test tree like this one, `ls test` against `find lib -name '*.mli'` is a two-minute coverage review. It finds gaps by *name*, which is exactly the level at which this repo organises both its code and its guards.

#### M10. Nothing in the build pins the warning policy · `dune-project`, all `dune` files · **[different]**

**Evidence.** `grep -rn "(env" --include=dune --include=dune-project .` returns nothing: there is no root `dune`, no `(env)` stanza, no `(flags)`, no `warn-error`, no `-strict-sequence`/`-strict-formats`. The build is clean today because the code is careful and because dune's default set covers the obvious ones (unused variables are why `Config.api_key (_config : t)` and `Engine.Fetch.read_page (_t : t)` are written as they are). Compare the effort spent elsewhere: three AST/text guards that parse the tree (`test_provider.ml`'s source discipline, `test_core_no_mcp_kit.ml`, `should_not_compile`'s `ocamlfind ocamlc` with `with-accepted-exit-codes`), and an `ocamldep` diff rule pinning one module's imports.

**Impact.** A new module added to the tree inherits an unpinned warning set from whoever's dune profile is in use; a warning that appears in a PR is advisory, not a gate, and `:standard` is not recorded anywhere.

**Direction.** One root `dune` with `(env (_ (flags :standard -w …)))` — the list chosen once, `+8`/`+26`/`+27`/`+69`/`+70` as the project decides, and `(dev (flags (:standard -w +a-4..9-42-44-45-52-70 -warn-error +a)))` or the narrower set the team can actually live with. Whatever is chosen, it becomes a reviewed value in the tree instead of an ambient default. Note this interacts with M2: a support library for tests would also inherit it.

**Learning note.** OCaml's compiler is the cheapest guard you own, and its verbosity is *configurable per project* — which means "clean build" is only a claim if the flags are in the repo. Also worth knowing as a reader: `_`-prefixed parameters and `_name` bindings are how this codebase satisfies unused-variable warnings, so their presence is evidence about the warning set in force, and a `_` prefix is a question worth asking (see L6).

#### M11. What may raise is written nowhere, and one name is both an exception and a variant constructor · `lib/fetch/fetcher.mli` · `Url_blocked`, `validate_url`, `validate_url_opt`, `refusal`; and `Router.Route_refused` · **[design question]**

**Evidence.** `Fetcher`'s interface carries both:

```ocaml
type refusal =
  | Url_blocked of string
  …
exception Url_blocked of string
(** [validate_url] raises this: a scheme, credential, host or port refusal of
the URL as written. *)

val validate_url : string -> string
```

and beside them, in the implementation, the non-raising twin with its own comment ("[validate_url] without the exception: the fetch chain turns a hop-0 refusal…"). Six exception types exist in `lib/`: `Fetcher.Url_blocked`, `Extractor.Extraction_failed`, `Jsondoc.Path_syntax`, `Tabledoc.No_rows`, `Policy_net.Refusal`, `Router.Route_refused`. Elsewhere the stated rule is the opposite: `Config`'s interface says failure is "not an exception: the CLI (P8) prints it and exits 1 where Python raises [SystemExit]", `Agent`'s says "Failure is a returned value, as in the rest of the port", and `Engine`'s module docstring repeats it. The two places the exception *is* converted are `Engine.Search.resolve` and `Engine.Fetch.resolve`:

```ocaml
    try Ok (Router.resolve_search (table t) ?mode requested)
    with Router.Route_refused sentence -> Error sentence
```

**Impact.** A reader of `Fetcher` must know which of two similarly named functions raises, and must not confuse `Url_blocked` in a `match` on a result with `Url_blocked` in a `with` clause — legal, unambiguous to the compiler, and a real reading trap. And "six exceptions exist, the docs say values" leaves a newcomer unable to tell which of the two they are looking at until they find the `try`.

**Direction.** Rename the exception (`Url_blocked_exn`, or make it `Bad_url` — the constructor name is the variant's, not the exception's right) *or* drop `validate_url` in favour of the result form at its remaining call sites. Then state the rule once — a paragraph in `docs/` or in `lib/provider.mli`'s/`lib/fetch/fetcher.mli`'s headers — of the shape: exceptions are for the pure grammars (`Path_syntax`, `No_rows`, `Route_refused`) and for unwinding deep inside an Eio body (`Policy_net.Refusal`); every boundary that a caller can act on returns a value, and the conversion point is `Engine.*.resolve`. `Config.default`'s `failwith ("Config.default: " ^ fault)` and `Server.addr_of_host`'s `failwith ("seekwright: cannot resolve bind address " ^ host)` are both at startup edges and belong on the allowed side of that line — but writing the line is what makes them obviously allowed rather than accidentally so.

**Learning note.** OCaml gives you two sum types that look identical in patterns — variants and exceptions — and only one of them is tracked by the type of a function. A codebase with a value-typed error convention should be able to answer "which exceptions cross this boundary?" from a grep: `grep -n '^exception ' lib/**/*.mli`. Six hits and a stated rule is a healthy answer; six hits and no rule is what an OCaml reviewer flags first, because the exceptions are where your `result` types stop covering you.

---

### LOW / NIT

#### L1. `Config.name` documented as "A provider name" is also the type of a file path · `lib/config.mli` · `name`, `config_path`, `load` · **[wrong]** (as interface prose) 

```ocaml
(** A provider name: [backend] or [backend:flavour] ([exa], [exa:free]). … *)
type name = string
…
val config_path : name option -> string
(** [path], else [$SEEKWRIGHT_CONFIG], else {!default_config_path}; … *)
val load : name option -> (t, string) result
```

Both are `string`, so nothing breaks; reading `load : name option` in the interface, a newcomer reads "load a provider name". Fix: `val config_path : string option -> string` (or a separate `type path = string` if you want the alias to mean something). `Config.name` is used correctly and usefully elsewhere (`Agent.answer`'s `?provider:Config.name`). **Learning note:** a type alias is documentation that the compiler enforces only against *other aliases*, so an alias whose meaning shifts by call site is worse than `string`.

#### L2. `surface.ml`'s config-key scan is a hand-rolled line parser with unstated layout assumptions · `ocaml-tools/surface.ml` · `record_fields`, `read_config_keys` · **[different]**

`record_fields` finds `type X = {` at column 0, then takes the name before the first `:` on each line, skipping lines starting `(*`, and stops at a line whose first char is `}`. It is correct today — I diffed its output against the interface for all eight records (70 keys) and it matches exactly — and the output is pinned by the `surface.expected` golden, which is what makes the risk contained. But the assumptions are not in the comment: an indented `}`, or `}` followed by `)`, and the scan walks silently into the *next* record. Three more nits in the same file: prefix tests written as `String.sub line 0 5 = "type "` and `String.sub trimmed 0 2 = "(*"` where the rest of the tree uses `String.starts_with`; the identical recursive trailing-blank `strip` is defined twice, once inside `render_body` and once in a pipeline in `render_journal`; and `count_lines` returns a **ten-component tuple of ints**, destructured positionally in two places with different names for the last component (`top_level_count` vs `_top`) — swap two of them and the compiler is silent while the manifest prints wrong counts. `render_body`/`render_full` also build output with `lines @ [..] @ List.map ..` inside folds (fine at this size, see L3). **Direction:** one small record for the counts; state the layout assumptions in the comment; `String.starts_with`; one `strip` at module level. **Learning note:** tuples wider than ~3, or whose components share a type, are records wearing a hat — and a hand-written scanner is fine when a golden pins it, provided the comment says what the scanner assumes.

#### L3. The append-at-end habit, in places where `n` is bounded and places where it is not · `lib/engine.ml`, `bin/main.ml`, `lib/caps/registry.ml`, `lib/caps/server.ml`, `lib/usage.ml`, `lib/model.ml`, `ocaml-tools/surface.ml` · **[different]**

`lines := !lines @ [ Printf.sprintf … ]` in `main.ml`'s `check`, `t.states <- t.states @ [(name, created)]` in `Health.ensure`, `:= !x @ [y]` and fold `acc @ [x]` at roughly a dozen sites. With at most seventeen provider names this is style, not cost, and it mirrors the Python it ports. It stops being style where the list grows with input: `Jsondoc.dedupe` (M4) and the passage/line accumulators. **Direction:** accumulate then `List.rev` (the tree does this well in `Provider.codepoints` — `acc := String.sub s !i len :: !acc; … Array.of_list (List.rev !acc)`), or a `Buffer` for text. **Learning note:** `l @ [x]` is O(n) on lists; the reviewer's question is never "is this list long?" but "does this list's length come from a caller, a page, or a config ceiling?"

#### L4. Three spellings of the same `Result` bind, and two modules that use none of them · `lib/config.ml`, `lib/factory/factory.ml`, `lib/model.ml`, `lib/caps/policy_net.ml`, `lib/caps/policy_fs.ml`, `lib/server.ml` · **[different]**

Module-level `let ( let* ) = Result.bind` (config.ml, factory.ml, model.ml — 87 and 137 uses) vs. a per-function `let ( let* ) = Result.bind in` shadow, nine times inside `lib/caps/policy_net.ml` and three in `policy_fs.ml`, vs. `let ( >>= ) = Result.bind` at the top of `lib/server.ml` and `lib/caps/server.ml`. And `Server.api_search`/`api_fetch`/`api_answer` use none: four nested `match`es with the paren-drift convention, e.g. `match parse_json_body body with | Error m -> error_response 400 m | Ok json -> ( match Model.search_request_of_yojson json with … )`. All of it is legal and locally sensible (the per-function shadow keeps the operator out of a large module's namespace; the nested matches map each level to a status code). It is three conventions in one tree. **Direction:** pick module-level `let*` for modules whose happy path is a chain, keep the nested-match form where each level's *shape* is the point (the REST routes), and say that in one line in the skill file. **Learning note:** `let ( let* ) = Result.bind in` is not an import, it is a local scope — that's why you see it repeated; repeated ten times in one file is a signal the shadow belongs at the top.

#### L5. 39 decorative banner comments, in a repo whose own convention file forbids them · `lib/usage.ml` (9), `test/test_config.ml` (8), `bin/main.ml` (8), `lib/server.ml` (6), `lib/model.ml` (5), `lib/health.ml` (1), `ocaml-tools/surface.ml` (2) · **[different]**

`(* ------------------------------------------------------------------ clocks *)` and friends. Meanwhile `engine.ml` sections itself with `(* {1 The search engine} *)`/`(* {2 The [logs.py] helpers} *)` — ocamldoc headings, which odoc can render — as do `agent.ml`, `extractor.ml` and `fetcher.ml`, and `AGENTS.md` states the rule for the Python side: "No decorative section banners … Sectioning comes from the module docstring and the function/class structure itself". **Direction:** convert the banners to `{1}`/`{2}` headings; they cost nothing, survive code moving, and feed the docs build the repo already has an `odoc` dependency for. **Learning note:** the comment that survives a refactor is the one that describes structure, not the one that draws a line. OCaml has an in-language convention for this (`{N}` in doc comments) precisely because the alternative rots.

#### L6. A dead binding in the diagnosis path · `bin/main.ml` · `check` · **[wrong]**

```ocaml
      let logging = Log.apply_overrides config.Config.logging None None in
      let _log = Log.sink (Log.make logging) in
```

`Log.sink` is pure — it returns a function — so building and discarding it does nothing, and `Log.make logging` reads two config fields into a record that is never used. (`logging` is used later, so the first line stays.) **Direction:** delete the second line, or if the intent was "validate the logging config and report", say so with the call that does it. **Learning note:** `_name` in OCaml means "I know this is unused", which is a *hint to the compiler*, not a marker for a side effect. When a codebase uses `_` prefixes to satisfy warnings (see M0, L7), a `_`-binding whose right-hand side is a pure call is worth a look — the underscore is suppressing exactly the question you should ask.

#### L7. Parameters that exist only to keep an arity · `lib/config.ml` · `api_key`; `lib/engine.ml` · `Engine.Fetch.read_page`, `log_ok` · **[different]**

`let api_key (_config : t) name = env (api_key_env_var name)` — the accessor ignores the configuration it is an accessor of; `read_page (_t : t) …` and `log_ok base (_t : t) …` take the engine value and discard it. Each keeps an OCaml function shaped like the Python method it replaces. That is defensible at a seam (a record field's function type has to match the other rungs) and misleading inside a module. **Direction:** keep the `_t` where the value is a member of a record of functions (`Fetcher.fetcher`'s fields, the `readers` packing — the type *requires* uniform arity); drop it where the function is called in one place and could simply take fewer arguments. **Learning note:** in OCaml there are no methods, so every "self" is a parameter you can see; if it is unused at every call site, delete it and the record-field type that forced it, and the interface gets smaller.

#### L8. `assert false` over an open sum type from a dependency · `lib/fetch/jsondoc.ml` · `dump_leaf` · **[different]**

```ocaml
  | `String s -> json_string s
  | _ -> assert false
(* Containers never reach here: the walk renders them as headers. *)
```

The invariant is real and commented. Two OCaml specifics: `` `Assoc ``/`` `List `` are members of `Yojson.Safe.t`, an open variant set a library owns and could grow; and `assert` disappears under `-noassert`, which anyone building with that flag (or a future `(env)` change, cf. M10) would silently get "fall through to match failure" instead. **Direction:** `| `List _ | `Assoc _ as c -> …` — enumerate the "impossible" cases and return a defined value (the same file's `dump_float` discipline) — or `invalid_arg`/a typed error if you want it loud. **Learning note:** `assert false` is a claim about *your* type. Over a dependency's sum type, prefer making the case impossible in the type (pass a leaf-only variant to `dump_leaf`) or handle it with a value; a defensive default that crashes only in debug is a default that has no owner in release.

#### L9. `describe_types`'s last-element dance · `lib/fetch/extractor.ml` · around the "HTML, plain text, JSON, CSV and PDF" phrase · **[different]**

```ocaml
  | _ -> join (List.rev (List.tl (List.rev labels))) ^ " and " ^ List.hd (List.rev labels)
```

Two `List.rev`s of the same list plus `tl`/`hd`, where the `hd` of one reversed list would do; `tl`/`hd` are partial, and here protected by the `| _ ->` that has already excluded `[]` and `[_]`. **Direction:** `match List.rev labels with [last] -> last | penultimate :: rest -> join (List.rev (penultimate :: rest)) ^ " and " ^ last` — one reversal, no partial functions. **Learning note:** `List.hd`/`List.tl`/`List.nth`/`List.last` are the partial parts of `List`; the total spelling is always a `match` on the shape you need. OCaml will not tell you the pattern is safe — the pattern *is* the proof, so write it in the pattern.

#### L10. A doc comment attached to the wrong thing, inside a module type · `lib/fetch/extractor.mli` · `module type S` · **[wrong]** (as documentation)

```ocaml
module type S = sig
  (** What the fetcher checks a response's media type against *before*
      using the body, so it must be honest: an unreadable type listed here
      spends a download on a page that can never be read. *)

  val name : string
  val supported_types : string list
```

That paragraph is about `supported_types`, and it sits after `sig`, where ocamldoc attaches it to the module type; `name` and `supported_types` themselves get nothing. The file otherwise attaches correctly — `val total_chars` and friends use trailing attached comments, and `val extract`'s comment (which notes it *raises* `Extraction_failed`) is attached properly. **Direction:** move the paragraph under `val supported_types`. **Learning note:** ocamldoc attachment rules bite everyone: `(** … *)` **before** an item attaches to that item; a comment **immediately after** one (no blank line) attaches backwards to it; a comment at the head of a `sig`/`struct` is the *signature's* description. If a doc comment looks like it is describing the thing above it, it probably is.

#### L11. `Agent.answer`'s error is prose, so its kinds are gone at the boundary · `lib/agent.mli`, `lib/server.ml` · `answer`, `answer_tool` · **[design question]**

`val answer : … -> (Model.answer_response, string) result`, documented as "Failure is a returned value, as in the rest of the port: [answer] answers [Error message] where Python raises [AgentFailed], and the message is written for the model". The interface also promises more structure than the type carries: "a call that exceeds it answers [Error] naming the phase it reached". `Server.answer_tool` then maps every one of those to one kind — `| Error message -> Error (Error.make Error.Failed ~message)`. A timeout, an all-steps-failed retrieval, and a no-results refusal are distinguishable only by reading the sentence. `Caps.Error.t` is the counter-example in the same tree: an abstract `t` with a kind and a sanitised message. **Direction:** if nothing branches on the distinction, current shape is honest and worth a sentence saying so; if the REST projection's status code, the journal's `error` field, or an operator alert should ever distinguish "we timed out" from "the provider failed", carry the phase/kind as a variant and keep the message for the model. **Learning note:** `Error string` is a fine convention for pure validation layers (`Config`, `Model`) because the message *is* the finding. For a layer that wraps network and clock failures, "string" means the next consumer will grep it.

#### L12. The server's stop switch is created and never resolved · `lib/server.ml` · `serve_http` · **[design question]**

```ocaml
  let stop, _resolve = Eio.Promise.create () in
  …
  Eio.Net.run_server ~stop ~on_error socket
```

`Eio.Net.run_server ~stop` is the right API, and `_resolve` being unused means the promise is never fulfilled: the listener runs until the process dies. `bin/main.ml` installs no signal handler, so there is no graceful-drain path (relevant for an HTTP deployment behind a kubelet, which the `/healthz` story implies). **Direction:** either return the resolver to the caller of `serve_http` so `main.ml` can wire `SIGTERM` to it, or record in the module comment that termination is deliberately process-level. **Learning note:** a value named `_resolve` is a promise about future work that nobody owns; in Eio, cancellation is data (a promise, a switch, a `Cancel`), so "how does this stop?" should be answerable from types, not from the fact that the process can be killed.

#### L3′. `Config.section`'s key discipline is good; its message picks one offender · `lib/config.ml` · `section` · **[different]**, listed because the positive pattern is worth copying

```ocaml
  let read = ref Name_set.empty in
  let get key =
    read := Name_set.add key !read;
    List.assoc_opt key fields
  in
  let* value = decode get in
  match List.filter (fun (key, _) -> not (Name_set.mem key !read)) fields with
  | [] -> Ok value
  | (key, _) :: _ -> Error (unknown_key loc key)
```

The decoder records what it consumed and reports what it did not — pydantic's `extra="forbid"` expressed without a schema DSL. Only the first unknown key is reported; reporting all of them (sorted) would save an operator a round-trip per typo. **Learning note:** this is a good OCaml idiom to internalise — capability-tracking-by-construction ("the getter notes the key it served") rather than validating a schema description. It is the same instinct as `caps`' grants, one level down.

---

## 3. What to look for in OCaml code — a checklist for this project

Each check names an example in this tree, good or bad, so it is executable on the next pull request.

1. **Does a failure the caller must act on arrive as a value?** Search the boundary function's type for `result`; search the module for `try`/`with`.
 *Good:* `Engine.Search.resolve` converts `Router.Route_refused` into `Error sentence` at the seam. *Bad:* H1 — `Engine.take` raises past every `try` in the file, out of a module whose docstring promises values.
2. **Which exceptions are allowed to cross this boundary, and is that stated?** `grep -n '^exception ' lib/**/*.mli` should be short *and* governed.
 *Bad:* M11 — `Fetcher.Url_blocked` is both a `refusal` constructor and an exception, next to a non-raising `validate_url_opt`, with no written rule anywhere.
3. **Is every `Option.get`, `List.hd`, `List.tl`, `List.nth`, `failwith`, `assert false` protected by something the compiler can see?**
 *Good:* `Jsondoc`'s `assert false` at least states its invariant. *Bad:* M3 — `page.image <> None` then `Option.get page.image`; `List.find_opt (fun r -> r.notice <> None)` then `Option.get r.notice`; L8.
4. **Is a byte-level or string-indexing invariant re-implemented anywhere else?** grep `0x80`, `0xc0`, `land 0xe0`, `String.sub`.
 *Bad:* H2 — eight codepoint walkers, three encodings of the test, one whitespace set written four times, one of the walkers unclamped (H1).
5. **Are prefix/suffix tests using `String.starts_with`/`String.ends_with`?**
 *Good:* `lib/fetch/fetcher.ml`'s image signatures. *Bad:* `ocaml-tools/surface.ml` (`String.sub line 0 5 = "type "`), `bin/main.ml` (`String.sub flag 0 2 = "--"`), `Server.serve_http`'s `"host:"` test, `test_engine.ml`/`test_fetch_engine.ml`'s `is_prefix`/`is_suffix`.
6. **Does the stdlib already have it?** (Substring search: no. Prefix/suffix: yes. `List.filter_map`, `Option.value`, `String.split_on_char`: yes. `List.last`: no.)
 *Good:* `main.ml`'s `Option.value ~default:"127.0.0.1" opts.host`. *Bad:* M2 — `contains` written 20 times with two argument orders; `List.concat_map (fun (f,v) -> if f = … then [v] else [])` where `List.filter_map` exists.
7. **Is there a dependency seam, and does this module pick the same shape as its neighbours?** Records of functions, `(module S)`, or `S` + record + `of_module`.
 *Good:* `Provider.Net.t` ("a plain record rather than an abstract grant", because tests are the point), `Engine.Fetch.fetcher` ("what a value gives and a module does not"). *Question:* L14/M5 — `Provider.t = (module S)` plus five hand-written accessors is a third shape in the same tree.
8. **Are there two records with the same fields and a function between them?** Read the copier: all `M.field` and no logic means a shared type.
 *Good:* `type endpoint = Policy_net.endpoint = { … }` in `lib/caps/policy.mli`. *Bad:* `Factory.page_of` between `Fetcher.fetched_page` and `Engine.Fetch.page` (M5).
9. **Is a type alias being used for more than one concept?**
 *Bad:* L1 — `Config.name` ("A provider name") is also the argument type of `Config.config_path` and `Config.load`. *Good:* `Config.name` in `Agent.answer`'s `?provider`.
10. **Is a tuple wider than three, or all the same type?** Then it is a record.
 *Bad:* `surface.ml`'s `count_lines`, ten `int`s destructured positionally twice. *Good:* `Factory.providers`' labelled record for the same kind of bundle.
11. **Do the same names mean one thing across the tree?** Same identifier, two meanings is a bug generator; same *arity and order* is what matters for helpers.
 *Bad:* M2 — `contains text needle` vs `contains needle haystack`.
12. **Does a list get built by appending?** Ask where the length comes from: config (≤17 names) or a caller/page.
 *Bad where unbounded:* `Jsondoc.dedupe` (M4). *Good shape:* `Provider.codepoints` accumulates backwards and `List.rev`s once.
13. **Is one `Result` bind style used per module?**
 `let*` module-level (config.ml, model.ml), per-function shadow ×9 (policy_net.ml), `( >>= )` (server.ml), or nested `match` (api_search). All appear in one build (L4).
14. **Is each doc comment attached to the thing it describes?** Especially inside `sig`/`module type`, and for `val`s whose comment mentions `raise`.
 *Bad:* L10 — the `supported_types` paragraph sits at the head of `module type S` and becomes the signature's own description.
15. **Is every "these are the same" claim enforced by a rule, not by prose?** This repo already has the tools: dune `diff` rules, `(deps (glob_files …))`, `with-accepted-exit-codes`.
 *Good:* `test/dune`'s `ocamldep -I ../lib` diff pinning `router_dependencies.expected`, and `lib/dune` naming that rule as the guard ("stdlib-only by design — not by the absence of a [libraries] field … but by the [ocamldep] diff in test/dune"); the six `should_not_compile` diagnostics. *Bad:* M1 (log type ×6, pinned in prose ×3), M8 (six byte-identical resources, unpinned), M6 (flag names in two modules, nothing between them).
16. **Does each `mutable`/`ref` carry its justification?**
 *Good:* `lib/health.ml` explains the assoc-list-of-mutable-records and the `open_until = 0.` sentinel ("replacing it with an [option] would move the state machine rather than name it") — that is how a sentinel earns its keep. *Ask:* L6's `_log` binding, and M3's `!first_failure` ref-plus-test pair.
17. **Can every effect be injected?** clocks, log sinks, net grants, page readers.
 *Good:* `Engine`/`Health`/`Usage` take `~clock`/`~now`/`~log`; `Engine.Fetch` takes a `Readers` seam so the core never names `Jsondoc`; `Policy_net` re-supplies its own connector. *Bad:* `bin/main.ml` is not drivable at all (exit-code paths intermixed with inline `exit 1`, and no suite).
18. **Are hand-written protocol bytes computing their own lengths?**
 *Bad:* M7's `content-length: 19` next to a message twenty lines away.
19. **Does the build pin the compiler's warnings, and does the project treat them as gates?**
 *Bad:* M10 — no `(env)`/`(flags)`/`warn-error` anywhere, next to three AST-scanning guards and an `ocamldep` diff rule.
20. **Is the library direction stated, and is it stated where a reader of the interface would see it?**
 *Good:* every `dune` in `lib/` explains its stanza and the direction; `lib/fetch/dune` — "nothing in [lib/] may name a fetch backend, so whatever builds one … depends on this library, never the reverse". This is the single most copyable habit in the tree.

---

## 4. Checked and clean

Verified in this session and worth saying out loud.

- **`dune build` is clean**: exit 0, no warnings, on OCaml 5.3.0 / dune 3.11.
- **Interfaces are complete and documented**: all 33 `lib/**/*.mli` files begin with `(**`, and the header comments explain trade-offs, not signatures (`engine.mli`'s clocks section, `extractor.mli`'s "an unreadable type listed here spends a download on a page that can never be read").
- **Every `dune` file carries a rationale**, including the dependency direction and why a stanza exists at all: `lib/dune`, `lib/providers/dune` ("the public name puts it inside the same artifact: findlib sees `seekwright.providers`, the build sees `Seekwright_providers`, and the opam package stays one"), `lib/fetch/dune`, `lib/fetch/extractors/dune`, `lib/factory/dune`, `lib/caps/dune` (including why `mirage-crypto-rng.unix` is *deliberately absent*).
- **The capability layer is the strongest OCaml in the tree**: `Tool.t` as `('caps, 'input) t` with `run : 'caps -> 'input -> (Output.t, Error.t) result`, `Authority.t` as `type _ t` with `type nonrec t = fs t`, and `test/should_not_compile/` pinning six claims by full expected compiler diagnostics, with a dune comment that explains why the compile is an `ocamlfind ocamlc` rule rather than a stanza and why the diagnostics are `sed`-cleaned with `set -o pipefail` + `with-accepted-exit-codes (not (or 0))`.
- **Dependency pins are real and non-vacuous**: `test/dune`'s `ocamldep -I ../lib` rule with the comment explaining that the `-I` is load-bearing (without it "every cross-module line [was] empty and the pin vacuous"); `test_core_no_mcp_kit.ml` derives its module list from the sandbox directory and fails if the glob is empty or the exempted adapter is missing.
- **The frozen-surface instrument is correct today**: I generated the manifest and compared its key lists against `lib/config.mli` for all eight record types — `[agent]` 11, `[dashboard]` 2, `[fetch]` 22, `[logging]` 6, `[policy]` 3, `[search]` 5, per-provider 12, top-level 9 — all matching exactly, and the two golden pairs (`surface.expected`, `py_body.out`/`our_body.out`) are wired into `runtest`.
- **All six embedded oracle strings are byte-identical to the Python resources** (`diff` clean for the four `Prompts` texts, `Agent.answer_system_prompt`, and the 1,204-line `Dashboard_html.dashboard_html`) — the claim in the header comments holds as of this checkout (see M8 for keeping it true).
- **Test seams are well-chosen and documented**: every adapter suite drives a fake `Provider.Net.t` "the position httpx.MockTransport holds in the Python suites", no socket is opened; `test_http_transport.ml` is the one place that runs a real listener, with a comment saying why that is the only way to observe the adapter's bounds; `test_config.ml` load-tests the operator docs pages as `(deps)`.
- **No library runs the event loop** (`Eio_main` appears in `lib/` only in comments and in `lib/dune`'s explanation), **no file `open`s a library globally** (zero `^open` in `lib/`, `bin/`, `test/`; aliasing is all `module X = Y`), and `model.mli` writes `(search_response, string) Stdlib.result` because the module has a wire model literally named `result` — shadowing handled deliberately rather than by accident.
- **Mutation is justified where it exists** (`lib/health.ml`'s board, `lib/usage.ml`'s aggregates, both with the reason in the module header), and injected clocks are universal enough that `test/dune`'s comment can claim a cooldown case "moves a reference rather than sleeping".
- **Per-operation `Eio.Switch.run` in `Policy_net`** with the socket-closing rationale in the comment, and defensive arms around third-party raises (`cohttp-eio`'s `failwith`, `Eio.Cancel`/`Eio.Exn.Multiple` re-raised explicitly).
- **The log discipline is structural, not stylistic**: `Log.sink` writes to stderr only, an event name is a constant, every value is a named field rendered through `Yojson`, and the level check is one comparison — which is what makes the "no secrets in logs" rule reviewable.
- **`test/conformance/` exists as a cross-implementation differential harness** (fixture + expected-failures + comparison script), which is the right instinct for a port, and `examples/` keeps the plan's fallback path (`echo.ml`, no capability code) runnable beside the gated ones.

---

## 5. Held by the earlier review — not repeated here

Default extractor unbootable; the factory silently dropping unported provider names; `Health.run_probes` never called; `provider_timeout_seconds` and `fetch.timeout_seconds` dead; the caps audit sink never wired; the public `Controls.t` bypass; raw `Printexc`/`prerr_endline` on the serving path; missing log-privacy test pins; `bin/main.ml` untested; other inert config keys; the three `py_repr` copies; `Jsondoc.py_repr`'s non-ASCII escaping; bracketed-IPv6 URL validation; `Engine.strip`'s whitespace-set membership (I cite the *duplication* of that set at H2, not its contents); the duplicated `policy_net` comment; the constant `cached = false`.

Where my findings touch these: M9 is the coverage map around the factory item, H2 is the ownership question underneath the `py_repr` and `strip` items, and L17/L6 are the mechanisms that keep `bin/main.ml` undrivable.

---

## 6. Appendix — how the load-bearing claims were verified

- **H1 repro.** A verbatim copy of `Engine.utf8_width` and `Engine.take` compiled with `ocamlfind ocamlopt` and run against `"a\xe2\x80"`:
  ```
  len=3 cps=2
  RAISED Invalid_argument "String.sub / Bytes.sub"
  ```
  Reachability was read, not executed: `Engine.Search.resolve_or_reject`'s `("requested", `String (safe ~limit:40 requested))`; `Model.search_request_of_yojson`'s `opt_string "provider"` with no membership check; `Server.search_properties`' `("provider", provider_enum)` covering the MCP door only; `Model.check_length` counting codepoints without validating well-formedness; `grep` showing exactly two `try` forms in `lib/engine.ml`, both for `Router.Route_refused`.
- **Byte-identity of embedded resources.** Each literal's body extracted and `diff`ed against `src/seekwright/resources/` (`server_instructions.txt`, `search_description.txt`, `fetch_description.txt`, `answer_description.txt`, `answer_system.txt`, `dashboard.html`); the two tool-description files have no trailing newline and their literals don't either, matching the header comment.
- **Surface correctness.** `./surface.exe lib/config.mli` output compared key-by-key against `lib/config.mli`'s record declarations for all eight record types (70 keys).
- **Duplication counts.** Greps for the codepoint constants, for substring-helper definitions, for `^(\* -{4,})` banner comments (39), for `^type log` (6 declarations), for `let ( let* )`/`let ( >>= )` definitions (20 definitions across 10 files), for `^exception ` (6), for `Option.get`/`List.hd`/`List.tl`/`assert false`/`failwith` in `lib/` and `bin/`.
- **Build facts.** `dune build` (exit 0, silent); `ocamlfind ocamlopt -version` → 5.3.0; `dune-project` → `(lang dune 3.11)`, `(name seekwright)`, `(generate_opam_files true)`; opam files carry `:with-test`/`:with-doc` markings; `grep -rn "(env" --include=dune --include=dune-project .` → nothing.

*No file in the worktree was modified; no `dune promote` or `dune runtest` was run; the only file created is this report.*
