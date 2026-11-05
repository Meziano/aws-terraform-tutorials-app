# Step 4: RDS, the PostgreSQL database

## 1. What are we going to build?

In this step the app gets its **database**. We use **Amazon RDS for PostgreSQL**, a managed database: AWS installs it, patches it and takes care of the server. We only decide how big it is, who may connect and which password it has.

Two Terraform resources are created:

| #   | Resource              | Job                                                                                      |
| --- | --------------------- | ---------------------------------------------------------------------------------------- |
| 1   | `aws_db_subnet_group` | Tells RDS in which subnets it may place the database. It needs the two subnets of step 3 |
| 2   | `aws_db_instance`     | The PostgreSQL database itself                                                           |

Together with steps 2 and 3 the project now has **14 resources**.

**This is the first step that costs money while it runs.** RDS is billed per hour, so run `tf destroy` at the end of every working session (section 8). Creating the database takes about **8 minutes**. In our test it took 7 minutes 47 seconds.

This step also introduces the first **secret** of the project: the database password. It goes into `terraform.tfvars`, which Git ignores (see step 1).

At the end of this step:

- the database has the status `available`,
- it is **not** publicly accessible,
- only `lambda_sg` may connect to it,
- you have checked all this with the AWS CLI. The first real connection comes in step 5.

## 2. Prerequisites

- Step 3 is done and merged: `main` contains the tag `step-03`. The database needs `private_a`, `private_b` and `rds_sg`.
- The AWS credentials work:

```bash
aws sts get-caller-identity
```

- Start the step on its own branch:

```bash
git switch main
git switch -c step-04-rds
```

## 3. The concepts

### What lives where

```
VPC 10.0.0.0/16
 |
 +-- subnet private_a (zone a) --+
 |                                +-- DB subnet group  -->  RDS instance
 +-- subnet private_b (zone b) --+                          (placed in ONE of the two subnets)
 |
 +-- rds_sg  :  port 5432 only from lambda_sg
```

- The **DB subnet group** is a list of subnets that RDS may use. It must cover **at least two availability zones**, even when you run a single database. This is why step 3 built two subnets.
- The database instance is placed in **one** of these subnets. With a single instance there is no second copy. The second subnet only keeps the option open to add one later.
- The **security group** `rds_sg` is the firewall in front of the instance. It already exists from step 3 and is only attached here.

### Instance, engine, storage

| Term                  | Meaning                                                                                                    |
| --------------------- | ---------------------------------------------------------------------------------------------------------- |
| **DB instance**       | One database server managed by AWS                                                                         |
| **Engine**            | The database software, here `postgres`                                                                     |
| **Instance class**    | The size of the server. `db.t3.micro` is the smallest common class: 2 vCPUs, 1 GB RAM. Enough for learning |
| **Allocated storage** | The disk size in GB. 20 GB is the minimum for PostgreSQL                                                   |
| **Endpoint**          | The host name under which the database is reached. It exists only inside the VPC                           |

### Private means private

`publicly_accessible = false` means that the instance gets no public IP address. Its host name resolves to an address such as `10.0.1.155`, which is only valid inside our VPC. Even with a wrong security group, nobody on the internet could reach it, because there is no route to it. Two independent locks, no route and no public address, plus the firewall rule, are three layers.

### Encryption

- **At rest:** `storage_encrypted = true` encrypts the disk with an AWS-managed key. It costs nothing extra. It must be chosen when the database is created, and it cannot be switched on later without rebuilding.
- **In transit:** from PostgreSQL major version **15** on, RDS sets the parameter `rds.force_ssl` to `1` by default. The database then **refuses connections without SSL**. Our version is 16, so the Lambda code in step 7 must connect with SSL.

### The password and the Terraform state

Terraform needs the password to create the database, so it is a variable:

- `sensitive = true` hides it in `tf plan` and `tf apply` output.
- It is **still stored in plain text in the state file** (`terraform.tfstate`). That is why the state is ignored by Git and must never be shared.
- A production setup would let RDS manage the password in AWS Secrets Manager (`manage_master_user_password`). That is safer, but it adds a service and a small cost. For this tutorial the variable is simpler to follow.

## 4. The code

Step 4 fills `infra/rds.tf` and extends `variables.tf`, `outputs.tf` and the two `tfvars` files.

### `infra/variables.tf` (add at the end)

