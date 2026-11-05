# Step 5: Lambda, the functions and their IAM role

## 1. What are we going to build?

In this step the app gets its **business logic**: four **AWS Lambda** functions. A Lambda function is a piece of code that AWS runs when something calls it. There is no server to manage, and you pay per call.

The functions need two things before they can do anything useful:

- an **IAM role**, which says what the functions are allowed to do in AWS,
- a place in the **private network** of step 3, from which they can reach the database of step 4.

Six Terraform resources are created:

| # | Resource | Job |
|---|---|---|
| 1 | `aws_iam_role` | The identity of the functions. Lambda may "put on" this role |
| 2 | `aws_iam_role_policy_attachment` | Gives the role the right to write logs and to create network interfaces in the VPC |
| 3 | `aws_lambda_function` `get_tutorials` | The first function: list and detail of tutorials |
| 4 | `aws_lambda_function` `init_db` | Creates the tables |
| 5 | `aws_lambda_function` `create_tutorial` | Adds a tutorial |
| 6 | `aws_lambda_function` `rate_tutorial` | Rates a tutorial |

Four `archive_file` data sources also appear. They create the zip files and are not counted as resources.

Together with steps 2, 3 and 4 the project now has **20 resources**.

**All four functions are placeholders in this step.** Each one does a single thing: it opens a plain TCP connection to the database port and reports the result. The real code (SQL, validation, the shared library) comes in step 7. This keeps step 5 about the infrastructure: role, network placement, environment variables and packaging.

At the end of this step:

- the four functions have the status `Active`,
- each one runs inside the private subnets with `lambda_sg`,
- an invocation shows `"db_reachable": true`. That is the first proof that the whole chain `lambda_sg` -> `rds_sg` -> RDS works.

## 2. Prerequisites

- Step 4 is done and merged: `main` contains the tag `step-04`. The functions need the subnets, `lambda_sg` and the database address.
- If you destroyed the stack after step 4, the plan below shows **20 to add** instead of 6. The database is created again and takes about 8 minutes. Cognito also gets new IDs (see step 2).
- The AWS credentials work:

```bash
aws sts get-caller-identity
```

- Start the step on its own branch:

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
| **Event** | The input. For a direct invoke it is what you send. Behind API Gateway (step 6) it describes the HTTP request |
| **Context** | Information about the running invocation (function name, remaining time) |
| **Runtime** | The language environment, here Python 3.12 |
| **Deployment package** | A zip file with your code (and its libraries). Lambda unpacks it when the function starts. It must contain at least one file with content |
| **Cold start** | The first call after a pause. AWS prepares a new environment, which takes extra time |

### The IAM role: two policies

A role has two kinds of rules, and they answer two different questions:

| Policy | Question | In our code |
|---|---|---|
| **Trust policy** (`assume_role_policy`) | **Who** may use this role? | Only the Lambda service (`lambda.amazonaws.com`) |
| **Permission policy** (the attachment) | **What** may the role do? | `AWSLambdaVPCAccessExecutionRole`, a policy managed by AWS |

`AWSLambdaVPCAccessExecutionRole` allows the writing of logs to CloudWatch (`logs:CreateLogGroup`, `CreateLogStream`, `PutLogEvents`) and the handling of network interfaces (`ec2:CreateNetworkInterface`, `DescribeNetworkInterfaces`, `DeleteNetworkInterface` and a few more). Nothing else. The functions cannot read S3, send e-mails or touch Cognito. If a function ever needs more, you add a policy on purpose.

### A function inside the VPC

When a function has a `vpc_config`, Lambda creates a **network interface** (ENI) for it in the subnets you list.

```
Lambda function  --- ENI in private_a / private_b, carries lambda_sg --->  RDS (rds_sg allows lambda_sg)
```

- The ENI carries the security group `lambda_sg`. This is what lets the traffic pass the rule of `rds_sg`.
- You list **both** subnets. Lambda then works in both zones, and keeps working if one zone has a problem.
- The function can reach **only the VPC**. No internet, no other AWS API, because step 3 built no NAT gateway. Our functions need nothing else.
- The role needs the ENI permissions from the managed policy, otherwise the function cannot be created.
- Starting a function is not a network connection into the VPC. `aws lambda invoke` and, later, API Gateway call the Lambda **service**, which then runs the function. So you can invoke the function from your laptop although the VPC is private.

### Environment variables

The functions learn where the database is from environment variables: `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`. Terraform fills them from the database resource and the variables of step 4. Two consequences:

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

**A zip of empty files is refused.** The setup script of step 1 creates every `handler.py` as an empty file. Terraform happily zips such a folder, but Lambda rejects the upload with `Uploaded file must be a non-empty zip`. So every function folder needs real content before the plan (see section 6, "Before the plan").

In this step the zip is made directly from `backend/<function>/`, because the placeholders need no libraries. In step 7 the source folder changes to `backend/build/<function>/`, which also holds the libraries and the shared code.

## 4. The code

