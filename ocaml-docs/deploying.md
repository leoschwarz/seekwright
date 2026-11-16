# Deploying the two roles

The two configs below split one installation in half so that neither half holds
the other's secret: the search role dials only the providers you named, and the
fetch role dials whatever URL a caller names and dispatches to no provider at
all. The fetch half is the one that reads arbitrary pages, so keeping provider
keys out of it means an exploit on that side has no credential to spend, and a
reader on that side never holds one. Each block is the whole config for its
role, and the suite loads both, so a key that moves out from under a role fails
a run here rather than a deployment.

### The search role

```toml
# search.toml — the role that can search and nothing else.
permitted_providers = ["exa:free", "freeserp"]

[providers."exa:free"]
enabled = true

[providers.freeserp]
enabled = true

[fetch]
enabled = false

[agent]
enabled = false
```

### The fetch role

```toml
# fetch.toml — the role that can fetch and nothing else.
permitted_providers = []

[fetch]
enabled = true
```

## Running the bundle

`deploy/compose/` is those two roles as a unit set: both run
`ghcr.io/leoschwarz/seekwright:${SEEKWRIGHT_TAG:-0.1.1}`, the same image built
from `Containerfile.ocaml`. Each sits on its own ordinary bridge network with
outbound NAT and no route to the other, publishing
`${SEEKWRIGHT_PUBLISH:-127.0.0.1}:8000` for search and `:8001` for fetch, both
onto the container's 8000. Egress is direct: no proxy sits in the bundle, the
binary reads no proxy variables, and the sink deny list and the
lenient-versus-strict `fetch` choice are not enforced there. Those belong to the
host firewall or nftables ruleset, fed from `deploy/compose/generated/`; the
reference ACLs for a network-layer proxy are in `deploy/compose/squid/`. What
the process still enforces is `Policy_net`'s address vetting,
`permitted_providers`, the `[fetch] enabled` gate, and `Fetcher.validate_url`'s
http(s)-only scheme with its refusal of credentials in the URL.

One trap the compose lane found: the `ghcr.io` packages the publishing workflow
creates are private until the repository's package visibility is set to Public.
The workflow's own smoke passes because it pulls with the token it pushed with,
while an unauthenticated `docker compose pull` fails. Either `docker login
ghcr.io` first and pull with that credential, or flip the package to public in
the repository's package settings.