```hcl
variable "db_name" {
  description = "Name of the first database inside the instance"
  type        = string
  default     = "tutorials"
}

variable "db_username" {
  description = "Master user of the database"
  type        = string
  default     = "tutorials_admin"
}

variable "db_password" {
  description = "Master password of the database. Set it in terraform.tfvars, never commit it"
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.db_password) >= 8 && can(regex("^[^/@\" ]+$", var.db_password))
    error_message = "The password needs at least 8 characters and must not contain a slash, an @, a double quote or a space."
  }
}

variable "db_instance_class" {
  description = "Size of the database server"
  type        = string
  default     = "db.t3.micro"
}

variable "db_allocated_storage" {
  description = "Disk size in GB"
  type        = number
  default     = 20
}

variable "db_engine_version" {
  description = "PostgreSQL major version"
  type        = string
  default     = "16"
}
```

`db_port` already exists since step 3. `db_password` has **no default** on purpose: Terraform refuses to plan until you provide it.

### `infra/rds.tf`

```hcl
# The subnets in which RDS may place the database (must cover 2 availability zones)
resource "aws_db_subnet_group" "tutorials_db_subnet_group" {
  name        = "${var.project_name}-db-subnets"
  description = "Private subnets for the tutorials database"
  subnet_ids  = [aws_subnet.private_a.id, aws_subnet.private_b.id]

  tags = merge(local.common_tags, { Name = "${var.project_name}-db-subnets" })
}

resource "aws_db_instance" "tutorials_db" {
  identifier = "${var.project_name}-db"

  # Engine and size
  engine            = "postgres"
  engine_version    = var.db_engine_version
  instance_class    = var.db_instance_class
  allocated_storage = var.db_allocated_storage
  storage_type      = "gp2"
  storage_encrypted = true

  # First database and master user
  db_name  = var.db_name
  username = var.db_username
  password = var.db_password
  port     = var.db_port

  # Network: private, only reachable from the Lambda security group
  db_subnet_group_name   = aws_db_subnet_group.tutorials_db_subnet_group.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  publicly_accessible    = false
  multi_az               = false

  # Learning setup: easy to create and to destroy
  backup_retention_period    = 0
  skip_final_snapshot        = true
  deletion_protection        = false
  apply_immediately          = true
  auto_minor_version_upgrade = true

  tags = merge(local.common_tags, { Name = "${var.project_name}-db" })
}
```

### `infra/outputs.tf` (add at the end)

```hcl
output "db_host" {
  description = "Host name of the database (only reachable inside the VPC)"
  value       = aws_db_instance.tutorials_db.address
}

output "db_name" {
  value = aws_db_instance.tutorials_db.db_name
}
```

There is **no output for the password**. `address` is the host name only. The attribute `endpoint` would also contain the port, which the Lambda code takes from its own variable.

### `infra/terraform.tfvars` (your real file, never committed)

```hcl
db_password = "choose-a-long-password-here"
```

Use at least 8 characters, without `/`, `@`, `"` or spaces. These characters are not allowed by RDS, and the validation block catches them before AWS does.

An alternative that keeps the password out of every file is an environment variable. Terraform reads variables named `TF_VAR_<name>` automatically:

```bash
read -rs TF_VAR_db_password && export TF_VAR_db_password     # type the password, nothing is shown
```

### `infra/terraform.tfvars.example` (committed, no real secret)

```hcl
aws_region    = "eu-central-1"
project_name  = "tutorials-app"
callback_urls = ["http://127.0.0.1:5500/callback.html"]
logout_urls   = ["http://127.0.0.1:5500/index.html"]

# Secret: set the real value only in terraform.tfvars (ignored by Git)
db_password = "change-me-please"
```

## 5. Why it is done this way

