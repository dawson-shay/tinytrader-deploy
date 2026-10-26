# JupyterLab for a site's research notebooks (its research/), with
# Databento's DBN reader for the store's tapes. Runs as a non-root user; no
# drive is mounted (notebooks ask the store, docs/decisions/0007).
# The packages are the site's uv.lock (pyproject.toml, uv.lock and
# .python-version at its root, the build context `project` in its
# compose.yaml; a `notebook` dependency group), installed with uv into
# /opt/venv, which is first on PATH: `python` and `jupyter` are the venv's.
# By hand, from the site:
#   docker build --build-context project=. -t research:test ../tinytrader-deploy/deploy/local/research
FROM python:3.13.9-slim-bookworm
COPY --from=ghcr.io/astral-sh/uv:0.12.17 /uv /uvx /usr/local/bin/
# The image's Python, never a downloaded one; bytecode compiled at build time.
ENV UV_PROJECT_ENVIRONMENT=/opt/venv \
    UV_PYTHON=/usr/local/bin/python3.13 \
    UV_PYTHON_DOWNLOADS=never \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_NO_CACHE=1
COPY --from=project pyproject.toml uv.lock .python-version /opt/site/
RUN cd /opt/site && uv sync --frozen --no-dev --group notebook
ENV VIRTUAL_ENV=/opt/venv \
    PATH=/opt/venv/bin:$PATH
RUN useradd --create-home --uid 1000 research
# Strategies keep their journals in /state (a named volume); a new volume takes
# this directory's owner, so the runner can write it.
RUN mkdir -p /state && chown research:research /state
COPY jupyter_server_config.py /etc/jupyter/jupyter_server_config.py
USER research
WORKDIR /work
EXPOSE 8888
CMD ["jupyter", "lab", "--ip=0.0.0.0", "--port=8888", "--no-browser", "--ServerApp.root_dir=/work"]
