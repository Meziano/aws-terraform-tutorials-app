# Step 5: Lambda, the functions and their IAM role

## 1. What are we going to build?

In this step the app gets its **business logic**: four **AWS Lambda** functions. A Lambda function is a piece of code that AWS runs when something calls it. There is no server to manage, and the bill follows the number of calls.

The functions need two things before they can do anything useful:

- an **IAM role**, which says what the functions are allowed to do in AWS,
- a place in the **private network** of step 3, from which they can reach the database of step 4.

Six Terraform resources are created:

| # | Resource | Job |
|---|---|---|
| 1 | `aws_iam_role` | The identity of the functions. Lambda may "put on" this role |
| 2 | `aws_iam_role_policy_attachment` | Gives the role the right to write logs and to create network interfaces in the VPC |
| 3 | `aws_lambda_function` `get_tutorials` | List and detail of tutorials |
| 4 | `aws_lambda_function` `init_db` | Creates the tables |
| 5 | `aws_lambda_function` `create_tutorial` | Adds a tutorial |
| 6 | `aws_lambda_function` `rate_tutorial` | Rates a tutorial |

Four `archive_file` data sources also appear. They create the zip files and are not counted as resources.

Together with steps 2, 3 and 4 the project now has **20 resources**.

**All four functions are placeholders in this step.** Each one does a single thing: it opens a plain TCP connection to the database port and reports the result. The real code follows later: `init_db` in step 7 and the other three functions in step 8. This keeps step 5 about the infrastructure: role, network placement, environment variables and packaging.

At the end of this step:

- the four functions have the status `Active`,
- each one runs inside the private subnets with `lambda_sg`,
- an invocation shows `"db_reachable": true`. That is the first proof that the whole chain `lambda_sg` -> `rds_sg` -> RDS works.

## 2. Prerequisites

- Step 4 is done and merged: `main` contains the tag `step-04`. The functions need the subnets, `lambda_sg` and the database address.
- If the stack was destroyed after step 4, the plan below shows **20 to add** instead of 6. The database is created again and takes 8 to 10 minutes, and the functions add about 2 to 3 minutes. Cognito also gets new IDs (see step 2).

- The AWS credentials work:

```bash
aws sts get-caller-identity
```

- The step starts on its own branch:

```bash
git switch main
git switch -c step-05-lambda
```

## 3. The concepts

### What is a Lambda function?

```
event (a JSON document)  --->  handler function  --->  result (a JSON document)
```

| Term | Meaning |
|---|---|
| **Handler** | The Python function that Lambda calls. In `handler = "handler.lambda_handler"` the part before the dot is the file `handler.py`, the part after the dot is the function `lambda_handler` |
| **Event** | The input. For a direct invocation it is what the caller sends. Behind API Gateway (step 6) it describes the HTTP request |
| **Context** | Information about the running invocation (function name, remaining time) |
| **Runtime** | The language environment, here Python 3.12 |
| **Deployment package** | A zip file with the code (and its libraries). Lambda unpacks it when the function starts. It must contain at least one file with content |
| **Cold start** | The first call after a pause. AWS prepares a new environment, which takes extra time |

### The IAM role: two policies

A role has two kinds of rules, and they answer two different questions:

| Policy | Question | In our code |
|---|---|---|
| **Trust policy** (`assume_role_policy`) | **Who** may use this role? | Only the Lambda service (`lambda.amazonaws.com`) |
| **Permission policy** (the attachment) | **What** may the role do? | `AWSLambdaVPCAccessExecutionRole`, a policy managed by AWS |

`AWSLambdaVPCAccessExecutionRole` allows the writing of logs to CloudWatch (`logs:CreateLogGroup`, `CreateLogStream`, `PutLogEvents`) and the handling of network interfaces (`ec2:CreateNetworkInterface`, `DescribeNetworkInterfaces`, `DeleteNetworkInterface` and a few more). Nothing else. The functions cannot read S3, send e-mails or touch Cognito. If a function ever needs more, a policy is added on purpose.

### A function inside the VPC

When a function has a `vpc_config`, Lambda creates a **network interface** (ENI) for it in the subnets that are listed.

