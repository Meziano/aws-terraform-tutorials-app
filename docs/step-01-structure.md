# Step 1: Project structure, Git workflow and the setup script

## 1. What are we going to build?

A small web app for **tutorials**. A logged-in user can:

- see the list of tutorials (title, link, description, average rating),
- add a tutorial,
- rate a tutorial from 1 to 5 stars.

The app is **serverless** and runs on AWS. Every piece of infrastructure is described in **Terraform** code, so the whole thing can be built with one command and removed with another. The project is built in **7 steps**. Each step adds one layer and ends with a test.

**This step builds no AWS resource.** It creates the skeleton that all later steps fill: the folders, the empty files and the `.gitignore`. A script generates the skeleton, so you can recreate it at any time. It also sets up the **Git repository** in which every step becomes one commit with a tag.

| Step | Topic | Git tag |
|---|---|---|
| 1 | Project structure, Git workflow, `setup_project.sh` (this step) | `step-01` |
| 2 | Cognito: users, sign-up and login | `step-02` |
| 3 | Network and security: VPC, subnets, security groups | `step-03` |
| 4 | RDS: the PostgreSQL database | `step-04` |
| 5 | Lambda: IAM role, the first function, the other functions | `step-05` |
| 6 | API Gateway: the front door | `step-06` |
| 7 | The application: database schema, handlers, build script, frontend | `step-07` |

## 2. The AWS infrastructure: what we need and why

| Component | AWS service | Job in the app | Step |
|---|---|---|---|
| Users and login | **Cognito** (user pool, app client, domain) | Sign-up, login page (Hosted UI), password reset, tokens | 2 |
| Private network | **VPC** with 2 private subnets in 2 availability zones | The database and the functions live here, not on the internet | 3 |
| Firewall rules | **Security groups** | Only the Lambda functions may talk to the database | 3 |
| Database | **RDS PostgreSQL** | Stores users, tutorials and ratings | 4 |
| Business logic | **Lambda** functions + **IAM** role | One function per job (list, create, rate, init) | 5, 7 |
| Front door | **API Gateway** (HTTP API) with a JWT authorizer | Public HTTPS address, rejects requests without a valid token | 6 |
| Web pages | **S3 + CloudFront** | Hosting of the frontend (added last, until then Live Server) | later |

How a request travels through the finished app:

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

- **Serverless:** no server to patch or keep running. You pay per request.
- **Cognito instead of our own login:** passwords and tokens are a security topic. We use a managed service for it.
- **Database in a private subnet:** it has no public address. Only our functions can reach it.
- **Terraform:** infrastructure as code. It is reviewable, repeatable and can be deleted with `terraform destroy`.

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
│   ├── lambda.tf              step 5 and 7
│   ├── api_gateway.tf         step 6 and 7
│   ├── terraform.tfvars       YOUR values, secrets included, never committed
│   └── terraform.tfvars.example   same keys, no secrets, committed
├── backend/                   Python code of the Lambda functions
│   ├── build.sh               builds the deployable folders (step 7)
│   ├── shared/                code used by all functions
│   │   ├── __init__.py
│   │   ├── db.py              database connection
│   │   └── responses.py       HTTP response helper
│   ├── init_db/               creates the tables
│   ├── get_tutorials/         list and detail
│   ├── create_tutorial/       add a tutorial
│   └── rate_tutorial/         rate a tutorial
│       (each with handler.py and requirements.txt)
├── frontend/                  what the browser loads
│   ├── index.html
│   ├── callback.html          the page Cognito sends the user back to
│   ├── css/style.css
│   └── js/                    auth.js, api.js, app.js
└── .gitignore
```

| Folder | What lives there | Why separate |
|---|---|---|
| `infra/` | Terraform files | Terraform runs here. Its state, plan files and secrets stay in one place. |
| `backend/` | Python source of the Lambdas | One folder per function: each is deployed as its own zip and gets only what it needs. |
| `backend/shared/` | Code that several functions use | Written once. `build.sh` copies it into every function. |
| `frontend/` | HTML, CSS, JavaScript | Static files, hosted separately from the code that runs in AWS. |
| `docs/` | The tutorial text, one file per step | Keeps the root `README.md` short. |
| `scripts/` | Helper scripts | Tooling is kept apart from the product code. |

### Why one `.tf` file per topic?

Terraform reads **all** `.tf` files in a folder as one configuration, so the split is only for people. One file per AWS topic is easy to navigate, and the file names match the steps of this tutorial. An empty `.tf` file is valid, so `terraform validate` already passes now.

### Why `terraform.tfvars.example`?

`terraform.tfvars` contains your secrets (for example `db_password`) and is ignored by Git. The `.example` file lists the same keys with dummy values. It is committed, so a new developer knows which values to provide.

### One `infra/` folder for the whole project

There is **one** `infra/` folder and therefore **one Terraform state**. Step 3 adds `vpc.tf` to the same folder, and `terraform apply` creates only the new resources. Real projects grow in the same way. You can still build, test and destroy: run `terraform destroy` at the end of a working session and `terraform apply` the next day.

## 4. The Git workflow: one repository, one commit and one tag per step

### The strategy

| Question | Answer |
|---|---|
| How many repositories? | **One**, private while you work. |
| Where is "the project after step N"? | At the commit with the tag `step-NN`. No copies of the files. |
| What is a branch for? | A short-lived working area for one step. It is merged and deleted. |
| Where is the tutorial text? | In `docs/`, one file per step. |

### Why not the alternatives?

| Option | Problem |
|---|---|
| One repository per step | Seven repositories for one project. Every fix must be repeated seven times, and the history of how the project grew is lost. |
| One long-lived branch per step | A fix on `step-02` does not reach `step-05` unless you merge by hand. The branches drift apart. |
| Folders `001` to `007` in one repository | Every file exists up to seven times, and each folder needs its own Terraform state. Real projects do not work that way. |

### The routine for every step from step 2 on

```bash
git switch -c step-02-cognito         # a branch for the step
# ... write code, terraform plan, terraform apply, test ...
git status                            # check: no tfvars, no state, no build/ folders
git add -A
git commit -m "Step 2: Cognito user pool, app client and domain"

