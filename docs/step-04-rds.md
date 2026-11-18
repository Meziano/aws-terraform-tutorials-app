# Step 4: RDS, the PostgreSQL database

## 1. What are we going to build?

In this step the app gets its **database**. We use **Amazon RDS for PostgreSQL**, a managed database: AWS installs it, patches it and takes care of the server. We only decide how big it is, who may connect and which password it has.

Two Terraform resources are created:

| # | Resource | Job |
|---|---|---|
| 1 | `aws_db_subnet_group` | Tells RDS in which subnets it may place the database. It needs the two subnets of step 3 |
| 2 | `aws_db_instance` | The PostgreSQL database itself |

Together with steps 2 and 3 the project now has **14 resources**.

**This is the first step that costs money while it runs.** RDS is billed per hour, so `tf destroy` ends every working session (section 8). Creating the database takes about **8 to 10 minutes**.

This step also introduces the first **secret** of the project: the database password. It goes into `terraform.tfvars`, which Git ignores (see step 1).

At the end of this step:

- the database has the status `available`,
- it is **not** publicly accessible,
- only `lambda_sg` may connect to it,
- the AWS CLI confirms all of this.

The first connection from a Lambda function follows in step 5 (a TCP check). The first real login follows in step 7.

## 2. Prerequisites

- Step 3 is done and merged: `main` contains the tag `step-03`. The database needs `private_a`, `private_b` and `rds_sg`.
- The AWS credentials work:

```bash
aws sts get-caller-identity
```

- The step starts on its own branch:

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

- The **DB subnet group** is a list of subnets that RDS may use. It must cover **at least two availability zones**, even for a single database. This is why step 3 built two subnets.
- The database instance is placed in **one** of these subnets. With a single instance there is no second copy. The second subnet only keeps the option open to add one later.
- The **security group** `rds_sg` is the firewall in front of the instance. It already exists from step 3 and is only attached here.

### Instance, engine, storage

| Term | Meaning |
|---|---|
| **DB instance** | One database server managed by AWS |
| **Engine** | The database software, here `postgres` |
| **Instance class** | The size of the server. `db.t3.micro` is the smallest common class: 2 vCPUs, 1 GB RAM. Enough for learning |
| **Allocated storage** | The disk size in GB. 20 GB is the minimum for PostgreSQL |
| **Endpoint** | The host name under which the database is reached. It exists only inside the VPC |

### Private means private

`publicly_accessible = false` means that the instance gets no public IP address. Its host name resolves to an address such as `10.0.1.155`, which is only valid inside our VPC. Even with a wrong security group, nobody on the internet could reach it, because there is no route to it. Three layers protect the database: no route, no public address and the firewall rule.

### Encryption

- **At rest:** `storage_encrypted = true` encrypts the disk with an AWS-managed key. It costs nothing extra. It is chosen when the database is created, and it cannot be switched on later without a rebuild.
- **In transit:** from PostgreSQL major version **15** on, RDS sets the parameter `rds.force_ssl` to `1` by default. The database then **refuses connections without SSL**. Our version is 16, so the Lambda code in step 7 connects with SSL.

### The password and the Terraform state

Terraform needs the password to create the database, so it is a variable:

- `sensitive = true` hides it in the output of `tf plan` and `tf apply`.
- It is **still stored in plain text in the state file** (`terraform.tfstate`). That is why Git ignores the state and why it is never shared.
- A production setup lets RDS manage the password in AWS Secrets Manager (`manage_master_user_password`). That is safer, but it adds a service and a small cost. For this tutorial the variable is simpler to follow.

## 4. The code

Step 4 fills `infra/rds.tf` and extends `variables.tf`, `outputs.tf` and the two `tfvars` files.

### `infra/variables.tf` (added at the end)

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

`db_port` already exists since step 3. `db_password` has **no default** on purpose: Terraform refuses to plan until a value is provided.

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

### `infra/outputs.tf` (added at the end)

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

### `infra/terraform.tfvars` (the real file, never committed)

```hcl
db_password = "choose-a-long-password-here"
```

The password has at least 8 characters and contains no `/`, `@`, `"` or space. RDS does not allow these characters, and the validation block catches them before AWS does.

An alternative keeps the password out of every file: an environment variable. Terraform reads variables named `TF_VAR_<name>` automatically.

```bash
read -rs TF_VAR_db_password && export TF_VAR_db_password     # type the password, nothing is shown
```

### `infra/terraform.tfvars.example` (committed, no real secret)

```hcl
aws_region    = "eu-central-1"
project_name  = "tutorials-app"
callback_urls = ["http://127.0.0.1:5500/callback.html"]
logout_urls   = ["http://127.0.0.1:5500/index.html"]

# Secret: the real value belongs only in terraform.tfvars (ignored by Git)
db_password = "change-me-please"
```

