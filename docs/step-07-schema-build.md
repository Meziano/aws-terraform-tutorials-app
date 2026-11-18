# Step 7: The database schema and the build pipeline

## 1. What are we going to build?

Until now the four Lambda functions were placeholders that only opened a TCP connection. In this step the first function becomes **real**: `init_db` logs in to PostgreSQL (SSL, user, password) and creates the three tables of the app. To get there, we also build the **packaging pipeline** that every later function needs: a build script that puts the code, the libraries and the shared code into one folder per function.

No new AWS resource is created. The 26 resources of steps 2 to 6 stay the same, and the four Lambda functions are **updated in place** because their code package changes.

| What | Where |
|---|---|
| Shared code that opens the database connection | `backend/shared/db.py` |
| The real `init_db` handler with the schema | `backend/init_db/handler.py` |
| The library `pg8000` for `init_db` | `backend/init_db/requirements.txt` |
| The build script | `backend/build.sh` |
| The four zips now come from the build folder | `infra/lambda.tf` (four `source_dir` lines) |

The steps of the whole project:

| Step | Topic |
|---|---|
| 1 to 6 | Structure, Cognito, network, RDS, Lambda, API Gateway |
| **7** | **Schema and build pipeline (this step)** |
| 8 | The handlers and the remaining routes |
| 9 | The frontend |

At the end of this step:

- `./backend/build.sh` creates `backend/build/<function>/` for all four functions,
- `aws lambda invoke` on `init_db` answers `{"tables": ["ratings", "tutorials", "users"]}`,
- that answer is the **first real login** to the database: it proves the SSL connection, the user and the password, and that SQL runs,
- a second invocation gives the same answer and breaks nothing.

## 2. Prerequisites

- Step 6 is done and merged: `main` contains the tag `step-06`.
- Python 3 and `pip` work on the computer:

```bash
python3 -m pip --version
```
On a computer with several Python versions, a virtual environment makes sure that `python3` and `pip` belong together. `python3 -m venv .venv` creates it in the repository root, and `source .venv/bin/activate` activates it in the current terminal. The prompt then starts with `(.venv)`. The `.gitignore` of step 1 ignores this folder. The build script calls `python3 -m pip`, so it installs into the active environment. The environment can run a newer Python than the `python3.12` of Lambda, because the libraries are pure Python.

- The AWS credentials work:

```bash
aws sts get-caller-identity
```
- If the stack was destroyed after step 6, the plan below shows **26 to add, 0 to change**. The database is created again and takes 8 to 10 minutes, the functions add about 2 to 3 minutes, and Cognito gets new IDs (see step 2). If the stack still exists, the plan shows **0 to add, 4 to change**.
- The step starts on its own branch:

```bash
git switch main
git switch -c step-07-schema-build
```

## 3. The concepts

### Why a build step?

A Lambda zip must contain **everything** the function needs, because Lambda does not install libraries. Our functions need:

1. their own code (`handler.py`),
2. libraries that are not part of Python (here `pg8000`, the PostgreSQL driver),
3. the code that all functions share (`shared/`).

If every function folder held all of this, `shared/` would be copied four times by hand and generated libraries would be mixed with our own files. So the source folders stay clean, and a script assembles the packages in a separate folder:

```
backend/
├── build.sh
├── shared/                  source, edited by hand
│   ├── __init__.py
│   └── db.py
├── init_db/                 source only: handler.py, requirements.txt
├── get_tutorials/           source only
├── create_tutorial/         source only
├── rate_tutorial/           source only
└── build/                   GENERATED, ignored by Git, safe to delete
    ├── init_db/             handler.py + pg8000/ + scramp/ + ... + shared/
    ├── get_tutorials/
    ├── create_tutorial/
    └── rate_tutorial/
```

Terraform zips `backend/build/<function>/` into `infra/build/<function>.zip`. There are two folders named `build`, and they hold different things: `backend/build/` is the staging area, and `infra/build/` holds the finished zips. Git ignores both.

