# Python Reverse Engineering & Triage Kit (`uv` + Docker)

A zero-pollution, containerized static analysis, complexity profiling, and test-gap discovery toolkit built on **Docker** and **`uv`**. 

This kit mounts any target Python repository into `/workspace`, runs isolated analysis tools from `/opt/uv-tools`, builds ephemeral test environments inside `/tmp` (leaving your host repo untouched except for the generated `audit_reports/` directory), and produces actionable refactoring and testing targets.

---

## 1. Repository Layout & Kit Files

Store these three files in your toolkit repository (e.g., `~/tools/py-xray/`):

```text
py-xray/
├── Dockerfile
├── docker-compose.yml
├── triage.sh
├── LICENSE          # e.g., PolyForm Noncommercial 1.0.0
└── USAGE_GUIDE.md   # This file
```

### `Dockerfile`
```dockerfile
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
```

### `triage.sh`
```bash
#!/usr/bin/env bash
set -u

PKG_PATH="${1:-src}"
REPORT_DIR="/workspace/audit_reports"
mkdir -p "$REPORT_DIR"

echo "=== Running Python Reverse Engineering & Triage (uv) on: $PKG_PATH ==="

# 1. Map: Module dependency graph
echo "[1/5] Generating dependency graph (pydeps)..."
pydeps "$PKG_PATH" --max-bacon=2 --noshow -T svg -o "$REPORT_DIR/1_dependencies.svg" || true

# 2. Rank: Cyclomatic Complexity (grades C-F) & Maintainability Index
echo "[2/5] Calculating complexity hotspots (radon)..."
radon cc "$PKG_PATH" -s -n C > "$REPORT_DIR/2_complexity_hotspots.txt"
radon mi "$PKG_PATH" -s -n B >> "$REPORT_DIR/2_complexity_hotspots.txt"

# 3. Prune: Dead code & anti-patterns
echo "[3/5] Scanning for dead code (vulture) & smells (ruff)..."
vulture "$PKG_PATH" --min-confidence 80 > "$REPORT_DIR/3_dead_code.txt" || true
ruff check "$PKG_PATH" --select C901,B,SIM,RET > "$REPORT_DIR/3b_ruff_smells.txt" || true

# Configure an ephemeral venv inside /tmp so we don't pollute the mounted repo
export UV_PROJECT_ENVIRONMENT="/tmp/target-venv"

if [ -f "pyproject.toml" ]; then
    TEST_RUNNER="uv run --with pytest --with pytest-cov --with mutmut"
elif [ -f "requirements.txt" ]; then
    TEST_RUNNER="uv run --no-project --with-requirements requirements.txt --with pytest --with pytest-cov --with mutmut"
else
    TEST_RUNNER=""
fi

# 4. Measure: Line & branch test coverage
echo "[4/5] Running pytest with branch coverage..."
$TEST_RUNNER pytest --cov="$PKG_PATH" --cov-branch --cov-report=term-missing --cov-report=xml:"$REPORT_DIR/coverage.xml" > "$REPORT_DIR/4_coverage_report.txt" || true

# 5. Stress-test: Mutation testing (optional via RUN_MUTMUT=true)
if [ "${RUN_MUTMUT:-false}" = "true" ]; then
    echo "[5/5] Running mutation tests (mutmut)..."
    $TEST_RUNNER mutmut run --paths-to-mutate="$PKG_PATH" || true
    $TEST_RUNNER mutmut results > "$REPORT_DIR/5_mutation_results.txt" || true
else
    echo "[5/5] Skipping mutmut (set RUN_MUTMUT=true to enable)."
fi

echo "=== Done! Reports saved to ./audit_reports ==="
```

### `docker-compose.yml`
```yaml
services:
  py-reveng:
    build:
      context: .
      dockerfile: Dockerfile
    image: py-reveng-toolkit:latest
    container_name: py-reveng-audit
    volumes:
      - ${TARGET_REPO:-.}:/workspace
    environment:
      - RUN_MUTMUT=${RUN_MUTMUT:-false}
    command: ["${TARGET_PKG:-src}"]
```

---

## 2. Setup & Directory Positioning

