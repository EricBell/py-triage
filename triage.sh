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
ruff check "$PKG_PATH" --isolated --select C901,B,SIM,RET > "$REPORT_DIR/3b_ruff_smells.txt" || true

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