### How `from shared.db import connect` works

The root of the zip is on Python's search path in Lambda. In the zip, `shared/` sits next to `handler.py`, so `shared.db` means the file `shared/db.py`. The import line is the same in all handlers. A relative import (`from .shared.db import ...`) fails, because Lambda loads `handler.py` as a top-level module.

The editor does not run the build. It reads the source tree, where `shared/` is one level above `init_db/`, so it may underline the import. This is only cosmetic. A file `.vscode/settings.json` removes the warning:

```json
{ "python.analysis.extraPaths": ["backend"] }
```

If the `.gitignore` of step 1 contains `.vscode/`, the setting stays on the local computer, which is fine.

### Pure Python libraries can be built on any computer

`pg8000` and its helpers are written in pure Python. A zip built on a Mac or Windows computer also runs on the Linux of Lambda. A library with compiled parts (for example `psycopg2`) needs a Linux build. This is why the project uses `pg8000`.

### Connecting to RDS with SSL

PostgreSQL 15 or newer on RDS refuses connections without SSL (step 4). `pg8000` needs an **SSL context** to use SSL:

```python
context = ssl.create_default_context()
context.check_hostname = False
context.verify_mode = ssl.CERT_NONE
```

These lines **encrypt** the connection but do **not verify** the server certificate. Traffic cannot be read on the wire, but the client does not check who answers. In our setup the database is only reachable inside a private VPC, so the risk is small. A stricter version downloads the RDS certificate bundle (`global-bundle.pem`), puts it in the zip and loads it with `ssl.create_default_context(cafile=...)`. We keep the simple version for learning.

### The schema

Three tables:

```
users                     tutorials                       ratings
-----                     ---------                       -------
id          UUID  PK      id          SERIAL  PK          tutorial_id INTEGER  PK, FK -> tutorials
email       TEXT          title       VARCHAR(200)        user_id     UUID     PK, FK -> users
created_at  TIMESTAMPTZ   url         TEXT                stars       SMALLINT 1 to 5
                          description TEXT NOT NULL       created_at  TIMESTAMPTZ
                          author_id   UUID  FK -> users
                          created_at  TIMESTAMPTZ
```

| Idea | Meaning |
|---|---|
| **Primary key** | Identifies a row. `ratings` has a **composite** key `(tutorial_id, user_id)`: one rating per user and tutorial |
| **Foreign key** | A column that must point to an existing row of another table. A tutorial needs an existing author in `users` |
| **`CHECK`** | A rule the database enforces: `stars BETWEEN 1 AND 5`, and a description that is not empty |
| **`ON DELETE CASCADE`** | If a tutorial is deleted, its ratings are deleted with it |
| **`IF NOT EXISTS`** | The statement does nothing when the table already exists. This makes `init_db` safe to run twice |

`users.id` is the `sub` claim of the Cognito token, which is a UUID. The `users` table gets its rows in step 8: the handlers insert the user the first time that user writes something.

### Why `init_db` has no route

`init_db` is **not** connected to API Gateway, so nobody on the internet can call it. It is started with the AWS CLI, which needs AWS credentials. Creating tables is an administrator task, and a public route would be a risk.

## 4. The code

Step 7 changes these files:

| File | Change |
|---|---|
| `backend/shared/__init__.py` | stays empty (it makes `shared` a package) |
| `backend/shared/db.py` | from empty to the connection function |
| `backend/init_db/handler.py` | the placeholder of step 5 becomes the real handler |
| `backend/init_db/requirements.txt` | from empty to one line |
| `backend/build.sh` | from empty to the build script |
| `infra/lambda.tf` | four `source_dir` lines |

### `backend/shared/db.py`

`shared/db.py` has been an empty file since step 1. We now fill it with the function that opens the database connection.

