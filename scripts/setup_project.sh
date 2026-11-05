#!/usr/bin/env bash
# scripts/setup_project.sh - generates the STRUCTURE of the project, nothing else:
# folders, empty files and the .gitignore. No code is written here.
# Safe to run twice: existing files are never overwritten.
#
# Usage:  bash scripts/setup_project.sh            (target = the repository root)
#         bash scripts/setup_project.sh some/folder (target = another folder)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(dirname "$SCRIPT_DIR")}"   # default: the parent of scripts/
mkdir -p "$ROOT"
cd "$ROOT"

# --- folders ---------------------------------------------------------------
mkdir -p docs infra
mkdir -p backend/{shared,init_db,get_tutorials,create_tutorial,rate_tutorial}
mkdir -p frontend/{css,js}

# --- root ------------------------------------------------------------------
touch README.md

# --- infra: one file per topic ---------------------------------------------
touch infra/{main,variables,outputs,cognito,vpc,rds,lambda,api_gateway}.tf
touch infra/terraform.tfvars infra/terraform.tfvars.example

# --- backend ---------------------------------------------------------------
touch backend/build.sh
chmod +x backend/build.sh
touch backend/shared/{__init__,db,responses}.py
for fn in init_db get_tutorials create_tutorial rate_tutorial; do
  touch "backend/$fn/handler.py" "backend/$fn/requirements.txt"
done

# --- frontend --------------------------------------------------------------
touch frontend/{index,callback}.html
touch frontend/css/style.css
touch frontend/js/{auth,api,app}.js

# --- .gitignore (only if it does not exist yet) ------------------------------
if [ -e .gitignore ]; then
  echo "skip (exists): .gitignore"
else
  cat > .gitignore << 'EOF'
# -----------------------------
# Terraform
# -----------------------------
infra/.terraform/
infra/*.tfstate
infra/*.tfstate.*
infra/terraform.tfvars
infra/*.tfplan
infra/*.plan
infra/build/
infra/crash.log
infra/crash.*.log
response.json

# -----------------------------
# Backend (Lambda)
# -----------------------------
backend/build/
__pycache__/
*.pyc
backend/**/.venv/
backend/**/venv/

# -----------------------------
# Frontend
# -----------------------------
frontend/node_modules/
frontend/dist/
frontend/.env

# -----------------------------
# General / editor / OS
# -----------------------------
.env
.DS_Store
Thumbs.db
*.log
.vscode/
.idea/
EOF
  echo "created: .gitignore"
fi

echo "Done. Project structure is in: $(pwd)"