```
Lambda function  --- ENI in private_a / private_b, carries lambda_sg --->  RDS (rds_sg allows lambda_sg)
```

- The ENI carries the security group `lambda_sg`. This is what lets the traffic pass the rule of `rds_sg`.
- **Both** subnets are listed. Lambda then works in both zones, and keeps working if one zone has a problem.
- The function can reach **only the VPC**. It has no internet and no access to other AWS APIs, because step 3 built no NAT gateway. Our functions need nothing else.
- The role needs the ENI permissions from the managed policy, otherwise the function cannot be created.
- Starting a function is not a network connection into the VPC. `aws lambda invoke` and, later, API Gateway call the Lambda **service**, which then runs the function. So a function can be invoked from a laptop although the VPC is private.

### Environment variables

The functions learn where the database is from environment variables: `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`. Terraform fills them from the database resource and the variables of step 4. Three consequences follow:

- `DB_HOST` comes from the database, so Terraform creates the functions **after** the database. A fresh `apply` therefore waits for RDS.
- Environment variable values are always strings, so the port is converted with `tostring()`.
- The password is visible in the Lambda console and in the state. That is acceptable for learning and wrong for production (see section 5).

### Packaging: `archive_file` and `source_code_hash`

Terraform zips the code folder with the `archive_file` data source. The function then needs two lines:

```hcl
filename         = data.archive_file.get_tutorials_zip.output_path
source_code_hash = data.archive_file.get_tutorials_zip.output_base64sha256
```

`source_code_hash` is the fingerprint of the zip. If the code changes, the fingerprint changes, and Terraform updates the function. Without it, Terraform would not notice a code change.

**A zip of empty files is refused.** The setup script of step 1 creates every `handler.py` as an empty file. Terraform zips such a folder without complaint, but Lambda rejects the upload with `Uploaded file must be a non-empty zip`. Every function folder therefore needs real content before the plan (see section 6, "Before the plan").

In this step the zip is made directly from `backend/<function>/`, because the placeholders need no libraries. In step 7 the source folder changes to `backend/build/<function>/`, which also holds the libraries and the shared code.

## 4. The code

Step 5 changes three files in `infra/` and fills the four handlers in `backend/`.

### `infra/main.tf` (the `archive` provider is added)

```hcl
terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.0"
    }
  }
}
```

The rest of the file (`provider "aws"` and `locals`) stays as it was. A new `tf init` downloads the new provider.

### `infra/variables.tf` (added at the end)

```hcl
variable "lambda_runtime" {
  description = "Python runtime of the Lambda functions"
  type        = string
  default     = "python3.12"
}
```

### `backend/get_tutorials/handler.py`

```python
import json
import os
import socket


def lambda_handler(event, context):
    host = os.environ["DB_HOST"]
    port = int(os.environ["DB_PORT"])

    # Plain TCP connection: proves the network path, no login, no SQL.
    try:
        with socket.create_connection((host, port), timeout=5):
            reachable, error = True, None
    except OSError as exc:
        reachable, error = False, str(exc)

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({
            "function": os.environ["AWS_LAMBDA_FUNCTION_NAME"],
            "db_host": host,
            "db_port": port,
            "db_reachable": reachable,
            "error": error,
        }),
    }
```

The handler reads the database address from the environment, tries to open a TCP connection to it and returns the result as JSON. `socket` is part of Python, so no library is needed. A TCP connection is **not** a database login. It only shows that a packet can travel from the function to the database port and be answered.

The other three functions (`init_db`, `create_tutorial`, `rate_tutorial`) get the same placeholder. The copy command is in section 6 under "Before the plan". The `requirements.txt` files stay empty, because the placeholders use no library.

### `infra/lambda.tf`

