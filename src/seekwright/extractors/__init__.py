"""Fetch extraction backends, one module per engine.

Nothing here is imported at package-import time: :func:`seekwright.factory.build_extractor`
imports the selected backend, which keeps ``import seekwright`` cheap and lets an
install carry only the backend it uses. The contract and the list of places a new
backend has to be wired live in :mod:`.base`.
"""
