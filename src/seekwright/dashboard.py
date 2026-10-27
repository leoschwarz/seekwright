"""The usage dashboard page, served as one static document from package data.

The page is ``resources/dashboard.html``, read once at import. uv_build ships the
whole module tree, so there is no static-asset mount to configure and no
package-data path to get wrong in the OCI build. The document carries no external
assets -- no CDN, no font, no chart library -- because a container behind a VPN
has no business reaching out for a script tag.

All behaviour is client-side: the page polls ``GET dashboard/data`` and renders
the snapshot it gets back. Nothing here reads the journal or holds state; the
route in ``server.py`` is the only server-side half.
"""

from __future__ import annotations

from importlib.resources import files

DASHBOARD_HTML = (
    files("seekwright")
    .joinpath("resources", "dashboard.html")
    .read_text(encoding="utf-8")
)
