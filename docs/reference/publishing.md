# Publishing a release

The wheel and the image a release ships: where they go, what has to be true
before a publish run can succeed, and what its log has to show. The mechanism is
`.github/workflows/publish.yml`; this page is the procedure around it. Building
the image by hand is [container.md](container.md).

## Where the artifacts go

Both artifacts land where a consumer can reach them without a credential and
without an index to name:

- wheel: an asset of the GitHub Release the tag names. `gh release view v0.1.0`
  lists `seekwright-0.1.0-py3-none-any.whl`, and its download URL is public — the
  publish run installs from it with no token at all.
- image: `ghcr.io/leoschwarz/seekwright:<tag>`, carrying
  `org.opencontainers.image.revision` so the artifact itself names the commit it was
  built from.

0.1.0 publishes **no PyPI.org artifact**: the release asset and the image are the two
artifacts, and a PyPI.org release stays open work in [the roadmap](../ROADMAP.md) — one
`uv publish` step and a repository credential this repository does not hold yet. Until
it exists there is no bare `uvx seekwright` spawn: the only documented install is the
clone plus `uv sync` in the [quickstart](../quickstart.md), which carries `fetch`'s
default extraction backend because the dev group self-includes the `trafilatura`
extra. `fetch.extractor = "stdlib"` is the other name the setting takes and needs no
library at all, and an enabled `fetch` whose backend library is missing is
startup-fatal.

## One trigger, one version source

| Trigger | Path | What it publishes |
| --- | --- | --- |
| push of a `v*` tag | the release path | the release the tag names, with the wheel as its asset, and `ghcr.io/…/seekwright:<tag>` |

A tag push is the only trigger. There is no `workflow_dispatch` path: the `wheel` job
and the `container` job of [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml)
already build both artifacts at every push to `main`, and a dispatch run would name no
artifact to publish.

The wheel version never comes from the trigger. It is `[project] version` in
`pyproject.toml`, read off the built wheel filename, so a version bump needs no edit in
the workflow. The release rule is that the tag is `v` plus that version: `v0.1.0`
publishes `seekwright-0.1.0`. The `build and upload the wheel` step enforces the match:
it exits non-zero when the tag is not `v` plus the version it just built, printing the
ref, the version and the remedy — cut the tag that matches `[project] version`, or bump
the version. It does so before anything is uploaded or pushed, so a rejected release
publishes nothing.
`tests/repo/test_ci_workflow_publish_tag_guard.py` reads the workflow text and fails if
that check moves after the upload, stops exiting non-zero, or stops preceding the image
push.

What is enforced separately is that the three copies of the version inside the tree
agree — `pyproject.toml`, the `Containerfile` label and `seekwright.__version__` — and
`tests/repo/test_packaging.py` fails CI when they drift. The files a bump touches, in
order, are listed under *Bumping the version* in [container.md](container.md). Cutting
the tag itself is not the workflow's job.

The tag rule has a second half, about the commit rather than the name. The tag also has
to name the commit `main` names, and nothing else in the run can see the difference. The
version guard above reads the tag *name* against the wheel version declared by the same
tree, and the `org.opencontainers.image.revision` read-back reads the image label against
this run's own sha. A tag left behind `main` would therefore build, publish and report
success on a tree CI never ran on, since `ci.yml` triggers on pushes to `main`, on pull
requests and on dispatch, never on a tag. The step `the tag must name the commit main names` runs
first: it fetches `main` at depth 1 from the checkout's own origin and exits non-zero
unless that head equals the commit the pushed tag names, printing both shas and the
remedy. A hotfix release therefore re-cuts the tag after the fix merges.
`tests/repo/test_ci_workflow_publish_tag_names_main_head.py` fails if the check moves
after the wheel step, stops exiting non-zero, stops naming `main`, or acquires a branch
that skips it.

## A version the release already holds

The wheel is uploaded only when the release named by the tag holds no asset of that
filename. What the run does with each state:

| Release state | Effect |
| --- | --- |
| identical asset, sha256 match | print the match, skip the upload, continue to the install |
| different asset | **the run fails** at the wheel step, before the image push |

Failing rather than warning is deliberate: the release record reads that run's colour
as "the wheel and the image resolved", and warn-and-continue lets a run that published
no wheel report success. A *different* file under the same version is the maintainer's
call — `gh release delete-asset` on the old one, or a version bump — and never a
workflow side effect.

A different file is not rare: a wheel's `METADATA` is generated from `README.md`, so a
docs-only commit changes the wheel hash while `src/` and `pyproject.toml` stay put. The
build backend's version is a second input — the gap [container.md](container.md) already
names, where one tree built under uv 0.13.1 and the runner's uv 0.13.3 gave a different
hash for the same version. A release run cannot catch up with what is already
published by waiting: the version is decided, not discovered.

Failing there is also total: the run stops at that step, the image build, push and
smoke steps never run, and the registry gains nothing.

## What has to happen before the release run

1. **Bump the version, then re-lock.** `[project] version` in `pyproject.toml` moves
   before the tag is cut, and `uv lock` with it: the run compares the tag name with the
   version it builds, and `uv lock --check` is a CI step.
2. **Cut the tag at `main`'s head, pinned to one commit.** Push it —
   `git push origin refs/tags/v<version>` from the verified commit. A tag-creation API
   call names whatever `main` names at the moment of the call, not the commit you hand
   it, so pinning one commit — which is what re-cutting a tag after a hotfix merge means
   — is a push. The run's own `the tag must name the commit main names` step is what
   separates "CI ran on what this release ships" from "the release is green".