Step 5 changes five files in `infra/` and the four handlers in `backend/`.

### `infra/main.tf` (add the `archive` provider)

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

The rest of the file (`provider "aws"` and `locals`) stays as it was. Run `tf init` again afterwards, because a new provider has to be downloaded.

### `infra/variables.tf` (add at the end)

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

What it does: it reads the database address from the environment, tries to open a TCP connection to it and returns the result as JSON. `socket` is part of Python, so no library is needed. A TCP connection is **not** a database login. It only shows that a packet can travel from the function to the database port and be answered.

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

# The first function: GET /tutorials and GET /tutorials/{id} (from step 6 on)
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

# POST /tutorials (from step 7 on)
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

# POST /tutorials/{id}/rating (from step 7 on)
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
| **One role for all four functions** | They need the same rights. One role is easier to read. A production setup gives each function its own role with only the rights it needs (least privilege). |
| **The managed policy `AWSLambdaVPCAccessExecutionRole`** | It contains exactly what a function in a VPC needs, and AWS maintains it. We do not write the JSON ourselves. |
| **`depends_on` the policy attachment** | Terraform sees the dependency on the role, but not on the attachment. Without `depends_on`, it may create a function before the role has its permissions. AWS then refuses with an error about `CreateNetworkInterface`. It also makes `tf destroy` remove the functions before the permissions. |
| **Explicit blocks instead of `for_each`** | Four blocks are longer, but each one is easy to read and has a stable address (`aws_lambda_function.get_tutorials`) that API Gateway refers to. `for_each` over a map is a good refactoring once you know the pattern. |
| **A `locals` block for the environment** | The five variables are written once. A change reaches all four functions. |
| **All four functions now, placeholders for all** | The role, the network placement and the environment are identical for all of them, so they belong to the infrastructure step. Step 7 only replaces code. |
| **A TCP check as the placeholder** | A test with value: it proves the security group chain without any library, SSL or password. It is also real content, which Lambda needs in the zip. |
| **`runtime` as a variable** | One place to change when you move to a newer Python version. I checked the AWS documentation: `python3.12` is supported until the end of October 2028, and newer runtimes exist. |
| **Subnets in both zones** | The functions survive the failure of one zone. |
| **`memory_size = 128`, `timeout = 10`** | The smallest memory is enough for a database call. 10 seconds are plenty. `init_db` gets 30, because the first connection of a new database can be slow. |
| **Password in an environment variable** | Simple, and enough for learning. A real application would store it in AWS Secrets Manager and let the function read it at start, or use IAM authentication to the database. |
| **Zips in `infra/build/`** | Generated files are kept out of the source folders. The `.gitignore` of step 1 ignores this folder. |
| **Placeholders in `backend/<function>/`** | They need no libraries, so the zip can come straight from the source folder. No build script yet. |

## 6. Run and verify

### Before the plan: fill the four handlers

The setup script of step 1 created `handler.py` and `requirements.txt` as **empty files**. `get_tutorials` already has the placeholder from section 4. Copy it into the other three folders:

```bash
cd ..    # to the repository root, if you are still in infra/
for fn in init_db create_tutorial rate_tutorial; do
  cp backend/get_tutorials/handler.py "backend/$fn/handler.py"
done
wc -l backend/*/handler.py
```

All four `handler.py` files must show more than 0 lines. Without this, Terraform plans without complaint, and the apply fails halfway:

```
InvalidParameterValueException: Uploaded file must be a non-empty zip
```

By then the network, Cognito and the **database** already exist, so RDS runs and costs money while you fix the problem (see section 7).

### Plan and apply

```bash
cd infra
tf init           # downloads the archive provider
tf fmt
tf validate
tf plan -out="actions.tfplan"
```

Expected: **6 to add, 0 to change, 0 to destroy**. The resources of steps 2 to 4 must not be in the plan. The four `archive_file` data sources appear as "read" and are not counted. If the plan shows 20 to add, the state is empty (see section 2).

Optional check of the zips that the plan created:

```bash
unzip -l build/init_db.zip      # must list handler.py with a size above 0
```

```bash
tf apply actions.tfplan
```

Functions in a VPC take a little longer to create than normal ones, because Lambda prepares the network interfaces. In our test the first function took 2 minutes 12 seconds. If the database was destroyed before, the apply first waits for it (about 8 minutes).

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

Do the same for the other three:

```bash
for fn in init-db create-tutorial rate-tutorial; do
  aws lambda invoke --function-name "tutorials-app-$fn" \
    --cli-binary-format raw-in-base64-out response.json > /dev/null
  echo "== $fn"; cat response.json; echo
done
```

Every answer must show `"db_reachable": true`.

### Test 3: the logs

```bash
aws logs tail /aws/lambda/tutorials-app-get-tutorials --since 10m
```

You see the lines `START`, `END` and `REPORT` with the duration and the memory used. The log group is created by Lambda at the first call. It works without internet, because the Lambda service writes the logs, not your function.

