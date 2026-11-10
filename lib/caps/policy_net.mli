(** The checked DNS, connection, redirect and response-bound machinery behind a
    [Net] grant. It has no public interface on purpose: [Policy] is the only
    module that may build a grant, and [Policy.with_endpoints] /
    [Policy.with_public_web] are the only entry points (§5).

    M3 fills this in: resolve-then-connect on the same vetted address (checking
    DNS and then letting the HTTP client resolve again is a rebinding race),
    redirects off in v1, streamed bodies against a decoded-byte cap, one timeout
    over DNS through body, and no authorization, cookie, URI userinfo, query or
    body value in any event. *)
