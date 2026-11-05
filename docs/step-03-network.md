# Step 3: Network and security (VPC, subnets, security groups)

## 1. What are we going to build?

In this step we build the **private network** in which the database (step 4) and the Lambda functions (step 5) will live. Nothing in it can be reached from the internet. We also write the **firewall rules** that decide who may talk to whom inside that network.

Eight Terraform resources are created. All of them are free of charge.

| # | Resource | Job |
|---|---|---|
| 1 | `aws_vpc` | Our own isolated network (address range `10.0.0.0/16`) |
| 2 | `aws_subnet` `private_a` | A part of the network in availability zone A |
| 3 | `aws_subnet` `private_b` | A part of the network in availability zone B |
| 4 | `aws_route_table` | The routing rules of the subnets. Only local traffic is allowed |
| 5 | `aws_route_table_association` `private_a` | Connects subnet A to the route table |
| 6 | `aws_route_table_association` `private_b` | Connects subnet B to the route table |
| 7 | `aws_security_group` `lambda_sg` | The firewall of the Lambda functions |
| 8 | `aws_security_group` `rds_sg` | The firewall of the database. Only `lambda_sg` may connect |

Together with step 2 the project now has **12 resources**.

This step has no visible result in the browser. The proof comes from the AWS CLI now, and from the first real connection in step 5.

## 2. Prerequisites

- Step 2 is done and merged: `main` contains the tag `step-02`.
- The AWS credentials work:

```bash
aws sts get-caller-identity
```

- Start the step on its own branch:

```bash
git switch main
git switch -c step-03-network
```

## 3. The concepts

### VPC, subnet, route table

```
VPC 10.0.0.0/16                      our own private network
 |
 +-- subnet private_a 10.0.1.0/24    in availability zone eu-central-1a
 +-- subnet private_b 10.0.2.0/24    in availability zone eu-central-1b
 |
 +-- route table "private"           knows only the local network (10.0.0.0/16)
```

- A **VPC** is a virtual network that belongs only to you. Nothing gets in or out unless you build a door.
- A **subnet** is a slice of the VPC address range. It sits in exactly one **availability zone** (AZ), which is one data centre location of the region.
- A **route table** says where traffic for an address goes. Ours has only the automatic `local` entry. There is no internet gateway and no NAT gateway, so these subnets are **private**: nothing leaves the VPC and nothing enters from outside.
- A subnet is only linked to a route table by an **association**.

### Address ranges (CIDR)

`10.0.0.0/16` means: all addresses from `10.0.0.0` to `10.0.255.255`, about 65 000 of them. The `/16` is the number of fixed bits. `10.0.1.0/24` is a smaller range of 256 addresses (AWS reserves 5 of them) inside it. The two subnet ranges must not overlap and must lie inside the VPC range.

### Why two subnets in two AZs?

The Lambda functions work fine in one subnet. The reason for two is the database: an RDS **DB subnet group** (step 4) must span **at least two availability zones**, even if you run a single database. If you only create one subnet, step 4 fails with `DBSubnetGroupDoesNotCoverEnoughAZs`.

### Security groups

A security group is a **stateful firewall** attached to a resource.

- **Ingress** rules say what may come in, **egress** rules what may go out.
- Everything not allowed is denied. There are no "deny" rules.
- **Stateful** means that the answer to an allowed request is allowed automatically. You do not write a rule for the reply.
- A rule can name another **security group** as the source instead of an address range. This is the key idea of this step.

```
Lambda functions (lambda_sg)  ---- port 5432 ---->  RDS (rds_sg)
                                                      ingress: only from lambda_sg
```

`rds_sg` does not say "allow 10.0.1.0/24". It says "allow whoever carries `lambda_sg`". If the subnets change, or more functions are added, the rule stays correct. Anything else in the VPC, such as a future EC2 instance, cannot reach the database unless it carries `lambda_sg`.

### Lambda in a VPC

A Lambda function that is attached to a VPC gets a **network interface** (ENI) in each of the subnets. This happens in step 5. Two consequences:

- The function can reach the database through the private network.
- The function can reach **nothing else**: no internet and no other AWS APIs, because there is no NAT gateway. Our functions need nothing else, since they only talk to RDS. Their logs still reach CloudWatch, because the Lambda service writes them and not the function.

The reverse direction is not affected: API Gateway starts the function through the Lambda service. The request never enters the VPC network.