### Test 4: look at what is stored (do not paste the output anywhere)

```bash
aws lambda get-function-configuration --function-name tutorials-app-get-tutorials \
  --query "Environment.Variables" --output json
```

The output contains `DB_PASSWORD` in plain text. This is why the console and the state need protection, and why a real application would use Secrets Manager.

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

`infra/.terraform.lock.hcl` belongs in this commit, because it now also pins the `archive` provider.

## 7. Typical problems

The error text in the first row comes from a real run. The other texts are written from memory, so compare them with what you see.

| Symptom | Likely cause |
|---|---|
| `InvalidParameterValueException: Uploaded file must be a non-empty zip` on `CreateFunction` | The `handler.py` of that function is still **empty** (the setup script creates empty files). Copy the placeholder (section 6, "Before the plan"), check with `wc -l`, then plan and apply again. |
| `tf apply` stopped halfway, some functions are created and others are not | Terraform keeps what it created. The network, Cognito and the **database** exist already, so RDS costs money until you destroy it. Fix the cause, then run a **new** `tf plan` (the saved plan is stale) and apply it. The new plan only lists the missing resources. |
| `Saved plan is stale` | The state changed after the plan was made, for example by a partial apply. Plan again and apply the new file. |
| `The provided execution role does not have permissions to call CreateNetworkInterface on EC2` | The permissions were not in place when the function was created. Check the `depends_on` line. A new `tf apply` usually succeeds, because IAM changes take a few seconds to spread. |
| `Error: ... archive_file ... no such file or directory` | `source_dir` points to a folder that does not exist. Check the path and the folder names (they are singular: `create_tutorial`, `rate_tutorial`). |
| The invoke answer contains an error about importing the module `handler` | `handler.py` is misnamed or in a sub folder, so Lambda cannot find the file named in `handler = "handler.lambda_handler"`. |
| `KeyError: 'DB_HOST'` in the logs | The environment variables are missing. Check the `environment` block and `local.db_environment`. |
| `"db_reachable": false` with `timed out` | The packets are dropped. Check that the function carries `lambda_sg` (Test 1), that `rds_sg` allows port 5432 from it (step 3, test 4), and that the functions and the database use the same port. |
| `"db_reachable": false` with `Name or service not known` | The host name cannot be resolved. Check `enable_dns_support` and `enable_dns_hostnames` of the VPC (step 3). |
| `Task timed out after ... seconds` | The `timeout` is too short, or a connection hangs. The placeholder waits at most 5 seconds. |
| `Error: ... ResourceConflictException` or "function already exists" | A function with this name exists, for example from a stack in another folder. Destroy it there first. |
| `tf plan` wants to update a function although you changed nothing | The zip content changed. Running Python locally in a function folder creates `__pycache__`, which ends up in the zip. Delete the folder, or build in `backend/build/` (step 7). |
| `tf destroy` fails with `DependencyViolation` on a subnet or a security group | The network interfaces of the functions are released with a delay after the functions are deleted. Wait a few minutes and run `tf destroy` again. |
| The log groups are still there after `tf destroy` | Lambda created them, not Terraform. Delete them if you want: `aws logs delete-log-group --log-group-name /aws/lambda/tutorials-app-get-tutorials`. |
| Console: no internet in the function | By design. The subnets have no NAT gateway. |

## 8. Cost and cleanup

Lambda is billed per call and per running time. There is a monthly free tier, which a learning project does not exceed. Check the current figures on the Lambda pricing page. Attaching a function to a VPC has no extra charge as far as I know, but check the pricing page for your region. Logs cost a small amount per GB. The roles and the zips are free.

The costly part of the project is still the database from step 4. Run `tf destroy` at the end of each session. The functions are removed with everything else, and the next `apply` creates them again.

## 9. What to remember

- A Lambda function is code plus a **handler** (`file.function`), a **runtime** and a **role**.
- The role has a **trust policy** (who may use it) and **permission policies** (what it may do).
- A function in a VPC gets network interfaces in your subnets and carries `lambda_sg`. Both subnets are listed.
- Without a NAT gateway the functions reach only the VPC. `aws lambda invoke` still works, because it calls the Lambda service.
- `source_code_hash` makes Terraform notice code changes. `depends_on` the attachment avoids a race with the permissions.
- **A zip of empty files is refused by Lambda.** `tf plan` does not catch this, only `tf apply` does, and by then the database already runs. Check `wc -l backend/*/handler.py` before the plan.
- Environment variables carry the database address. The password in them is a learning shortcut.
- `"db_reachable": true` proves the chain `lambda_sg` -> `rds_sg` -> RDS. A real login (SSL, user, password, SQL) is step 7.

## 10. Next step

Step 6 fills `infra/api_gateway.tf`: an HTTP API with a JWT authorizer that checks the Cognito token, a route to `get_tutorials`, a stage and the permission that lets API Gateway start the function. After it, `curl` without a token answers `401`. The other routes follow in step 7, together with the real code of the four functions.