```hcl
# ---------------------------------------------------------------------------
# IAM: what the functions may do (one role for all four)
# ---------------------------------------------------------------------------

resource "aws_iam_role" "lambda_role" {
  name = "${var.project_name}-lambda-role"

  # Trust policy: only the Lambda service may use this role
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = local.common_tags
}

# Permission policy managed by AWS: write logs and manage network interfaces in the VPC
resource "aws_iam_role_policy_attachment" "lambda_vpc_access" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# ---------------------------------------------------------------------------
# Settings that all four functions share
# ---------------------------------------------------------------------------

locals {
  db_environment = {
    DB_HOST     = aws_db_instance.tutorials_db.address
    DB_PORT     = tostring(var.db_port)
    DB_NAME     = var.db_name
    DB_USER     = var.db_username
    DB_PASSWORD = var.db_password
  }
}

# ---------------------------------------------------------------------------
# Zips: Terraform packs the code folders
# (step 7 changes source_dir to ../backend/build/<function>)
# ---------------------------------------------------------------------------

data "archive_file" "get_tutorials_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../backend/get_tutorials"
  output_path = "${path.module}/build/get_tutorials.zip"
}

data "archive_file" "init_db_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../backend/init_db"
  output_path = "${path.module}/build/init_db.zip"
}

data "archive_file" "create_tutorial_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../backend/create_tutorial"
  output_path = "${path.module}/build/create_tutorial.zip"
}

data "archive_file" "rate_tutorial_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../backend/rate_tutorial"
  output_path = "${path.module}/build/rate_tutorial.zip"
}

# ---------------------------------------------------------------------------
# The functions
# ---------------------------------------------------------------------------

# The first function: GET /tutorials (from step 6 on) and GET /tutorials/{id} (from step 8 on)

resource "aws_lambda_function" "get_tutorials" {
  function_name = "${var.project_name}-get-tutorials"
  role          = aws_iam_role.lambda_role.arn
  runtime       = var.lambda_runtime
  handler       = "handler.lambda_handler"
  timeout       = 10
  memory_size   = 128

  filename         = data.archive_file.get_tutorials_zip.output_path
  source_code_hash = data.archive_file.get_tutorials_zip.output_base64sha256

  vpc_config {
    subnet_ids         = [aws_subnet.private_a.id, aws_subnet.private_b.id]
    security_group_ids = [aws_security_group.lambda_sg.id]
  }

  environment {
    variables = local.db_environment
  }

  # The role needs its permissions BEFORE the function is created
  depends_on = [aws_iam_role_policy_attachment.lambda_vpc_access]

  tags = local.common_tags
}

# Creates the tables (used once after each new database)
resource "aws_lambda_function" "init_db" {
  function_name = "${var.project_name}-init-db"
  role          = aws_iam_role.lambda_role.arn
  runtime       = var.lambda_runtime
  handler       = "handler.lambda_handler"
  timeout       = 30 # the first connection can be slow
  memory_size   = 128

  filename         = data.archive_file.init_db_zip.output_path
  source_code_hash = data.archive_file.init_db_zip.output_base64sha256

  vpc_config {
    subnet_ids         = [aws_subnet.private_a.id, aws_subnet.private_b.id]
    security_group_ids = [aws_security_group.lambda_sg.id]
  }

  environment {
    variables = local.db_environment
  }

  depends_on = [aws_iam_role_policy_attachment.lambda_vpc_access]

  tags = local.common_tags
}

# POST /tutorials (from step 8 on)
resource "aws_lambda_function" "create_tutorial" {
  function_name = "${var.project_name}-create-tutorial"
  role          = aws_iam_role.lambda_role.arn
  runtime       = var.lambda_runtime
  handler       = "handler.lambda_handler"
  timeout       = 10
  memory_size   = 128

  filename         = data.archive_file.create_tutorial_zip.output_path
  source_code_hash = data.archive_file.create_tutorial_zip.output_base64sha256

  vpc_config {
    subnet_ids         = [aws_subnet.private_a.id, aws_subnet.private_b.id]
    security_group_ids = [aws_security_group.lambda_sg.id]
  }

  environment {
    variables = local.db_environment
  }

  depends_on = [aws_iam_role_policy_attachment.lambda_vpc_access]

  tags = local.common_tags
}

# POST /tutorials/{id}/rating (from step 8 on)
resource "aws_lambda_function" "rate_tutorial" {
  function_name = "${var.project_name}-rate-tutorial"
  role          = aws_iam_role.lambda_role.arn
  runtime       = var.lambda_runtime
  handler       = "handler.lambda_handler"
  timeout       = 10
  memory_size   = 128

  filename         = data.archive_file.rate_tutorial_zip.output_path
  source_code_hash = data.archive_file.rate_tutorial_zip.output_base64sha256

  vpc_config {
    subnet_ids         = [aws_subnet.private_a.id, aws_subnet.private_b.id]
    security_group_ids = [aws_security_group.lambda_sg.id]
  }

  environment {
    variables = local.db_environment
  }

  depends_on = [aws_iam_role_policy_attachment.lambda_vpc_access]

  tags = local.common_tags
}
```