```python
import os
import ssl

import pg8000.native


def connect():
    """Open an encrypted connection to the database (settings come from the environment)."""
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE

    return pg8000.native.Connection(
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        host=os.environ["DB_HOST"],
        port=int(os.environ["DB_PORT"]),
        database=os.environ["DB_NAME"],
        ssl_context=context,
        timeout=10,
    )
```

The five `DB_*` variables are the ones that `lambda.tf` has set since step 5. `timeout=10` is the socket timeout in seconds: a hanging connection fails quickly instead of waiting for the whole Lambda timeout. `ensure_user()` is added to this file in step 8.

### `backend/init_db/requirements.txt`

This file has been empty so far, because the placeholders needed no library. From now on `init_db` needs the PostgreSQL driver, so we add one line:

```
pg8000>=1.31,<2
```

The other three `requirements.txt` files stay empty until step 8.

### `backend/init_db/handler.py`

In this step we replace the placeholder in `backend/init_db/handler.py`, which we wrote in step 5, with real code. The placeholder only opened a TCP connection to the database port. The new handler logs in to PostgreSQL through `connect()` from `shared/db.py` and creates the three tables of the app. Because `connect()` opens a real connection, the TCP check is no longer needed. If the network is broken, the login fails with a timeout, just as the TCP check did.

```python
from shared.db import connect

SCHEMA = [
    """
    CREATE TABLE IF NOT EXISTS users (
        id         UUID PRIMARY KEY,
        email      TEXT NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS tutorials (
        id          SERIAL PRIMARY KEY,
        title       VARCHAR(200) NOT NULL,
        url         TEXT NOT NULL,
        description TEXT NOT NULL CHECK (length(trim(description)) > 0),
        author_id   UUID NOT NULL REFERENCES users(id),
        created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS ratings (
        tutorial_id INTEGER NOT NULL REFERENCES tutorials(id) ON DELETE CASCADE,
        user_id     UUID NOT NULL REFERENCES users(id),
        stars       SMALLINT NOT NULL CHECK (stars BETWEEN 1 AND 5),
        created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
        PRIMARY KEY (tutorial_id, user_id)
    )
    """,
]

LIST_TABLES = """
    SELECT table_name
    FROM information_schema.tables
    WHERE table_schema = 'public'
    ORDER BY table_name
"""


def lambda_handler(event, context):
    conn = connect()
    try:
        for statement in SCHEMA:
            conn.run(statement)
        rows = conn.run(LIST_TABLES)
    finally:
        conn.close()
    return {"tables": [row[0] for row in rows]}
```

- The tables are created in an order that respects the foreign keys: `users`, then `tutorials`, then `ratings`.
- One statement per `conn.run()` call keeps the errors easy to read.
- The handler returns a plain dictionary. It is called directly with `aws lambda invoke`, not through API Gateway, so there is no `statusCode`.
- `try ... finally` closes the connection even if a statement fails.

The other three functions keep their step 5 placeholders for now. We replace them with real code in step 8. In this step they are only repackaged by the build script.

### `backend/build.sh`

`backend/build.sh` has been an empty file since step 1. We now fill it with the script that assembles one folder per function.

```bash
#!/usr/bin/env bash
# Builds every function into backend/build/<function>/:
# its own code + its libraries + a copy of shared/. Terraform zips that folder.
set -euo pipefail
cd "$(dirname "$0")"

OUT="build"
rm -rf "$OUT"
mkdir -p "$OUT"

for dir in init_db get_tutorials create_tutorial rate_tutorial; do
  [ -d "$dir" ] || continue
  echo "Building $dir"
  mkdir -p "$OUT/$dir"

  cp "$dir"/*.py "$OUT/$dir/"

  # requirements.txt may be empty (placeholders): install only if it has content
  if [ -s "$dir/requirements.txt" ]; then
    python3 -m pip install --quiet --upgrade --no-compile \
      -r "$dir/requirements.txt" --target "$OUT/$dir"
  fi

  if [ -d shared ]; then
    cp -r shared "$OUT/$dir/shared"
  fi
done

# No bytecode caches in the zips
find "$OUT" -name "__pycache__" -type d -prune -exec rm -rf {} +
echo "Done: $(pwd)/$OUT"
```