3. **Nothing has to be cleared first.** With no release named `<tag>`, the run creates
   it; with one holding the identical wheel, it skips the upload; with one holding a
   different wheel it fails and names what to delete. Deleting a published asset is the
   maintainer's action — `gh release delete-asset` — and no workflow code does it.
4. **The image tag keeps the leading `v`, and it is the only name.** The release pushes
   exactly `ghcr.io/leoschwarz/seekwright:v0.1.0`. Pushing an unqualified `0.1.0`
   beside it is rejected: two pullable names for one release is how an image goes
   unnoticed. A moving `latest` tag is open work in [the roadmap](../ROADMAP.md).

## What a publish run has to show

A run is evidence when its log carries these lines, and the release record quotes them:

- `TAG NAMES MAIN HEAD: v0.1.0 at <sha>`, printed when the run fetches `main`'s head
  and it equals the commit the pushed tag names; a tag at any other commit fails the run
  there, before the wheel step
- `tag v0.1.0 matches the built wheel version 0.1.0`
- `built seekwright-0.1.0-py3-none-any.whl sha256=…`
- either `created release v0.1.0 carrying seekwright-0.1.0-py3-none-any.whl` or
  `release already holds the identical … (sha256 match); skipping upload`
- `downloaded anonymously from the release: … sha256=…` followed by `WHEEL INSTALL OK:
  seekwright 0.1.0 (…) installed from the release asset`: the asset fetched over its
  public URL with no credential, its sha256 compared with the build's, then installed
  into a clean `--clear`ed venv, where `seekwright --help` runs
- `PUSHED ghcr.io/leoschwarz/seekwright:v0.1.0`
- `IMAGE REVISION OK: ghcr.io/leoschwarz/seekwright:v0.1.0 built from <sha>`, printed
  when the run reads `org.opencontainers.image.revision` back off the image it pulled
  out of the registry — not off the local build — and it equals the sha the run built
  from; an image naming another commit, or none, fails the run instead
- `seekwright --check exit code: 1`, recorded rather than asserted: a CI run holds no
  provider keys, which is also the reading a consumer gets from an unconfigured install
- `IMAGE SMOKE OK: ghcr.io/leoschwarz/seekwright:v0.1.0`

The acceptance check is the two halves of that list: the wheel installs in a clean
environment from the public asset URL and `seekwright --help` runs there, and the image
pulled back out of the registry answers `--help` and prints its `--check` exit code.

## The checklist, item by item, at a named head

The per-item answers live here, each naming the date it was measured at; the next run
re-measures them rather than carrying a figure over.

Measured 2026-10-27 on the head that carries the GitHub lane: no tag has been pushed
from it, so items 4 and 6 carry what the guards and the CI lane answer, not what a
publish answered.

- **Item 1, every release-critical issue closed: open work, not answerable from the
  tree.** What the tree does answer is the freeze: the three `--check` instruments of
  item 3 exit 0. Which issues are release-critical is the tracker's answer, and this
  repository acquires one when it is published.
- **Item 2, the release commit is green: verified.** `uv run ruff check` prints
  `All checks passed!`, `uv run ty check` prints `All checks passed!`, and
  `uv run pytest -q` exits 0 with no failures. The counts on those lines are read off
  the run, never recorded here: a suite size in prose is a number that ages.
- **Item 3, docs complete and consistent: verified.** The three `--check` steps CI runs,
  in its order, all exit 0:

  ```text
  uv run python -m tools.surface --check
  uv run python -m tools.egress_lists --check
  uv run python -m tools.value_sets --check
  ```

  Each prints its counts on success; the surface's own are
  [surface.md](surface.md)'s, rendered by [`tools/surface.py`](../../tools/surface.py)
  from the tree. `docs/architecture.md` and `docs/reference/metrics.md` both exist, and
  the surface manifest is the census `configuration.md` and `providers.md` render. The
  install block in `docs/quickstart.md` is the clone plus `uv`, which is the only
  install path 0.1.0 documents, and the README points there rather than adding a
  command of its own.
- **Item 4, install verified from the published artifacts: measured up to the artifact,
  and the published half waits on the first tag.** The `wheel` job of
  `.github/workflows/ci.yml` builds that file at every push to `main`, prints
  `built <wheel> sha256=…`, installs it into a clean venv and runs `seekwright --help`
  from outside the checkout. What only a release can measure is the install of what the
  release serves: the run's `install the published wheel in a clean venv` step, which
  downloads the asset by URL with no credential, compares its sha256 with the build's
  and installs it. There is no asset to read until the first tag runs, so this item
  closes with the release, not before it.
- **Item 5, live URLs and the version: the version half is verified, the URL half
  closes at publication.** `pyproject.toml`'s `[project] version` reads
  `version = "0.1.0"`, which matches the tag name and the `Containerfile` label, and
  `tests/repo/test_packaging.py` fails CI when those three copies drift.
  `pyproject.toml`'s `[project.urls]` names `github.com/leoschwarz/seekwright`
  addresses; they answer 404 until the repository is public and answer the real thing
  the moment it is, and the same test module keeps any retired host name out of the
  shipped fields — including the `User-Agent` the wheel carries, which is built from
  the same table.
- **Item 6, tag `v0.1.0` on the verified commit and publish: both artifacts are
  measured by CI, and the tag is the release.** The `container` job of
  `.github/workflows/ci.yml` builds this `Containerfile` at every push to `main`, runs
  `--help` inside the result and pushes nothing. Cutting the tag at a head is the
  release rather than a check of it, and the two guards — the tag against `main`'s head,
  the tag name against the built version — are what make pushing it a measured act.

Items 1, 4, 5 and 6 all move with the publication itself — the tracker, the public
repository, and the first tag.