`infra/outputs.tf` does not change in this step.

## 5. Why it is done this way

| Decision | Reason |
|---|---|
| **One role for all four functions** | They need the same rights, and one role is easier to read. A production setup gives each function its own role with only the rights it needs (least privilege) |
| **The managed policy `AWSLambdaVPCAccessExecutionRole`** | It contains exactly what a function in a VPC needs, and AWS maintains it. The JSON does not have to be written by hand |
| **`depends_on` the policy attachment** | Terraform sees the dependency on the role, but not on the attachment. Without `depends_on`, a function may be created before the role has its permissions, and AWS then refuses with an error about `CreateNetworkInterface`. It also makes `tf destroy` remove the functions before the permissions |
| **Explicit blocks instead of `for_each`** | Four blocks are longer, but each one is easy to read and has a stable address (`aws_lambda_function.get_tutorials`) that API Gateway refers to. `for_each` over a map is a good refactoring once the pattern is clear |
| **A `locals` block for the environment** | The five variables are written once, and a change reaches all four functions |
| **All four functions now, placeholders for all** | The role, the network placement and the environment are identical for all of them, so they belong to the infrastructure step. The later steps only replace code |
| **A TCP check as the placeholder** | It proves the security group chain without any library, SSL or password. It is also real content, which Lambda needs in the zip |
| **`runtime` as a variable** | One place changes when the project moves to a newer Python version. The Lambda documentation lists the supported runtimes and their end-of-support dates |
| **Subnets in both zones** | The functions survive the failure of one zone |
| **`memory_size = 128`, `timeout = 10`** | The smallest memory is enough for a database call, and 10 seconds are plenty. `init_db` gets 30, because the first connection to a new database can be slow |
| **Password in an environment variable** | Simple, and enough for learning. A real application stores it in AWS Secrets Manager and lets the function read it at start, or uses IAM authentication to the database |
| **Zips in `infra/build/`** | Generated files stay out of the source folders. The `.gitignore` of step 1 ignores this folder |
| **Placeholders in `backend/<function>/`** | They need no libraries, so the zip comes straight from the source folder. The build script follows in step 7 |

## 6. Run and verify

### Before the plan: filling the four handlers

The setup script of step 1 created `handler.py` and `requirements.txt` as **empty files**. `get_tutorials` already has the placeholder from section 4. We copy it into the other three folders:

```bash
cd ..    # to the repository root, if the shell is still in infra/
for fn in init_db create_tutorial rate_tutorial; do
  cp backend/get_tutorials/handler.py "backend/$fn/handler.py"
done
wc -l backend/*/handler.py
```

All four `handler.py` files must show more than 0 lines. Without this, Terraform plans without complaint, and the apply fails halfway:

```
InvalidParameterValueException: Uploaded file must be a non-empty zip
```

By then the network, Cognito and the **database** already exist, so RDS runs and costs money while the problem is fixed (see section 7).

### Plan and apply

```bash
cd infra
tf init           # downloads the archive provider
tf fmt
tf validate
tf plan -out="actions.tfplan"
```

Expected: **6 to add, 0 to change, 0 to destroy**. The resources of steps 2 to 4 do not appear in the plan. The four `archive_file` data sources appear as "read" and are not counted. A plan with 20 to add means that the state is empty (see section 2).

An optional check of the zips that the plan created:

```bash
unzip -l build/init_db.zip      # lists handler.py with a size above 0
```

```bash
tf apply actions.tfplan
```