The setup script of step 1 already made the file executable. If the permission is missing, `chmod +x backend/build.sh` sets it once.

| Line | Meaning |
|---|---|
| `set -euo pipefail` | Stops at the first error, on unset variables, and on errors inside pipes |
| `cd "$(dirname "$0")"` | Works in the folder of the script, wherever it is started from |
| `rm -rf "$OUT"` | A clean build every time. Files of an old build cannot end up in a zip |
| `cp "$dir"/*.py` | Copies our own code only: the `.py` files of the source folder |
| `[ -s file ]` | True if the file exists **and is not empty**. Empty `requirements.txt` files are skipped |
| `--target "$OUT/$dir"` | Installs the libraries into the function folder, not into the system |
| `--no-compile` and removing `__pycache__` | The zip content stays identical between builds, so Terraform does not see a change without a reason |
| `cp -r shared` | The shared code lands next to `handler.py` |

### `infra/lambda.tf`: four lines change

In step 5 the four `archive_file` blocks pointed to `backend/<function>`. They now point to the build folder:

```hcl
data "archive_file" "get_tutorials_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../backend/build/get_tutorials"
  output_path = "${path.module}/build/get_tutorials.zip"
}

data "archive_file" "init_db_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../backend/build/init_db"
  output_path = "${path.module}/build/init_db.zip"
}

data "archive_file" "create_tutorial_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../backend/build/create_tutorial"
  output_path = "${path.module}/build/create_tutorial.zip"
}

data "archive_file" "rate_tutorial_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../backend/build/rate_tutorial"
  output_path = "${path.module}/build/rate_tutorial.zip"
}
```

The comment above these blocks changes to `# Zips: Terraform packs the folders that backend/build.sh produced`. Nothing else in `lambda.tf` changes.

## 5. Why it is done this way

| Decision | Reason |
|---|---|
| **A build folder separate from the source folders** | Source files and generated libraries stay apart. The `.gitignore` already lists `backend/build/`, and a `pip install` cannot overwrite our own files |
| **`rm -rf build` at the start** | No leftovers from earlier builds. The result depends only on the sources |
| **Terraform fails if `backend/build/` is missing** | `archive_file` reports that `source_dir` does not exist. An unbuilt function cannot be deployed by accident |
| **One `shared/` folder, copied into each package** | The connection code is written once. A zip is self-contained, which Lambda requires |
| **Only `init_db` is real in this step** | If something fails, there are few possible causes: the build, the connection or the schema |
| **`pg8000` instead of `psycopg2`** | Pure Python, so it needs no Linux build and no Lambda layer |
| **`pg8000.native`** | The simple interface: `conn.run("SQL", name=value)` with named parameters. Parameters are never pasted into the SQL text, which prevents SQL injection |
| **SSL context without certificate check** | Encrypts the traffic and needs no certificate file in the zip. A stricter setup is described in section 3 |
| **`CREATE TABLE IF NOT EXISTS`** | `init_db` can run after every new database, and twice in a row, without errors |
| **No migrations tool** | Three tables do not justify one. A real project uses a tool such as Alembic or Flyway to change an existing schema |
| **Constraints in the database** | `NOT NULL`, `CHECK` and foreign keys are the last line of defence. The handlers of step 8 validate input too, but another code path cannot break the rules |
| **`description` is required** | A tutorial without a description is incomplete. The `CHECK` also rejects a text of only spaces |
| **`init_db` has no route** | Creating tables is for administrators. Only someone with AWS credentials can start it |
| **`pg8000>=1.31,<2`** | New minor versions are accepted, a possibly breaking major version is not |

## 6. Run and verify

### Build

```bash
./backend/build.sh
```

The result can be checked:

```bash
ls backend/build/init_db
ls backend/build/get_tutorials
ls backend/build/init_db/shared      # __init__.py  db.py
```

