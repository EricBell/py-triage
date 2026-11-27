# py-triage — Overview

> A Docker + `uv` toolkit that mounts any Python repo and runs a fixed static-analysis and test-gap pipeline against it, writing reports to `audit_reports/`.

## Purpose

py-triage ("Python Reverse Engineering & Triage Kit") helps you size up an unfamiliar or legacy Python codebase. It maps module dependencies, ranks complexity hotspots, finds dead code and smells, measures branch coverage, and optionally runs mutation tests. The target repo is mounted into the container at `/workspace`, so nothing is installed into it. The only thing written to the host repo is `audit_reports/` (plus `.mutmut-cache` if mutmut runs). Licensed under PolyForm Noncommercial 1.0.0.

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Runtime | Docker, `python:3.12-slim` base image |
| Package/tool manager | `uv` (copied from `ghcr.io/astral-sh/uv:latest`) |
| Orchestration | Bash (`triage.sh`), Docker Compose |
| Analysis tools | pydeps (+ Graphviz), radon, xenon, vulture, ruff, diff-cover |
| Test tools | pytest, pytest-cov, coverage, mutmut |

## Directory Structure

```
py-triage/
├── Dockerfile            # Image: uv + graphviz + git + isolated uv tool installs; entrypoint = triage
├── docker-compose.yml    # Service "py-reveng": mounts target repo, passes env vars
├── triage.sh             # The 5-step pipeline (installed in image as /usr/local/bin/triage)
├── UsageGuide.md         # Long usage doc (untracked in git); embeds copies of the three files above
├── README.md             # One-liner description
├── LICENSE               # PolyForm Noncommercial 1.0.0
└── .gitignore
```

There is no Python source in this repo. It is purely tooling.

## Architecture

`docker compose up` builds the image and runs `triage <TARGET_PKG>` with the target repo mounted at `/workspace`. `triage.sh` runs five steps. Output files go to `/workspace/audit_reports/`:

| Step | Tool | Output |
|------|------|--------|
| 1 Map | `pydeps --max-bacon=2 -T svg` | `1_dependencies.svg` |
| 2 Rank | `radon cc -n C` and `radon mi -n B` | `2_complexity_hotspots.txt` |
| 3 Prune | `vulture --min-confidence 80`, `ruff --select C901,B,SIM,RET` | `3_dead_code.txt`, `3b_ruff_smells.txt` |
| 4 Measure | `pytest --cov --cov-branch` | `4_coverage_report.txt`, `coverage.xml` |
| 5 Stress | `mutmut run` and `mutmut results` (only if `RUN_MUTMUT=true`) | `5_mutation_results.txt` |

- **Tool isolation:** each analysis tool is installed with `uv tool install` into its own environment under `/opt/uv-tools`, with shims in `/usr/local/bin`. pytest, pytest-cov, coverage and mutmut share one env.
- **Target test environment:** `UV_PROJECT_ENVIRONMENT=/tmp/target-venv` keeps the target's dependencies out of the mounted repo.
  - `pyproject.toml` present: `uv run --with pytest --with pytest-cov --with mutmut`.
  - Otherwise `requirements.txt` present: `uv run --no-project --with-requirements requirements.txt ...`.
  - Neither present: `TEST_RUNNER` is empty and `pytest` is called directly from the tool env.
- **Error handling:** `set -u` only (no `-e`). Most steps end in `|| true`, so one failing tool doesn't stop the run.

## Integrations

No external services. The only network use is at build time (the uv image from GHCR, apt packages, PyPI tool installs).

## Database & Data Layer

None.

## Connectivity & Configuration

| Variable | Default | Purpose |
|----------|---------|---------|
| `TARGET_REPO` | `.` | Host path of the repo to analyze (mounted to `/workspace`) |
| `TARGET_PKG` | `src` | Package or path passed to every tool (positional arg of `triage`) |
| `RUN_MUTMUT` | `false` | Set to `true` to run step 5 |

Typical run: `TARGET_REPO=~/projects/app TARGET_PKG=app docker compose up`. For a shell inside the container: `docker compose run --rm --entrypoint /bin/bash py-reveng`. Image tag is `py-reveng-toolkit:latest` and the container name is `py-reveng-audit`. No ports are exposed.

## Key Entry Points

1. `triage.sh`: all pipeline logic.
2. `Dockerfile`: which tools are installed, and where.
3. `docker-compose.yml`: the env-var interface.
4. `UsageGuide.md` §4: how to read each report.

## Notes & Gotchas

- **Duplicated source of truth:** `UsageGuide.md` embeds full copies of the Dockerfile, `triage.sh` and compose file. They will drift unless updated together. The guide also calls itself `USAGE_GUIDE.md` and refers to the kit as `py-xray/`, while the repo is `py-triage` and the file is `UsageGuide.md`.
- **mutmut version:** `--paths-to-mutate` is a mutmut 2.x flag. The Dockerfile installs mutmut unpinned, so a 3.x install would likely break step 5, which `|| true` then hides.
- **Unused tools:** `xenon` and `diff-cover` are installed but not called by `triage.sh`. They are meant for ad-hoc use in the interactive shell.
- **Empty `TEST_RUNNER`:** with no `pyproject.toml` or `requirements.txt`, pytest runs without the target's dependencies, so coverage will likely fail or be empty.
- **Working directory:** `pyproject.toml` and `requirements.txt` are checked relative to `/workspace`, so `TARGET_PKG` should be a subpath of the repo root.
- **Unguarded steps:** the `radon` commands in step 2 have no `|| true`. They don't abort the run because `-e` isn't set.
- **Cleanup:** the guide suggests ignoring `audit_reports/` and `.mutmut-cache` in the target repo's `.gitignore`.
- **Unchecked claim:** `UsageGuide.md` says the target repo is left untouched. Nothing in the scripts enforces this beyond the `/tmp` venv, and `pytest` itself may write `.coverage` or `__pycache__` into `/workspace`.