### Step 1: Build the Image Once
Navigate to your toolkit directory (`py-xray/`) and build the image:

```bash
cd ~/tools/py-xray
docker compose build
```

### Step 2: Position Your Working Directory (`cwd`)
You have two ways to position your terminal depending on your workflow:

#### Pattern A: Run from the Toolkit Directory (Recommended)
Keep your `cwd` inside `~/tools/py-xray` and point `TARGET_REPO` at the external codebase you want to inspect.

```text
~/
├── tools/
│   └── py-xray/              <-- Your CWD is here
│       └── docker-compose.yml
└── projects/
    └── legacy-app/           <-- TARGET_REPO points here
        ├── pyproject.toml
        ├── app/              <-- TARGET_PKG is "app"
        └── tests/
```

#### Pattern B: Run from Inside the Target Codebase
Keep your `cwd` inside the target repository and pass `-f` to `docker compose`. `TARGET_REPO` defaults to `.` (your current directory).

```bash
cd ~/projects/legacy-app
TARGET_PKG=app docker compose -f ~/tools/py-xray/docker-compose.yml up
```

---

## 3. Execution & Command Permutations

All reports are written to `<TARGET_REPO>/audit_reports/`.

### Standard Fast Audit (Steps 1–4)
Runs dependency mapping, complexity scoring, dead-code detection, smell linting, and branch coverage (skips slow mutation testing):

```bash
TARGET_REPO=~/projects/legacy-app TARGET_PKG=app docker compose up
```

### Full Deep Audit with Mutation Testing (Steps 1–5)
Runs the entire pipeline including `mutmut`. Best run **after** fixing obvious coverage gaps:

```bash
TARGET_REPO=~/projects/legacy-app TARGET_PKG=app RUN_MUTMUT=true docker compose up
```

### Interactive Investigation Shell
Drop into a `bash` shell inside `/workspace` with all `uv` tools on `PATH` so you can run ad-hoc queries, inspect specific mutants, or tweak flags:

```bash
TARGET_REPO=~/projects/legacy-app docker compose run --rm --entrypoint /bin/bash py-reveng
```

#### Useful Ad-Hoc Commands Inside the Interactive Shell
Once inside the container shell (`/workspace`):

* **Inspect a surviving mutant from `mutmut`:**
  ```bash
  mutmut show 14
  ```
* **Check test coverage only on files changed since `main`:**
  ```bash
  diff-cover audit_reports/coverage.xml --compare-branch=origin/main
  ```
* **Zoom in on a single tightly-coupled module's dependencies:**
  ```bash
  pydeps app/billing/processor.py --max-bacon=1 --noshow -T svg -o audit_reports/billing_deps.svg
  ```
* **View all functions (including simple `A` and `B` grades) sorted by complexity:**
  ```bash
  radon cc app -s -o SCORE
  ```
* **Enforce a hard complexity ceiling (exits non-zero if any block is worse than `B`):**
  ```bash
  xenon app --max-absolute B --max-modules B --max-average A
  ```
* **Find dead code with lower confidence (catches more dynamic/obscure unused items):**
  ```bash
  vulture app --min-confidence 60
  ```

### Cleanup Between Runs
Remove stopped container instances when finished:
```bash
docker compose down
```
*(Note: If you ran `mutmut`, it creates a `.mutmut-cache` file in your target repo. Delete it or add `.mutmut-cache` and `audit_reports/` to your global `.gitignore`.)*

---

## 4. What to Look For in Each Tool's Output

Use this diagnostic guide to translate raw tool outputs into concrete refactoring tickets and unit tests.

### 1. `pydeps` (`1_dependencies.svg`) — Architecture & Coupling
Open the SVG in any browser to inspect module relationships.
* **Circular Dependencies (Red/Bidirectional Arrows):** Module A imports Module B, and Module B imports Module A.
  * *Action:* Extract shared data models or interfaces into a third, lower-level module so dependencies flow strictly one way.
* **"Hub" or "God" Modules (Nodes with 10+ incoming/outgoing arrows):** A single file that everything depends on, or that imports everything else.
  * *Action:* Split the file by domain responsibility before attempting to write isolated unit tests.