`init_db` shows `handler.py`, `pg8000`, `scramp`, `shared` and a few more library folders. `get_tutorials` shows only `handler.py` and `shared`.

### Plan and apply

```bash
cd infra
tf fmt
tf validate
tf plan -out="actions.tfplan"
```

Expected:

| Situation | Plan |
|---|---|
| The stack is destroyed (state is empty) | **26 to add, 0 to change, 0 to destroy** |
| The stack from step 6 still exists | **0 to add, 4 to change, 0 to destroy**. The four functions get a new package |

Anything with `destroy` or `# forces replacement` is wrong. In that case the plan is read before anything is applied.

An optional check of a zip:

```bash
unzip -l build/init_db.zip | grep -E "handler.py|shared/db.py|pg8000/__init__"
```

```bash
tf apply actions.tfplan
```

If the database is created again, the apply takes 12 to 15 minutes: the database needs 8 to 10 minutes, and the functions add 2 to 3 minutes.

### Test 1: the tables are created

```bash
aws lambda invoke --function-name tutorials-app-init-db \
  --cli-binary-format raw-in-base64-out response.json
cat response.json
```

Expected: `{"tables": ["ratings", "tutorials", "users"]}`.

`StatusCode: 200` in the terminal only says that the call worked, not that the new code ran. The content of `response.json` is what counts: the three table names show the new handler. An answer with `db_host` and `db_reachable` comes from the placeholder of step 5, so the zip holds old code (see section 7). If the terminal output also contains a `FunctionError` field, the function failed and `response.json` holds the error. The logs show more:

```bash
aws logs tail /aws/lambda/tutorials-app-init-db --since 10m
```

### Test 2: it is safe to run twice

The same command runs a second time. The answer is identical, and there is no error. This is the effect of `IF NOT EXISTS`.

### Test 3: the other functions still work

The three placeholders were repackaged too. This test shows that the build did not break them:

```bash
for fn in get-tutorials create-tutorial rate-tutorial; do
  aws lambda invoke --function-name "tutorials-app-$fn" \
    --cli-binary-format raw-in-base64-out response.json > /dev/null
  echo "== $fn"; cat response.json; echo
done
```

Every answer still shows `"db_reachable": true`.

### Test 4 (optional): looking into the database

Test 1 already proves that the tables exist. To see the columns and constraints, a `psql` session **inside the VPC** is needed. The firewall `rds_sg` accepts only `lambda_sg`, so a normal CloudShell cannot connect: the connection times out.

- In CloudShell, a VPC environment is created with the VPC of the project, one private subnet and the security group `tutorials-app-lambda-sg`.
- In that environment, the `psql` command shown in the RDS console connects with `db_password`. Then `\dt` lists the tables and `\d tutorials` shows the columns.
- A hand-made rule in `rds_sg` is not needed. If one was added anyway, it has to be removed before `tf destroy`.

### Commit, merge, tag

```bash
git status                  # no tfvars, no tfstate, no tfplan, no backend/build, no infra/build in the list
git add -A
git commit -m "Step 7: database schema, shared db code and build pipeline"
git switch main
git merge --no-ff step-07-schema-build
git tag -a step-07 -m "Schema and build pipeline"
git push origin main --tags
git branch -d step-07-schema-build
```

`docs/step-07-schema-build.md` is part of this commit.

## 7. Typical problems

Error texts can differ slightly between tool and library versions. The cause column matters more than the exact wording.