## 5. Why it is done this way

| Decision | Reason |
|---|---|
| **RDS instead of a database on a server** | No operating system to patch. Backups and updates are managed by AWS |
| **PostgreSQL** | Strong SQL support, foreign keys and constraints, and a good fit for users, tutorials and ratings |
| **`db.t3.micro`, 20 GB, single zone** | The smallest setup that works. A real application uses more resources and `multi_az = true` |
| **`publicly_accessible = false`** | The database is never on the internet. Only our functions need it |
| **`vpc_security_group_ids = [rds_sg]`** | Attaches the firewall of step 3. Without it, RDS would use the default group of the VPC |
| **`storage_encrypted = true`** | Free, and it cannot be added later without a rebuild |
| **`password` as a `sensitive` variable without default** | The secret is not in the code, and Terraform cannot run by accident with a weak default |
| **Validation of the password** | A bad password fails in seconds at `tf plan`, instead of after minutes at `tf apply` |
| **`engine_version = "16"` (major only)** | RDS picks a current minor version. PostgreSQL 15 or newer forces SSL, which is the safe default |
| **`backup_retention_period = 0`** | No automated backups: faster to create, and nothing is left behind. Fine for a project that is destroyed after every session, not for real data |
| **`skip_final_snapshot = true`** | Without it, `tf destroy` fails unless a final snapshot is named. The data is lost on destroy, and `init_db` (step 7) recreates the tables |
| **`deletion_protection = false`** | Needed to destroy the database with Terraform. Production setups set it to `true` |
| **`apply_immediately = true`** | Changes apply now and not in the next maintenance window. Good for learning, risky in production |
| **Database name and user in variables** | Step 5 hands the same values to the Lambda functions. Each value has one source |
| **Instance named `${var.project_name}-db`** | A predictable name, `tutorials-app-db`, which the AWS CLI checks below use |

## 6. Run and verify

```bash
cd infra
tf fmt
tf validate
tf plan -out="actions.tfplan"
```

Expected: **2 to add, 0 to change, 0 to destroy**. The password appears as `(sensitive value)`. The resources of steps 2 and 3 do not appear in the plan. If they do, the state is empty: a different folder, or a missing state file.

If Terraform asks for `var.db_password`, it did not find the value in `terraform.tfvars` or in the environment variable.

```bash
tf apply actions.tfplan
```

The instance goes through the status `creating` and takes about 8 to 10 minutes. The apply is not interrupted. Section 7 is a good read in the meantime.

```bash
tf output
```

### Test 1: status and exposure

```bash
aws rds describe-db-instances --db-instance-identifier tutorials-app-db \
  --query "DBInstances[0].[DBInstanceStatus,PubliclyAccessible,Engine,EngineVersion,StorageEncrypted]" \
  --output text
```

Expected: `available  False  postgres  16.x  True`. `PubliclyAccessible` has to be `False`.

### Test 2: placement in the right network

```bash
aws rds describe-db-instances --db-instance-identifier tutorials-app-db \
  --query "DBInstances[0].[DBSubnetGroup.VpcId,DBSubnetGroup.Subnets[].SubnetAvailabilityZone.Name,VpcSecurityGroups[].VpcSecurityGroupId]" \
  --output json

tf output vpc_id
tf output rds_sg_id
```

Expected: the VPC ID equals `vpc_id`, the subnet list shows **two different zones**, and the security group equals `rds_sg_id`. Nothing else is attached.

### Test 3: SSL is enforced

```bash
aws rds describe-db-instances --db-instance-identifier tutorials-app-db \
  --query "DBInstances[0].DBParameterGroups[0].DBParameterGroupName" --output text
```

This prints the parameter group, for example `default.postgres16`. That name goes into the next command:

```bash
aws rds describe-db-parameters --db-parameter-group-name default.postgres16 \
  --query "Parameters[?ParameterName=='rds.force_ssl'].[ParameterName,ParameterValue]" \
  --output text
```

Expected: `rds.force_ssl  1`. An empty value means that the parameter has no explicit value in this group. The documented default for version 15 and later then applies, and the real connection in step 7 confirms it.

### Test 4: a laptop cannot connect

```bash
HOST=$(tf output -raw db_host)
timeout 5 bash -c "</dev/tcp/$HOST/5432" && echo OPEN || echo BLOCKED
```

Expected: `BLOCKED`. On macOS, `timeout` may be missing. It comes with the `coreutils` package, and the test can also be skipped.

`BLOCKED` is a **good** result. A laptop is outside the VPC, so the private address cannot be reached.