| Decision                                                 | Reason                                                                                                                                     |
| -------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| **RDS instead of a database on a server**                | No operating system to patch, backups and updates are managed by AWS.                                                                      |
| **PostgreSQL**                                           | Strong SQL support, foreign keys, constraints, and a good fit for users, tutorials and ratings.                                            |
| **`db.t3.micro`, 20 GB, single zone**                    | The smallest setup that works. A real application would use more resources and `multi_az = true`.                                          |
| **`publicly_accessible = false`**                        | The database must never be on the internet. Only our functions need it.                                                                    |
| **`vpc_security_group_ids = [rds_sg]`**                  | Attaches the firewall of step 3. Without it, RDS would use the default group of the VPC.                                                   |
| **`storage_encrypted = true`**                           | Free, and it cannot be added later without a rebuild.                                                                                      |
| **`password` as a `sensitive` variable without default** | The secret is not in the code, and Terraform cannot run by accident with a weak default.                                                   |
| **Validation of the password**                           | Fails in seconds at `tf plan`, instead of after minutes at `tf apply`.                                                                     |
| **`engine_version = "16"` (major only)**                 | RDS picks a current minor version. PostgreSQL 15 or newer forces SSL, which is the safe default.                                           |
| **`backup_retention_period = 0`**                        | No automated backups: faster to create, nothing left behind. Fine for a project that is destroyed daily, not for real data.                |
| **`skip_final_snapshot = true`**                         | Without it, `tf destroy` fails unless you name a final snapshot. The data is lost on destroy, and `init_db` (step 7) recreates the tables. |
| **`deletion_protection = false`**                        | Needed to destroy the database with Terraform. Production setups set it to `true`.                                                         |
| **`apply_immediately = true`**                           | Changes are applied now and not in the next maintenance window. Good for learning, risky in production.                                    |
| **Database name and user in variables**                  | Step 5 hands the same values to the Lambda functions. One source for each value.                                                           |
| **Instance named `${var.project_name}-db`**              | Predictable name: `tutorials-app-db`. The AWS CLI checks below use it.                                                                     |

## 6. Run and verify

```bash
cd infra
tf fmt
tf validate
tf plan -out="actions.tfplan"
```

Expected: **2 to add, 0 to change, 0 to destroy**. The password appears as `(sensitive value)`. The resources of steps 2 and 3 must not be in the plan. If they are, you are in an empty state: a different folder, or a missing state file.

If Terraform asks `var.db_password`, it did not find the value. Check `terraform.tfvars` or the environment variable.

```bash
tf apply actions.tfplan
```

Now wait. The instance goes through `creating` and takes about 8 minutes. Do not interrupt `tf apply`.

```bash
tf output
```

### Test 1: status and exposure

```bash
aws rds describe-db-instances --db-instance-identifier tutorials-app-db \
  --query "DBInstances[0].[DBInstanceStatus,PubliclyAccessible,Engine,EngineVersion,StorageEncrypted]" \
  --output text
```

Expected: `available  False  postgres  16.x  True`. `PubliclyAccessible` must be `False`.

### Test 2: placement in the right network

```bash
aws rds describe-db-instances --db-instance-identifier tutorials-app-db \
  --query "DBInstances[0].[DBSubnetGroup.VpcId,DBSubnetGroup.Subnets[].SubnetAvailabilityZone.Name,VpcSecurityGroups[].VpcSecurityGroupId]" \
  --output json

tf output vpc_id
tf output rds_sg_id
```

Expected: the VPC ID equals `vpc_id`, the subnet list shows **two different zones**, and the security group equals `rds_sg_id`. Nothing else may be attached.

### Test 3: SSL is enforced

```bash
aws rds describe-db-instances --db-instance-identifier tutorials-app-db \
  --query "DBInstances[0].DBParameterGroups[0].DBParameterGroupName" --output text
```

This prints the parameter group, for example `default.postgres16`. Use that name here:

```bash
aws rds describe-db-parameters --db-parameter-group-name default.postgres16 \
  --query "Parameters[?ParameterName=='rds.force_ssl'].[ParameterName,ParameterValue]" \
  --output text
```

Expected: `rds.force_ssl  1`. If the value is empty, the parameter has no explicit value in this group. In that case rely on the documented default for version 15 and later, and test the real connection in step 5.

### Test 4: the laptop cannot connect

```bash
HOST=$(tf output -raw db_host)
timeout 5 bash -c "</dev/tcp/$HOST/5432" && echo OPEN || echo BLOCKED
```

Expected: `BLOCKED` (on macOS, `timeout` may be missing; install `coreutils` or skip this test). This is a **good** result. Your laptop is outside the VPC, so the private address cannot be reached.

A real login with `psql` is possible from a CloudShell inside the VPC, but only if `rds_sg` allows that CloudShell. It does not by design, so we do not need it now. The first real connection test is the `init_db` function in step 7.

### Commit, merge, tag

```bash
git status                  # no tfvars, no tfstate, no tfplan in the list
git add -A
git commit -m "Step 4: RDS PostgreSQL instance and DB subnet group"
git switch main
git merge --no-ff step-04-rds
git tag -a step-04 -m "RDS database"
git push origin main --tags
git branch -d step-04-rds
```

Before you push, check once more that the password is not tracked:

```bash
git ls-files | grep -E 'tfvars$|tfstate'     # must print nothing
git grep -n "db_password" -- ':!*.md'        # the variable name may appear, the value must not
```