| Symptom | Likely cause |
|---|---|
| `tf plan`: `source_dir ... no such file or directory` | `build.sh` was not run, or the path in `lambda.tf` is wrong. `./backend/build.sh` creates the folders |
| `Unable to import module 'handler': No module named 'shared'` | The build did not copy `shared/`, or the zip was made from the source folder. `ls backend/build/init_db/shared` shows which |
| `No module named 'pg8000'` | `requirements.txt` is empty or has a typo, or the pip step failed. The output of `build.sh` shows the error |
| `KeyError: 'DB_HOST'` in the logs | The environment variables are missing. `local.db_environment` in `lambda.tf` (step 5) defines them |
| The connection hangs and ends with `timed out` | A network problem. `lambda_sg`, `rds_sg` and the port are the places to look. The TCP check of step 5 tests exactly this |
| An error saying the server requires encryption (SSL) | The SSL context was not passed to `Connection`. The line `ssl_context=context` in `db.py` is the one that matters |
| `password authentication failed for user` | `DB_PASSWORD` does not match the password the database was created with. After correcting `terraform.tfvars`, a new plan and apply update the functions |
| `database "..." does not exist` | `DB_NAME` differs from `db_name` of step 4 |
| `relation "users" does not exist` when creating `tutorials` | The statements ran in the wrong order. `users` has to come first in the list |
| `pip install` says `externally-managed-environment` | The Python installation blocks installs. A virtual environment avoids this: `python3 -m venv .venv && source .venv/bin/activate` |
| The answer of `init_db` still shows `db_host` and `db_reachable` | The zip was made from the wrong folder, and it holds the placeholder of step 5. The four `source_dir` lines in `lambda.tf` have to point to four different folders under `backend/build/`. `unzip -p infra/build/init_db.zip handler.py` shows which code is inside |
| `tf plan` shows a change on a function that was not touched | The zip content changed. `build.sh` removes `__pycache__` and uses `--no-compile`, so a change means that files changed. A new build and a comparison show which |
| `Uploaded file must be a non-empty zip` | A `handler.py` is empty, so `build/<function>` has no content. `wc -l backend/*/handler.py` shows it |
| `Saved plan is stale` | The plan file was already applied, or the state changed after the plan was made. A new `tf plan -out=...` and the apply of that new file solve it |
| The editor underlines `from shared.db import connect` | Only cosmetic. The `.vscode/settings.json` of section 3 removes it |
| `tf destroy` waits 10 to 20 minutes or more on the subnets and `lambda_sg` | Lambda releases the network interfaces of deleted functions late. They can be listed with `aws ec2 describe-network-interfaces --filters "Name=subnet-id,Values=<subnet ids>"`. Interfaces with the status `available` can be deleted with `aws ec2 delete-network-interface --network-interface-id eni-...`. `tf destroy` then continues |

## 8. Cost and cleanup

No new resource, so no new cost. The database from step 4 is still the costly part. `tf destroy` ends every session:

```bash
tf destroy
```

The tables disappear with the database. `init_db` recreates them in seconds after the next apply. Destroying the network can take a long time (last row of section 7), and the terminal can stay open meanwhile.

## 9. What to remember

- A Lambda package is a **zip with everything**: code, libraries and shared code. The build script assembles one folder per function in `backend/build/`.
- The source folders stay clean. `backend/build/` is generated and ignored by Git.
- `./backend/build.sh` runs **before** every `tf plan` after a code change.
- In the zip, `shared/` sits next to `handler.py`, so `from shared.db import connect` works.
- `pg8000` is pure Python, so a zip built on a laptop runs on Lambda.
- PostgreSQL 16 on RDS needs SSL. The SSL context here encrypts but does not verify the certificate.
- `CREATE TABLE IF NOT EXISTS` makes `init_db` safe to repeat. Constraints in the database are the last line of defence.
- `init_db` has no route. Only people with AWS credentials can run it.
- The answer `{"tables": [...]}` is the first real login to the database.

## 10. Next step

Step 8 adds the real handlers: `create_tutorial`, `get_tutorials` (list and one tutorial) and `rate_tutorial`. It extends `shared/` with `ensure_user()` and `responses.py`, validates the input, and adds the remaining routes `GET /tutorials/{id}`, `POST /tutorials` and `POST /tutorials/{id}/rating`. That brings the project to **33 resources**. The tests use Lambda console events first, and `curl` with a token after that.