git switch main
git merge --no-ff step-02-cognito     # or: open a pull request on GitHub and merge it there
git tag -a step-02 -m "Cognito working"
git push origin main --tags
git branch -d step-02-cognito         # the branch has done its job
```

Step 1 is the exception: it is the first commit, so it goes straight onto `main` (see section 7).

### Working with the tags

```bash
git diff step-02 step-03              # exactly what step 3 added
git switch --detach step-03           # look at the project as it was after step 3
git switch main                       # come back
git tag                               # list all steps
```

On GitHub, the "Tags" dropdown shows the same state in the browser. A bug in an old step is fixed once on `main`. The old tags stay as they were, which is right for a history.

**A pull request per step** is a good habit even when you work alone. GitHub shows the diff of the step, and the description of the PR can be the summary of the step.

## 5. The `.gitignore`

Git must only store **source files**. The script (section 6) writes these rules:

| Rule | Why it is ignored |
|---|---|
| `infra/.terraform/` | Downloaded providers. `terraform init` recreates them. |
| `infra/*.tfstate*` | The state. It contains resource details and sometimes secrets. |
| `infra/terraform.tfvars` | Your secrets. |
| `infra/*.tfplan`, `infra/*.plan` | Saved plans can contain variable values, including the DB password. |
| `infra/build/` | The zip files that Terraform creates. |
| `backend/build/` | Output of `build.sh`: your code plus libraries. It is generated and can be deleted at any time. |
| `__pycache__/`, `*.pyc`, `.venv/` | Python leftovers. |
| `response.json` | Output of `aws lambda invoke`. |
| `frontend/node_modules/`, `frontend/.env` | Dependencies and local settings. |
| `.env`, `.DS_Store`, `.vscode/`, `.idea/` | Secrets, OS and editor files. |

`infra/.terraform.lock.hcl` is **not** ignored. It pins the provider versions and holds no secrets, so it must be committed.

## 6. The script `setup_project.sh`

### Where does it live?

In **`scripts/setup_project.sh`**, inside the repository, and it is committed.

- It documents how the structure came to be, and a new team member can recreate the skeleton.
- It is safe to run again, because it never overwrites a file.
- It finds the repository root by itself (the parent of `scripts/`), so you can start it from any folder.

It is used once at the start. After that it stays as documentation.

### What it does

It generates **only the structure**: folders, empty files and the `.gitignore`. It writes no code. The code is written in the later steps.

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
- `SCRIPT_DIR` is the folder of the script, found from `BASH_SOURCE`. The default target is its parent, so the script works wherever you start it. An optional argument selects another target folder.
- `mkdir -p` creates folders and does not complain if they exist. `backend/{a,b}` is bash **brace expansion**, so one line creates five folders.
- `touch` creates an empty file, or only updates the timestamp of an existing one. **It never deletes content**, so a second run does not damage your work.
- `chmod +x backend/build.sh` makes the build script executable for step 7.
- The `.gitignore` is written only if none exists. Otherwise a second run would overwrite your own additions.
- The heredoc is quoted (`<< 'EOF'`), so bash writes the text exactly as it is.

## 7. Run it, then make the first commit

```bash
mkdir tutorials-app && cd tutorials-app
mkdir scripts
# save the script above as scripts/setup_project.sh, then:
bash scripts/setup_project.sh
```

Move this file to `docs/step-01-structure.md`.

### Verify

```bash
find . -type f | sort | wc -l
```

You should get **31 files**: 30 generated by the script (8 `.tf` files, `terraform.tfvars` and its `.example`, `build.sh`, 3 files in `shared/`, 8 in the four function folders, 6 in `frontend/`, `README.md` and `.gitignore`) plus the script itself. The empty folder `docs/` is created too, and it fills up when you add this file.

Run the script a second time. It must print `skip (exists): .gitignore` and change nothing else.

Check that Terraform accepts the empty skeleton:

```bash
cd infra
terraform init          # in this tutorial: tf init
terraform validate      # Success! The configuration is valid.
cd ..
```

### Check before the first commit

This matters more than any branch strategy. A secret that was committed once stays in the history, even if you delete the file later.

```bash
git init -b main
git check-ignore -v infra/terraform.tfvars infra/terraform.tfstate backend/build/x
git add -A
git status --short
git ls-files | grep -E 'tfvars$|tfstate|\.tfplan|\.plan'     # must print nothing
```

- `git check-ignore -v` must report all three paths as ignored, and shows which rule matched.
- `git ls-files` lists what Git tracks. `terraform.tfvars` must not be in it. `terraform.tfvars.example` is allowed, and the grep does not match it.

### Commit, tag and push

Create an empty **private** repository on GitHub, without README or `.gitignore`, then:

```bash
git commit -m "Step 1: project structure and setup script"
git tag -a step-01 -m "Project structure"
git remote add origin git@github.com:<your-user>/tutorials-app.git
git push -u origin main --tags
```

Use the HTTPS URL instead if you do not have an SSH key set up.

## 8. Typical problems

| Symptom | Likely cause |
|---|---|
| `Permission denied` when you run the script | Run it with `bash scripts/setup_project.sh`, or `chmod +x` first. |
| `mkdir backend/{a,b}` creates one folder named `{a,b}` | The script was run with `sh` instead of `bash`. Use `bash`. |
| A file you edited is empty again | Not possible with `touch`. Look for `>` redirections in your own changes to the script. |
| `terraform.tfvars` appears in `git status` or `git ls-files` | The file was added before the `.gitignore` existed. Run `git rm --cached infra/terraform.tfvars`. If it was already pushed, change the secrets in it. |
| `.gitignore` was not updated by a second run | By design. Edit the file by hand. |
| `git push` is rejected: "remote contains work you do not have" | The GitHub repository was created with a README. Use an empty one, or run `git pull --rebase origin main` first. |
| An empty folder is missing after `git clone` | Git does not store empty folders. The folder appears once it holds a file. |

## 9. What to remember

- Step 1 creates **no AWS resource**, only the skeleton and the repository.
- Three folders, three jobs: `infra` builds the cloud, `backend` is the code that runs there, `frontend` is what the browser loads.
- **One repository, one `infra/` folder, one state.** Each step is a commit, and a tag `step-NN` marks it.
- The setup script lives in `scripts/` and is **idempotent**: you can run it again without losing work.
- Secrets and generated files never go into Git: `terraform.tfvars`, state, plans, `build/` folders.

## 10. Next step

Step 2 fills `infra/main.tf`, `infra/variables.tf`, `infra/outputs.tf` and `infra/cognito.tf`. It adds the user pool, the app client and the login domain, and you test sign-up, login and password reset in the browser. It starts with `git switch -c step-02-cognito` and ends with the tag `step-02`.
