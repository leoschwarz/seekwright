# Its tag is `uv_build`'s lower bound in pyproject.toml (tests/test_packaging.py).
FROM ghcr.io/astral-sh/uv:0.12.3 AS uv

# Alpine, not Debian slim: the scan job fails the image on CRITICAL/HIGH, and the
# Debian trixie base ships util-linux/systemd/sqlite/ncurses builds carrying HIGH
# CVEs with no upstream fix released yet. The Alpine apk set scans clean.
FROM python:3.14-alpine AS build
COPY --from=uv /uv /usr/local/bin/uv
ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never
WORKDIR /app

# Keyed on the lock, not on src/; README.md and LICENSE feed the metadata build.
COPY pyproject.toml uv.lock README.md LICENSE ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked --no-dev --extra trafilatura --no-install-project

COPY src ./src
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked --no-dev --extra trafilatura --no-editable

FROM python:3.14-alpine
# Not at the top of the file: an ARG does not cross a stage boundary.
ARG SEEKWRIGHT_REVISION
# image.version copies `seekwright.__version__`: a LABEL cannot read Python.
LABEL org.opencontainers.image.title="seekwright" \
      org.opencontainers.image.description="MCP server fronting web-search providers: paid, free-tiered and keyless" \
      org.opencontainers.image.version="0.1.1" \
      org.opencontainers.image.source="https://github.com/leoschwarz/seekwright" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.revision="${SEEKWRIGHT_REVISION}"

# busybox adduser, not useradd. The runtime venv is self-contained and needs no
# pip; the base image's pip ships vendored msgpack/urllib3/setuptools copies the
# scan flags, so pip and its entry points are removed.
RUN adduser -S -D -u 10001 seekwright \
    && rm -rf /usr/local/lib/python3.14/site-packages/pip* /usr/local/bin/pip*

COPY --from=build --chown=seekwright:seekwright /app/.venv /app/.venv

# The config file names providers, so it is not baked in: bind-mount it.
ENV PATH="/app/.venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    SEEKWRIGHT_CONFIG=/etc/seekwright/config.toml

USER seekwright
EXPOSE 8000

# urllib, not curl: this base ships neither. Only under `--http`.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD ["python", "-c", \
         "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/healthz').read()"]

ENTRYPOINT ["seekwright"]
