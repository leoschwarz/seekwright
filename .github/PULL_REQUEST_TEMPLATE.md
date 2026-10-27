Fixes #<N>

<!-- Keep this on line 1: `<N>` is the issue this PR resolves. When it lands
     part of an issue that stays open, write `Part of #<N> - ` and name the part
     after the dash instead. The rest of the body is the evidence: what changed,
     why, and which checks ran with their real output. -->

# What this changes

<!-- One or two sentences. A reviewer should be able to tell from this line
     whether they are the right person to read the diff. -->

## Why

<!-- The problem it solves, and what you tried that did not work. If this
     changes something structural, the page that owns the rule carries the
     reasoning — link it here. -->

## Checks

CI runs all of these; paste each command with its real output rather than
saying "tests pass".

```bash
uv lock --check
uv run ruff check
uv run ty check
uv run pytest -q
```

## Docs that moved with it

- [ ] the page that owns the rule — if this changes something structural or
      reverses a constraint another page states
- [ ] `docs/reference/` — provider facts, config keys, the public API surface,
      the fetcher's guarantees, the container recipe
- [ ] `README.md` — only if the front door changed
- [ ] `docs/ROADMAP.md` — if this closes, defers or reverses an open item
- [ ] the reference page that owns a change a user would notice: a renamed or
      removed config key is `configuration.md`'s, a new provider name or flag is
      `providers.md`'s plus `surface.md` re-printed — there is no changelog

## Checklist

- [ ] No secrets, keys or credentials in the diff, the tests or the pasted
      output
- [ ] The new tests are hermetic — no network, no billing; a live test is
      opt-in, gated on `SEEKWRIGHT_LIVE_TESTS=1`, and names the provider
- [ ] New log lines use a constant dotted event name with values through
      `bind()`, and log no traceback
- [ ] A new adapter reports what it cannot honour in `notice` rather than
      dropping it silently
- [ ] No decorative section banners, and docstrings say *why*
