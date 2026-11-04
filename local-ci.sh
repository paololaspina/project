#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$0")"

echo "=================================="
echo " AWS Lab – Local CI"
echo "=================================="

echo
echo "[1/5] Bash-Syntax"
bash -n aws-lab-reset.sh

echo
echo "[2/5] Python-Syntax"
python3 - <<'PY'
from pathlib import Path

for path in Path("tests").glob("test_*.py"):
    compile(path.read_bytes(), str(path), "exec")

print("Python-Syntax OK")
PY

echo
echo "[3/5] Regressionstests"
python3 tests/test-aws-lab-reset.py

echo
echo "[4/5] Terraform-Formatierung"
terraform fmt -check -recursive terraform

echo
echo "[5/5] Terraform-Validierung"
terraform -chdir=terraform init -backend=false -input=false
terraform -chdir=terraform validate -no-color

echo
echo "=================================="
echo " ALLE LOKALEN CI-CHECKS BESTANDEN"
echo "=================================="
