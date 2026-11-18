# Step 1: Project structure, Git workflow and the setup script

## 1. What are we going to build?

A small web app for **tutorials**. A logged-in user can:

- see the list of tutorials (title, link, description, average rating),
- add a tutorial,
- rate a tutorial from 1 to 5 stars.

The app is **serverless** and runs on AWS. Every piece of infrastructure is described in **Terraform** code, so the whole stack can be built with one command and removed with another. The project is built in **9 steps**. Each step adds one layer and ends with a test.

**This step builds no AWS resource.** It creates the skeleton that all later steps fill: the folders, the empty files and the `.gitignore`. A script generates the skeleton, so it can be recreated at any time. This step also sets up the **Git repository**, in which every step becomes one commit with a tag.

| Step | Topic | Git tag |
|---|---|---|
| 1 | Project structure, Git workflow, `setup_project.sh` (this step) | `step-01` |
| 2 | Cognito: users, sign-up and login | `step-02` |
| 3 | Network and security: VPC, subnets, security groups | `step-03` |
| 4 | RDS: the PostgreSQL database | `step-04` |
| 5 | Lambda: IAM role and the four functions (placeholders) | `step-05` |
| 6 | API Gateway: the front door | `step-06` |
| 7 | Database schema and build pipeline | `step-07` |
| 8 | The handlers and the remaining routes | `step-08` |
| 9 | The frontend: login, list, form and star rating | `step-09` |

## 2. The AWS infrastructure: what we need and why

| Component | AWS service | Job in the app | Step |
|---|---|---|---|
| Users and login | **Cognito** (user pool, app client, domain) | Sign-up, login page (Hosted UI), password reset, tokens | 2 |
| Private network | **VPC** with 2 private subnets in 2 availability zones | The database and the functions live here, not on the internet | 3 |
| Firewall rules | **Security groups** | Only the Lambda functions may talk to the database | 3 |
| Database | **RDS PostgreSQL** | Stores users, tutorials and ratings | 4 |
| Business logic | **Lambda** functions and an **IAM** role | One function per job (list, create, rate, init) | 5, 7, 8 |
| Front door | **API Gateway** (HTTP API) with a JWT authorizer | Public HTTPS address, rejects requests without a valid token | 6, 8 |
| Web pages | **S3 and CloudFront** | Hosting of the frontend. Until then, a local development server serves the pages | after step 9 |

A request travels through the finished app like this:

```
Browser (frontend)
  |  1. login            ------------------->  Cognito Hosted UI
  |  <------------------  tokens (JWT)
  |
  |  2. GET /tutorials   (Authorization: Bearer <ID token>)
  v
API Gateway  --- invalid token? --->  401, stop
  |
  v
Lambda (in the private subnets)
  |
  v
RDS PostgreSQL (private, no public access)
```

### Why this design?

- **Serverless:** there is no server to patch or keep running, and the bill follows the number of requests.
- **Cognito instead of our own login:** passwords and tokens are a security topic, so a managed service takes care of them.
- **Database in a private subnet:** it has no public address, and only our functions can reach it.
- **Terraform:** infrastructure as code. It is reviewable, repeatable and can be removed with `terraform destroy`.

## 3. The folders: frontend, backend, infra

```
tutorials-app/                 the Git repository
├── README.md                  overview of the project
├── docs/                      one tutorial file per step
│   ├── step-01-structure.md   (this file)
│   └── step-02-cognito.md ... added step by step
├── scripts/
│   └── setup_project.sh       generates the structure (used once)
├── infra/                     Terraform: all AWS resources
│   ├── main.tf                Terraform block, provider, locals
│   ├── variables.tf           input variables
│   ├── outputs.tf             values printed after apply (URLs, IDs)
│   ├── cognito.tf             step 2
│   ├── vpc.tf                 step 3
│   ├── rds.tf                 step 4
│   ├── lambda.tf              steps 5 and 7
│   ├── api_gateway.tf         steps 6 and 8
│   ├── terraform.tfvars       the real values, secrets included, never committed
│   └── terraform.tfvars.example   same keys, no secrets, committed
├── backend/                   Python code of the Lambda functions
│   ├── build.sh               builds the deployable folders (step 7)
│   ├── shared/                code used by all functions
│   │   ├── __init__.py
│   │   ├── db.py              database connection (step 7)
│   │   └── responses.py       HTTP response helper (step 8)
│   ├── init_db/               creates the tables
│   ├── get_tutorials/         list and detail
│   ├── create_tutorial/       add a tutorial
│   └── rate_tutorial/         rate a tutorial
│       (each with handler.py and requirements.txt)
├── frontend/                  what the browser loads (step 9)
│   ├── index.html
│   ├── callback.html          the page Cognito sends the user back to
│   ├── css/style.css
│   └── js/                    auth.js, api.js, app.js
└── .gitignore
```