A `psql` session needs a machine inside the VPC that carries `lambda_sg`, because `rds_sg` allows nothing else. The first connection test is the TCP check of the Lambda functions in step 5. The first real login, with SSL, user and password, is `init_db` in step 7.

### Commit, merge, tag

Before the commit, a check shows that the password is not tracked:

```bash
git ls-files | grep -E 'tfvars$|tfstate'     # prints nothing
git grep -n "db_password" -- ':!*.md'        # the variable name may appear, the value never
```

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

`docs/step-04-rds.md` is part of this commit.

## 7. Typical problems

| Symptom | Likely cause |
|---|---|
| `DBSubnetGroupDoesNotCoverEnoughAZs` | The two subnets are in the same zone. The `availability_zone` lines in `vpc.tf` (step 3) show it |
| `InvalidParameterValue: ... MasterUserPassword ...` | The password contains `/`, `@`, `"` or a space, or it is too short |
| `Error: Invalid value for variable` at `tf plan` | The validation of `db_password` failed. The message names the rule |
| Terraform asks for `var.db_password` | The value is missing in `terraform.tfvars` and in `TF_VAR_db_password` |
| `DBInstanceAlreadyExists` | An instance named `tutorials-app-db` exists already, for example from a stack in another folder. It has to be destroyed there first |
| `InvalidParameterCombination: ... engine version ...` | The chosen version is not offered in the region, or not for this instance class. `aws rds describe-db-engine-versions --engine postgres --query "DBEngineVersions[].EngineVersion"` lists what exists |
| `FreeTierRestrictionError` or a similar message about backups or instance classes | The plan of the AWS account restricts these settings. The message names the setting, and the Billing console shows the plan |
| `tf destroy` fails with a final snapshot error | `skip_final_snapshot` is not `true`. After setting it and running `tf apply`, the destroy works |
| `tf destroy` waits on the security group or a subnet | A network interface or a rule added by hand still uses it. After removing the manual rule, `tf destroy` runs again. From step 5 on, leftover Lambda network interfaces are the usual cause (see step 5) |
| `tf plan` shows a change of `engine_version` after some days | RDS did a minor upgrade (`auto_minor_version_upgrade`). Pinning the full version, or `lifecycle { ignore_changes = [engine_version] }`, stops the difference |
| `tf plan` wants to replace the instance | A change such as `storage_encrypted`, `identifier` or `db_name` forces a rebuild, and the data is lost. `# forces replacement` in the plan shows it before the apply |
| `Connection timed out` from a laptop | Expected. The database is private |

## 8. Cost and cleanup

RDS is billed **per hour** for the instance, plus storage. The price depends on the region and the instance class. The current figures are on the RDS pricing page.

Free Tier rules differ between accounts. Accounts created before 15 July 2025 had a 12-month Free Tier with 750 instance hours per month. Newer accounts use a "free plan" with credits for a limited period. The Billing console, section Free Tier, shows what a given account gets. A running database is never assumed to be free.

The database is destroyed at the end of each session:

```bash
tf destroy
```

- `tf destroy` removes **everything** in the state: Cognito, the network and the database. The database takes a few minutes to disappear.
- The data is lost (`skip_final_snapshot`). Step 7 recreates the tables in seconds with `init_db`.
- Cognito is destroyed too, so the next `apply` makes a **new** pool, a new client ID and a new login URL (see step 2). Users register again.
- To remove only the database, `tf destroy -target=aws_db_instance.tutorials_db` does the job. The `-target` option is meant for this kind of cleanup, not as a normal workflow.

A last check shows that nothing keeps running:

```bash
aws rds describe-db-instances --region eu-central-1 \
  --query "DBInstances[].[DBInstanceIdentifier,DBInstanceStatus]" --output text
```

An empty result means that no database is left.

## 9. What to remember

- RDS is a managed PostgreSQL server. The **subnet group** says where it may live, the **security group** says who may connect.
- The subnet group needs **two zones**. That is the reason for the two subnets of step 3.
- `publicly_accessible = false`, a private subnet and `rds_sg` together keep the database away from the internet.
- PostgreSQL 15 or newer **requires SSL**. The connection code in step 7 uses it.
- The password is a `sensitive` variable. It is hidden in the output but stored in the **state**, so the state stays private.
- `skip_final_snapshot`, `deletion_protection = false` and `backup_retention_period = 0` are learning settings, not production settings.
- RDS costs money while it runs, so it is destroyed after every session.

## 10. Next step

Step 5 fills `infra/lambda.tf`: the IAM role and four Lambda functions. They run inside the private subnets with `lambda_sg` and receive the database host, name, user and password as environment variables. The functions are placeholders that open a TCP connection to the database. A successful answer is the first proof that the chain `lambda_sg` -> `rds_sg` -> RDS works. The real code follows in steps 7 and 8.
