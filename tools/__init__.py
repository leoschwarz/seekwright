"""Dev-side tooling that runs in CI over this checkout, never in the server.

Deliberately outside ``src/``: nothing here runs in the server, imports its
serving path, or is shipped in the image. Each module is a ``--check`` step the
gate runs -- the frozen surface, the egress lists, the frozen value sets --
reading the tree rather than a running process.
"""