## 4. The code

Step 3 fills `infra/vpc.tf` and adds two variables to `infra/variables.tf`.

### `infra/variables.tf` (add at the end)

```hcl
variable "vpc_cidr" {
  description = "Address range of the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "db_port" {
  description = "Port of the PostgreSQL database"
  type        = number
  default     = 5432
}
```

### `infra/vpc.tf`

```hcl
# The availability zones of the region. This data source creates nothing.
data "aws_availability_zones" "available" {
  state = "available"

  # only regular zones, no Local Zones
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, { Name = "${var.project_name}-vpc" })
}

# --- Two private subnets in two different availability zones -------------------

resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = merge(local.common_tags, { Name = "${var.project_name}-private-a" })
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = data.aws_availability_zones.available.names[1]

  tags = merge(local.common_tags, { Name = "${var.project_name}-private-b" })
}

# --- Route table: local traffic only (no internet gateway, no NAT) -------------

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, { Name = "${var.project_name}-private-rt" })
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private.id
}

# --- Security groups -----------------------------------------------------------

# Firewall of the Lambda functions: nothing may come in, they may call out
resource "aws_security_group" "lambda_sg" {
  name        = "${var.project_name}-lambda-sg"
  description = "Lambda functions: no inbound traffic"
  vpc_id      = aws_vpc.main.id

  egress {
    description = "Outbound traffic (the subnets have no route to the internet)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.project_name}-lambda-sg" })
}

# Firewall of the database: only the Lambda functions may connect
resource "aws_security_group" "rds_sg" {
  name        = "${var.project_name}-rds-sg"
  description = "RDS PostgreSQL: inbound only from the Lambda security group"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL from the Lambda functions"
    from_port       = var.db_port
    to_port         = var.db_port
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda_sg.id]
  }

  tags = merge(local.common_tags, { Name = "${var.project_name}-rds-sg" })
}
```

### `infra/outputs.tf` (add at the end)

```hcl
output "vpc_id" {
  value = aws_vpc.main.id
}

output "lambda_sg_id" {
  value = aws_security_group.lambda_sg.id
}

output "rds_sg_id" {
  value = aws_security_group.rds_sg.id
}
```

The outputs make the CLI checks below easy and are handy later when you open a CloudShell inside the VPC.

## 5. Why it is done this way

| Decision | Reason |
|---|---|
| **A VPC of our own** | The default VPC of the account has public subnets. We want a network where we decide every door. |
| **Private subnets, no internet gateway, no NAT** | The database and the functions cannot be attacked from the internet, because there is no route to them. A NAT gateway would also cost money per hour. |
| **Two subnets in two AZs** | RDS requires a subnet group over at least two AZs. It also lets Lambda spread over two locations. |
| **AZ names from a data source, not typed in** | `eu-central-1a` could be missing in another account or region. The data source asks AWS what exists. |
| **Explicit route table and associations** | Without them, the subnets use the VPC's main route table. The result is the same, but the explicit version shows what the network does. |
| **`enable_dns_hostnames = true`** | The RDS endpoint is a host name. The VPC must be able to resolve it. |
| **`rds_sg` allows a security group, not an address range** | The rule says who may connect, not where they sit. It stays correct when addresses change. |
| **No ingress on `lambda_sg`** | Nobody connects to the functions over the network. API Gateway starts them through the Lambda service. |
| **No egress rule on `rds_sg`** | Terraform removes the default "allow all" egress rule when no `egress` block is written. The database answers connections through the stateful rule and never starts one. |
| **Rules written inside the security group** | This keeps the step at 8 resources and is easy to read. The AWS provider also offers separate rule resources (`aws_vpc_security_group_ingress_rule`). They are the better choice for large setups, but they add resources. |
| **`description` in plain ASCII** | AWS accepts only a limited character set in security group descriptions. Umlauts and accents cause an error. |
| **The `Name` tag** | The console shows the `Name` tag as the label. Without it, the list is a column of empty names and IDs. |

## 6. Run and verify

```bash
cd infra
tf fmt
tf validate
tf plan -out="actions.tfplan"
```

Expected: **8 to add, 0 to change, 0 to destroy**. The data source does not count. Your Cognito resources from step 2 must not appear in the plan. If they do, you are in an empty state, which means a different folder or a missing state file.