## 7. Typical problems

| Symptom                                                                  | Likely cause                                                                                                                                                                                       |
| ------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `DBSubnetGroupDoesNotCoverEnoughAZs`                                     | The two subnets are in the same zone. Check the `availability_zone` lines in `vpc.tf` (step 3).                                                                                                    |
| `InvalidParameterValue: ... MasterUserPassword ...`                      | The password contains `/`, `@`, `"` or a space, or is too short.                                                                                                                                   |
| `Error: Invalid value for variable` at `tf plan`                         | The validation of `db_password` failed. Read the message and change the password.                                                                                                                  |
| Terraform asks for `var.db_password`                                     | The value is missing in `terraform.tfvars` and in `TF_VAR_db_password`.                                                                                                                            |
| `DBInstanceAlreadyExists`                                                | An instance named `tutorials-app-db` exists already, for example from a stack in another folder. Destroy it there first.                                                                           |
| `InvalidParameterCombination: ... engine version ...`                    | The chosen version is not offered in your region, or not for this class. Check what exists: `aws rds describe-db-engine-versions --engine postgres --query "DBEngineVersions[].EngineVersion"`.    |
| `FreeTierRestrictionError` or a similar message about backups or classes | Your account plan restricts the settings. Read the message, and check the plan of your account in the Billing console.                                                                             |
| `tf destroy` fails with a final snapshot error                           | `skip_final_snapshot` is not `true`. Set it, run `tf apply`, then destroy again.                                                                                                                   |
| `tf destroy` hangs on the security group or subnet                       | A network interface or a rule that was added by hand is still using it. Remove the manual rule and run `tf destroy` again.                                                                         |
| `tf plan` shows a change of `engine_version` after some days             | RDS did a minor upgrade (`auto_minor_version_upgrade`). Pin the full version, or add `lifecycle { ignore_changes = [engine_version] }`. I have not checked how your provider version reports this. |
| `tf plan` wants to replace the instance                                  | A change such as `storage_encrypted`, `identifier` or `db_name` forces a rebuild, and the data is lost. Read the plan for `# forces replacement` before applying.                                  |
| `Connection timed out` from your laptop                                  | Expected. The database is private.                                                                                                                                                                 |

## 8. Cost and cleanup

RDS is billed **per hour** for the instance, plus storage. The price depends on the region and the instance class, so check the current figures on the RDS pricing page.

Free Tier rules differ between accounts. Accounts created before 15 July 2025 had a 12-month Free Tier with 750 instance hours per month. Newer accounts use a "free plan" with credits for a limited period. Look at the Billing console, section Free Tier, to see what your account gets. Do not assume it is free.

Destroy the database at the end of each session:

```bash
tf destroy
```

- `tf destroy` removes **everything** in the state: Cognito, the network and the database. The database takes a few minutes to disappear.
- The data is lost (`skip_final_snapshot`). Step 7 recreates the tables in seconds with `init_db`.
- Cognito is destroyed too, so the next `apply` makes a **new** pool, a new client ID and a new login URL (see step 2), and users must register again.
- If you only want to remove the database, run `tf destroy -target=aws_db_instance.tutorials_db`. Use `-target` only for this kind of cleanup, not as a normal workflow.

Check afterwards that nothing keeps running:

```bash
aws rds describe-db-instances --region eu-central-1 \
  --query "DBInstances[].[DBInstanceIdentifier,DBInstanceStatus]" --output text
```

An empty result means no database is left.

## 9. What to remember

- RDS is a managed PostgreSQL server. The **subnet group** says where it may live, the **security group** says who may connect.
- The subnet group needs **two zones**. That is the reason for the two subnets of step 3.
- `publicly_accessible = false` plus a private subnet plus `rds_sg`: the database is not reachable from the internet.
- PostgreSQL 15 or newer **requires SSL**. The connection code in step 7 must use it.
- The password is a `sensitive` variable. It is hidden in the output but stored in the **state**, so the state stays private.
- `skip_final_snapshot`, `deletion_protection = false` and `backup_retention_period = 0` are learning settings, not production settings.
- RDS costs money while it runs. Destroy it after every session.

## 10. Next step

Step 5 fills `infra/lambda.tf`: the IAM role, the first Lambda function and the other functions. The functions run inside the private subnets with `lambda_sg` and receive the database host, name, user and password as environment variables. A first test shows that the Lambda sees the database host. Real queries come in step 7.