| Folder | What lives there | Why separate |
|---|---|---|
| `infra/` | Terraform files | Terraform runs here. Its state, plan files and secrets stay in one place. |
| `backend/` | Python source of the Lambdas | One folder per function: each is deployed as its own zip and contains only what it needs. |
| `backend/shared/` | Code that several functions use | It is written once, and `build.sh` copies it into every function. |
| `frontend/` | HTML, CSS, JavaScript | Static files, hosted separately from the code that runs in AWS. |
| `docs/` | The tutorial text, one file per step | It keeps the root `README.md` short. |
| `scripts/` | Helper scripts | Tooling stays apart from the product code. |

### Why one `.tf` file per topic?

Terraform reads **all** `.tf` files in a folder as one configuration, so the split is only for people. One file per AWS topic is easy to navigate, and the file names match the steps of this tutorial. An empty `.tf` file is valid, so `terraform validate` already passes now.

### Why `terraform.tfvars.example`?

`terraform.tfvars` contains the secrets (for example `db_password`) and is ignored by Git. The `.example` file lists the same keys with dummy values. It is committed, so a new developer knows which values to provide.

### One `infra/` folder for the whole project

There is **one** `infra/` folder and therefore **one Terraform state**. Step 3 adds `vpc.tf` to the same folder, and `terraform apply` creates only the new resources. Real projects grow in the same way. The stack can still be built, tested and destroyed: `terraform destroy` ends a working session, and `terraform apply` starts the next one.

## 4. The Git workflow: one repository, one commit and one tag per step

### The strategy

| Question | Answer |
|---|---|
| How many repositories? | **One**, private while the project is in progress. |
| Where is "the project after step N"? | At the commit with the tag `step-NN`. There are no copies of the files. |
| What is a branch for? | A short-lived working area for one step. It is merged and deleted. |
| Where is the tutorial text? | In `docs/`, one file per step. |

### Why not the alternatives?

| Option | Problem |
|---|---|
| One repository per step | Nine repositories for one project. Every fix has to be repeated nine times, and the history of how the project grew is lost. |
| One long-lived branch per step | A fix on `step-02` does not reach `step-05` unless the branches are merged by hand, so they drift apart. |
| Folders `01` to `09` in one repository | Every file exists up to nine times, and each folder needs its own Terraform state. Real projects do not work that way. |

### The routine for every step from step 2 on

```bash
git switch -c step-02-cognito         # a branch for the step
# ... write code, terraform plan, terraform apply, test ...
git status                            # no tfvars, no state, no build/ folders in the list
git add -A
git commit -m "Step 2: Cognito user pool, app client and domain"

git switch main
git merge --no-ff step-02-cognito     # or: open a pull request on GitHub and merge it there
git tag -a step-02 -m "Cognito working"
git push origin main --tags
git branch -d step-02-cognito         # the branch has done its job
```

Step 1 is the exception. It is the first commit, so it goes straight onto `main` (see section 7).

### Working with the tags

```bash
git diff step-02 step-03              # exactly what step 3 added
git switch --detach step-03           # the project as it was after step 3
git switch main                       # back to the latest state
git tag                               # list of all steps
```

On GitHub, the "Tags" dropdown shows the same state in the browser. A bug in an old step is fixed once on `main`, and the old tags stay as they were, which is right for a history.

A pull request per step is a good habit even for a single developer. GitHub shows the diff of the step, and the description of the pull request can be the summary of the step.

## 5. The `.gitignore`

Git stores **source files** only. The script (section 6) writes these rules:

| Rule | Why it is ignored |
|---|---|
| `infra/.terraform/` | Downloaded providers. `terraform init` recreates them. |
| `infra/*.tfstate*` | The state. It contains resource details and sometimes secrets. |
| `infra/terraform.tfvars` | The secrets. |
| `infra/*.tfplan`, `infra/*.plan` | Saved plans can contain variable values, including the database password. |
| `infra/build/` | The zip files that Terraform creates. |
| `backend/build/` | Output of `build.sh`: the code plus libraries. It is generated and can be deleted at any time. |
| `__pycache__/`, `*.pyc`, `.venv/` | Python leftovers. |
| `response.json` | Output of `aws lambda invoke`. |
| `frontend/node_modules/`, `frontend/.env` | Dependencies and local settings. |
| `.env`, `.DS_Store`, `.vscode/`, `.idea/` | Secrets, operating system files and editor files. |

`infra/.terraform.lock.hcl` is **not** ignored. It pins the provider versions and holds no secrets, so it belongs in Git.

## 6. The script `setup_project.sh`

### Where does it live?

In **`scripts/setup_project.sh`**, inside the repository, and it is committed.

- It documents how the structure came to be, and a new team member can recreate the skeleton with it.
- It is safe to run again, because it never overwrites a file.
- It finds the repository root by itself (the parent of `scripts/`), so it works from any folder.

It is used once at the start. After that it stays as documentation.

### What it does

It generates **only the structure**: folders, empty files and the `.gitignore`. It writes no code, because the code is written in the later steps.

```bash
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
.venv/
venv/
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
```

How it works:

- `set -euo pipefail` stops the script on the first error, on unset variables and on failures inside pipes.
- `SCRIPT_DIR` is the folder of the script, found through `BASH_SOURCE`. The default target is its parent, so the script works wherever it is started. An optional argument selects another target folder.
- `mkdir -p` creates folders and does not complain if they exist. `backend/{a,b}` is bash **brace expansion**, so one line creates five folders.
- `touch` creates an empty file, or only updates the timestamp of an existing one. **It never deletes content**, so a second run does not damage existing work.
- `chmod +x backend/build.sh` makes the build script executable for step 7.
- The `.gitignore` is written only if none exists. Otherwise a second run would overwrite later additions.
- The heredoc delimiter is quoted (`<< 'EOF'`), so bash writes the text exactly as it is.

## 7. Running the script and making the first commit

### Tools

The tutorial uses these tools. Steps 2 to 9 explain when each one is needed.

| Tool | Used for |
|---|---|
| Git and a GitHub account | Version control (this step) |
| Terraform 1.5 or newer | Infrastructure (from step 2) |
| AWS CLI, configured with credentials | Checks and test calls (from step 2) |
| Python 3 with `pip` | The build script (from step 7) |
| `curl` and `jq` | Test calls to the API (from step 6) |

In this tutorial, `tf` is a short alias for `terraform`. It is set once in the shell configuration (for example `~/.zshrc`):

```bash
alias tf=terraform
```

### Running the script

```bash
mkdir tutorials-app && cd tutorials-app
mkdir scripts
# the script of section 6 is saved as scripts/setup_project.sh, then:
bash scripts/setup_project.sh
```

### Verify

`terraform.tfvars` is created by the script but ignored by Git, so it is missing in a fresh clone. `setup_project.sh` or a manual copy of `terraform.tfvars.example` creates it again.

```bash
find . -type f | sort | wc -l
```

The result is **31 files**: 30 generated by the script (8 `.tf` files, `terraform.tfvars` and its `.example`, `build.sh`, 3 files in `shared/`, 8 in the four function folders, 6 in `frontend/`, `README.md` and `.gitignore`) plus the script itself. The empty folder `docs/` is created too, and it fills up when this file is added.

A second run of the script prints `skip (exists): .gitignore` and changes nothing else.

Terraform accepts the empty skeleton:

```bash
cd infra
tf init
tf validate          # Success! The configuration is valid.
cd ..
```

### Check before the first commit

This check matters more than any branch strategy. A secret that was committed once stays in the history, even after the file is deleted.

```bash
git init -b main
git check-ignore -v infra/terraform.tfvars infra/terraform.tfstate backend/build/x
git add -A
git status --short
git ls-files | grep -E 'tfvars$|tfstate|\.tfplan|\.plan'     # prints nothing
```

- `git check-ignore -v` reports all three paths as ignored and shows which rule matched.
- `git ls-files` lists what Git tracks. `terraform.tfvars` is not in it. `terraform.tfvars.example` is allowed, and the `grep` does not match it.

### Commit, tag and push

On GitHub, an empty **private** repository is created, without README or `.gitignore`. Then:

```bash
git commit -m "Step 1: project structure and setup script"
git tag -a step-01 -m "Project structure"
git remote add origin git@github.com:<your-user>/tutorials-app.git
git push -u origin main --tags
```

Without an SSH key, the HTTPS URL of the repository works as well.

## 8. Typical problems

| Symptom | Likely cause |
|---|---|
| `Permission denied` when the script starts | The script is started with `bash scripts/setup_project.sh`, or made executable with `chmod +x` first. |
| `mkdir backend/{a,b}` creates one folder named `{a,b}` | The script was started with `sh` instead of `bash`. Brace expansion needs `bash`. |
| A file with content is empty again | Not possible with `touch`. A `>` redirection in a change to the script is the likely cause. |
| `terraform.tfvars` appears in `git status` or `git ls-files` | The file was added before the `.gitignore` existed. `git rm --cached infra/terraform.tfvars` removes it from Git. If it was already pushed, the secrets in it have to be changed. |
| `.gitignore` was not updated by a second run | By design. The file is edited by hand. |
| `git push` is rejected: "remote contains work you do not have" | The GitHub repository was created with a README. The repository has to be empty, or `git pull --rebase origin main` merges the two histories first. |
| An empty folder is missing after `git clone` | Git does not store empty folders. The folder appears once it holds a file. |
| `tf: command not found` | The alias from section 7 is missing, or the shell was not restarted after adding it. |

## 9. What to remember

- Step 1 creates **no AWS resource**, only the skeleton and the repository.
- Three folders, three jobs: `infra` builds the cloud, `backend` is the code that runs there, and `frontend` is what the browser loads.
- **One repository, one `infra/` folder, one state.** Each step is a commit, and a tag `step-NN` marks it.
- The setup script lives in `scripts/` and is **idempotent**: running it again loses no work.
- Secrets and generated files never go into Git: `terraform.tfvars`, state, plans and the `build/` folders.

## 10. Next step

Step 2 fills `infra/main.tf`, `infra/variables.tf`, `infra/outputs.tf` and `infra/cognito.tf`. It adds the user pool, the app client and the login domain, and tests sign-up, login and password reset in the browser. It starts with `git switch -c step-02-cognito` and ends with the tag `step-02`.