```bash
tf apply actions.tfplan
tf output
```

### Test 1: the network exists

```bash
aws ec2 describe-vpcs --filters "Name=tag:Project,Values=tutorials-app" \
  --query "Vpcs[].[VpcId,CidrBlock]" --output text
```

Expected: one VPC with `10.0.0.0/16`.

### Test 2: two subnets in two different zones

```bash
aws ec2 describe-subnets --filters "Name=tag:Project,Values=tutorials-app" \
  --query "Subnets[].[CidrBlock,AvailabilityZone]" --output text
```

Expected: `10.0.1.0/24` in one zone and `10.0.2.0/24` in another one (for example `eu-central-1a` and `eu-central-1b`). Two different zones are what step 4 needs.

### Test 3: the route table has no way out

```bash
aws ec2 describe-route-tables --filters "Name=tag:Name,Values=tutorials-app-private-rt" \
  --query "RouteTables[].Routes[].[DestinationCidrBlock,GatewayId]" --output text
```

Expected: only one line, `10.0.0.0/16  local`. A line with `0.0.0.0/0` would mean that a door to the internet exists.

### Test 4: the database firewall accepts only the Lambda group

```bash
aws ec2 describe-security-groups --group-ids "$(tf output -raw rds_sg_id)" \
  --query "SecurityGroups[0].IpPermissions[].[FromPort,UserIdGroupPairs[0].GroupId]" --output text

tf output lambda_sg_id
```

Expected: port `5432` and a group ID that is equal to `lambda_sg_id`. There must be no `0.0.0.0/0` anywhere in the ingress rules.

### Commit, merge, tag

```bash
git status                  # no tfvars, no tfstate, no tfplan in the list
git add -A
git commit -m "Step 3: VPC, private subnets, route table and security groups"
git switch main
git merge --no-ff step-03-network
git tag -a step-03 -m "Network and security"
git push origin main --tags
git branch -d step-03-network
```

## 7. Typical problems

| Symptom | Likely cause |
|---|---|
| `Invalid index` on `names[1]` | The region offers only one regular availability zone, or the filter removed the others. Pick a region with at least two zones. `eu-central-1` has three. |
| `InvalidSubnet.Range` or `InvalidSubnet.Conflict` | A subnet range lies outside the VPC range or overlaps another subnet. |
| `InvalidParameterValue` in a security group description | The description contains a character that AWS does not accept. Use plain ASCII. |
| `Cycle` error from Terraform | The two security groups reference each other in their inline rules. Here only `rds_sg` points to `lambda_sg`, never the reverse. |
| `DependencyViolation` when you delete a security group or subnet (`tf destroy`) | A Lambda network interface still uses it. AWS frees it a few minutes after the function is deleted, so wait and run `tf destroy` again. Also remove any rule that you added by hand in the console, for example for CloudShell, before you destroy. |
| `tf plan` wants to replace a subnet | The CIDR range or the zone was changed. Both force a new subnet, and everything inside it must move. |
| `tf plan` shows changes on the security group that you did not make | Somebody edited a rule in the console. Terraform will undo it. |
| `Unsupported argument` on `enable_dns_hostnames` | A typo in the argument name. Check the spelling against the code above. |

## 8. Cost

A VPC, subnets, route tables and security groups are free of charge. What would cost money are the extras that this setup avoids on purpose: **NAT gateways**, **VPC endpoints** and **public IPv4 addresses**, which AWS bills by the hour. Check the current prices on the AWS pricing pages if you add one of them later. Nothing here needs a daily `tf destroy`.

## 9. What to remember

- A **VPC** is your own network. A **subnet** lives in one availability zone. A **route table** decides where traffic goes.
- Without an internet gateway or NAT, a subnet is **private**.
- RDS needs a subnet group over **two** zones, so we have two subnets.
- Security groups are stateful and deny everything that is not allowed.
- The database rule names a **security group** as the source, not an address range.
- `lambda_sg` and `rds_sg` do nothing yet. They get a purpose when the database (step 4) and the functions (step 5) join them.

## 10. Next step

Step 4 fills `infra/rds.tf`: a **DB subnet group** over the two subnets and the **PostgreSQL instance**, protected by `rds_sg`. It adds the variable `db_password`, so the file `terraform.tfvars` holds a secret for the first time. RDS is the part of the project that costs money, and it takes about 8 minutes to create.