Functions in a VPC take longer to create than normal ones, because Lambda prepares the network interfaces. A single function can take two minutes or more. If the database was destroyed before, the apply first waits for it (about 8 to 10 minutes).

### Test 1: the configuration

```bash
aws lambda get-function-configuration --function-name tutorials-app-get-tutorials \
  --query "[State,Runtime,Handler,VpcConfig.SubnetIds,VpcConfig.SecurityGroupIds]" --output json

tf output lambda_sg_id
```

Expected: `Active`, `python3.12`, `handler.lambda_handler`, **two** subnet IDs, and a security group ID that equals `lambda_sg_id`.

### Test 2: the first real connection

```bash
aws lambda invoke --function-name tutorials-app-get-tutorials \
  --cli-binary-format raw-in-base64-out response.json
cat response.json
```

`StatusCode: 200` in the terminal only says that the call worked. The answer of the function is in `response.json`. Expected:

```
{"statusCode": 200, "headers": {...}, "body": "{\"function\": \"tutorials-app-get-tutorials\", \"db_host\": \"tutorials-app-db....rds.amazonaws.com\", \"db_port\": 5432, \"db_reachable\": true, \"error\": null}"}
```

`"db_reachable": true` is the result we wanted. It shows that DNS, the subnets, `lambda_sg` and the rule of `rds_sg` all work together. If the terminal output contains a `FunctionError` field, the function itself failed (see section 7).

The other three functions are tested the same way:

```bash
for fn in init-db create-tutorial rate-tutorial; do
  aws lambda invoke --function-name "tutorials-app-$fn" \
    --cli-binary-format raw-in-base64-out response.json > /dev/null
  echo "== $fn"; cat response.json; echo
done
```

Every answer shows `"db_reachable": true`.

### Test 3: the logs

```bash
aws logs tail /aws/lambda/tutorials-app-get-tutorials --since 10m
```

The output has the lines `START`, `END` and `REPORT` with the duration and the memory used. Lambda creates the log group at the first call. Logging works without internet access, because the Lambda service writes the logs and not the function.

### Test 4: the stored environment

```bash
aws lambda get-function-configuration --function-name tutorials-app-get-tutorials \
  --query "Environment.Variables" --output json
```

The output contains `DB_PASSWORD` in plain text, so it is never pasted into a chat, a ticket or a repository. This is why the console and the state need protection, and why a real application would use Secrets Manager.

### Commit, merge, tag

```bash
git status                  # no tfvars, no tfstate, no tfplan, no infra/build in the list
git add -A
git commit -m "Step 5: IAM role and four Lambda functions in the VPC (placeholders)"
git switch main
git merge --no-ff step-05-lambda
git tag -a step-05 -m "Lambda functions"
git push origin main --tags
git branch -d step-05-lambda
```

`infra/.terraform.lock.hcl` belongs in this commit, because it now also pins the `archive` provider. So does `docs/step-05-lambda.md`.

## 7. Typical problems

Error texts can differ slightly between tool versions. The cause column matters more than the exact wording.

