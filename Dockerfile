FROM python:3.12-slim

# Copy the standalone uv binary from Astral's official image
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

# Install Graphviz (for pydeps) and git (for diff-cover / history checks)
RUN apt-get update && apt-get install -y --no-install-recommends \
    graphviz \
    git \
    && rm -rf /var/lib/apt/lists/*

# Put uv-managed tool shims on the global PATH
ENV UV_TOOL_BIN_DIR=/usr/local/bin \
    UV_TOOL_DIR=/opt/uv-tools \
    UV_NO_CACHE=1

# Install each static analysis tool in its own isolated environment
RUN uv tool install pydeps && \
    uv tool install radon && \
    uv tool install xenon && \
    uv tool install vulture && \
    uv tool install ruff && \
    uv tool install diff-cover

# Install pytest + mutmut together in a shared test-runner tool env
RUN uv tool install pytest --with pytest-cov --with coverage --with mutmut

WORKDIR /workspace

COPY triage.sh /usr/local/bin/triage
RUN chmod +x /usr/local/bin/triage

ENTRYPOINT ["triage"]