### 2. `radon` (`2_complexity_hotspots.txt`) — Refactoring Priorities
`radon cc` grades every function/method from **`A` (1–5)** to **`F` (41+)** based on independent execution paths (`if`, `for`, `while`, `except`, boolean `and`/`or`). `radon mi` grades overall file maintainability from **`A` (high)** to **`C` (low)**.
* **Grades `D`, `E`, `F` (Cyclomatic Complexity $\ge 21$):** High-risk monoliths. Too many branches to test reliably.
  * *Action:* Decompose into smaller, pure helper functions. Replace deeply nested `if/elif` chains with dispatch dictionaries or early-return guard clauses.
* **Grade `C` (Complexity 11–20):** Moderate risk.
  * *Action:* Prime candidates for parameterized unit tests covering every branch before refactoring.

### 3. `vulture` (`3_dead_code.txt`) — Code to Delete
Lists unused functions, classes, methods, properties, and variables along with a confidence percentage (`60%` to `100%`).
* **`100%` Confidence Items:** Unused imports and unreachable variables.
  * *Action:* Delete immediately.
* **`80%–90%` Confidence Items:** Unused functions, classes, or methods.
  * *Action:* Verify they aren't invoked dynamically (e.g., via `getattr()`, FastAPI/Flask route decorators, or Celery task registries). If not, delete them—never waste time refactoring or testing dead code.

### 4. `ruff` (`3b_ruff_smells.txt`) — Structural Anti-Patterns
Filtered to four high-signal rule sets (`C901`, `B`, `SIM`, `RET`):
* **`C901` (McCabe Complexity):** Flags functions exceeding default branching limits.
* **`B` (flake8-bugbear):** Highlights likely bugs (mutable default arguments like `def f(x=[])`, bare `except:`, unused loop variables).
* **`SIM` (flake8-simplify):** Spots collapsible `if` statements, redundant `else` blocks, and overly convoluted boolean expressions.
* **`RET` (flake8-return):** Identifies unnecessary `else` after `return` and inconsistent return paths.
  * *Action:* Apply these as quick, low-risk cleanup passes to improve readability.

### 5. `pytest --cov-branch` (`4_coverage_report.txt`) — Missing Test Paths
Shows statement coverage (`Stmts`, `Miss`) and branch coverage (`Branch`, `BrPart`), plus exact line numbers in the `Missing` column.
* **Partial Branches (e.g., `14->18` or `14->exit`):** Line 14 is an `if` condition that evaluated to `True` during tests, so line 15 ran, **but the `False` path was never tested**.
  * *Action:* Write targeted unit tests specifically triggering the `False` or edge-case condition.
* **High Complexity + Low Coverage Intersection:** Cross-reference `2_complexity_hotspots.txt` with `4_coverage_report.txt`. Any function graded `C–F` with `< 70%` branch coverage is your **highest-risk bug hotspot**.

### 6. `mutmut` (`5_mutation_results.txt`) — Weak Assertions
`mutmut` subtly alters your source code (e.g., changing `>` to `>=`, `+` to `-`, `True` to `False`, or deleting function calls) and re-runs `pytest`.
* **Killed Mutants:** Your test suite failed when the code was broken. *(Good)*
* **Survived Mutants:** `mutmut` broke your production logic and **all your tests still passed**.
  * *Action:* Run `mutmut show <id>` to see the exact diff that survived. This reveals missing boundary assertions (e.g., testing `x = 10` when the threshold is `x >= 5`, missing the `x = 5` boundary) or tests that execute code without asserting return values or side effects.

---

## 5. Future Expansion Notes

As you evolve this kit, consider adding:
* [ ] **Git Churn + Complexity Matrix:** Script combining `git log --format=format: --name-only` with `radon cc` to pinpoint files that change frequently *and* have high complexity.
* [ ] **Call Graph Generation (`code2flow`):** Add `uv tool install code2flow` to trace execution paths inside spaghetti legacy scripts without clear entry points.
* [ ] **Automated Test Bootstrapping (`pynguin`):** Add `pynguin` to auto-generate baseline regression tests for completely uncovered legacy modules prior to refactoring.