| Symptom | Likely cause |
|---|---|
| `InvalidParameterValueException: Uploaded file must be a non-empty zip` on `CreateFunction` | The `handler.py` of that function is still **empty**, because the setup script creates empty files. After copying the placeholder (section 6, "Before the plan") and checking with `wc -l`, a new plan and apply succeed |
| `tf apply` stopped halfway, some functions are created and others are not | Terraform keeps what it created. The network, Cognito and the **database** exist already, so RDS costs money until it is destroyed. After fixing the cause, a **new** `tf plan` lists only the missing resources, and applying that plan finishes the job |
| `Saved plan is stale` | The state changed after the plan was made, for example by a partial apply, or the plan file was already applied. A new `tf plan -out=...` and the apply of that new file solve it |
| `The provided execution role does not have permissions to call CreateNetworkInterface on EC2` | The permissions were not in place when the function was created. The `depends_on` line prevents it. A new `tf apply` usually succeeds, because IAM changes take a few seconds to spread |
| `Error: ... archive_file ... no such file or directory` | `source_dir` points to a folder that does not exist. The folder names are singular: `create_tutorial`, `rate_tutorial` |
| The answer of an invocation contains an error about importing the module `handler` | `handler.py` is misnamed or in a subfolder, so Lambda cannot find the file named in `handler = "handler.lambda_handler"` |
| `KeyError: 'DB_HOST'` in the logs | The environment variables are missing. The `environment` block and `local.db_environment` show why |
| `"db_reachable": false` with `timed out` | The packets are dropped. Test 1 shows whether the function carries `lambda_sg`. `rds_sg` has to allow port 5432 from it (step 3, test 4), and the functions and the database have to use the same port |
| `"db_reachable": false` with `Name or service not known` | The host name cannot be resolved. `enable_dns_support` and `enable_dns_hostnames` of the VPC (step 3) are the settings to check |
| `Task timed out after ... seconds` | The `timeout` is too short, or a connection hangs. The placeholder waits at most 5 seconds |
| `ResourceConflictException` or "function already exists" | A function with this name exists, for example from a stack in another folder. It has to be destroyed there first |
| `tf plan` wants to update a function although nothing was changed | The zip content changed. Running Python locally in a function folder creates `__pycache__`, which ends up in the zip. Deleting that folder helps, and so does the build folder of step 7 |
| `tf destroy` waits 10 to 20 minutes or more on the subnets and `lambda_sg` | Lambda releases the network interfaces of deleted functions late, and AWS does not delete a subnet or security group that an interface still uses. The interfaces can be listed with `aws ec2 describe-network-interfaces --filters "Name=subnet-id,Values=<subnet ids>"`. Interfaces with the status `available` can be deleted with `aws ec2 delete-network-interface --network-interface-id eni-...`. `tf destroy` then continues. The description of such an interface starts with `AWS Lambda VPC ENI` |
| `tf destroy` stops with `DependencyViolation` on a subnet or a security group | Same cause as above. After the interfaces are gone, `tf destroy` runs again and continues where it stopped |
| The log groups are still there after `tf destroy` | Lambda created them, not Terraform. `aws logs delete-log-group --log-group-name /aws/lambda/tutorials-app-get-tutorials` removes one |
| No internet in the function | By design. The subnets have no NAT gateway |

## 8. Cost and cleanup

Lambda is billed per call and per running time. There is a monthly free tier, which a learning project does not exceed. The current figures are on the Lambda pricing page. Attaching a function to a VPC has no charge of its own. Charges would come from a NAT gateway, which this setup does not have. Logs cost a small amount per GB. The roles and the zips are free.

The costly part of the project is still the database from step 4. `tf destroy` ends each session. The functions are removed with everything else, and the next `apply` creates them again.

The destroy of the network can take a long time because of the leftover network interfaces (last rows of section 7). The terminal can stay open while the interfaces are released.

## 9. What to remember

- A Lambda function is code plus a **handler** (`file.function`), a **runtime** and a **role**.
- The role has a **trust policy** (who may use it) and **permission policies** (what it may do).
- A function in a VPC gets network interfaces in the subnets and carries `lambda_sg`. Both subnets are listed.
- Without a NAT gateway the functions reach only the VPC. `aws lambda invoke` still works, because it calls the Lambda service.
- `source_code_hash` makes Terraform notice code changes. `depends_on` the attachment avoids a race with the permissions.
- **A zip of empty files is refused by Lambda.** `tf plan` does not catch this, only `tf apply` does, and by then the database already runs. `wc -l backend/*/handler.py` before the plan prevents it.
- Environment variables carry the database address. The password in them is a learning shortcut.
- `"db_reachable": true` proves the chain `lambda_sg` -> `rds_sg` -> RDS. A real login (SSL, user, password, SQL) follows in step 7.
- Destroying functions in a VPC can leave network interfaces behind for a while. They block the subnets until AWS releases them or they are deleted.

## 10. Next step

Step 6 fills `infra/api_gateway.tf`: an HTTP API with a JWT authorizer that checks the Cognito token, a route to `get_tutorials`, a stage and the permission that lets API Gateway start the function. After it, `curl` without a token answers `401`. Step 7 then adds the database schema, the shared code and the build script, and step 8 the real handlers and the remaining routes.
