# Step 2: Cognito, users and login

## 1. What are we going to build?

In this step the app gets its **users and the login**. We do not write a login page and we do not store passwords ourselves. **Amazon Cognito** does both: it shows a ready-made login page (the **Hosted UI**), handles sign-up with an e-mail confirmation, handles "forgot password", and hands the app signed **tokens** after a successful login.

Four Terraform resources are created. The Cognito free tier covers a project of this size, and the current figures are on the Cognito pricing page.

| # | Resource | Job |
|---|---|---|
| 1 | `aws_cognito_user_pool` | The user directory: who exists, password rules, e-mail verification, password recovery |
| 2 | `aws_cognito_user_pool_client` | One registered application (our website) that may use the pool, and how it may log users in |
| 3 | `random_id` | A random suffix, so that the domain name is unique worldwide |
| 4 | `aws_cognito_user_pool_domain` | The public address of the Hosted UI login page |

At the end of this step:

- the login URL opens the Cognito login page,
- a new user can register with an e-mail address and confirm it with a code,
- a login ends on `http://127.0.0.1:5500/callback.html?code=...`,
- a forgotten password can be reset.

The `code` in that URL is not a token yet. Exchanging it for tokens is the job of the frontend (step 9).

## 2. Prerequisites

- Step 1 is done: the repository, the folders and the empty files exist.
- Terraform is installed, and `tf` is the alias for `terraform` from step 1.
- The AWS CLI is configured with credentials. This command prints the account and the user:

```bash
aws sts get-caller-identity
```

- A tool serves the `frontend/` folder on **port 5500**, for example the VS Code extension Live Server. The port has to match the callback URL below.
- The step starts on its own branch:

```bash
git switch -c step-02-cognito
```

## 3. The concepts

### User pool, app client, domain

```
User pool        the directory of users            (who may log in)
   |
   +-- App client   our website, registered here    (how it may log in)
   |
   +-- Domain       https://<prefix>.auth.<region>.amazoncognito.com   (where the login page lives)
```

- The **user pool** knows the users. One pool can serve several applications.
- An **app client** is one application. It decides which redirect addresses are allowed and which scopes it may ask for. The client ID is public and is not a secret.
- The **domain** is the web address of the Hosted UI. Without a domain there is no login page.

### The login flow (authorization code flow)

```
1. The browser opens the login URL           ->  Cognito Hosted UI
2. The user signs up or logs in              ->  Cognito checks the password
3. Cognito redirects the browser to          ->  http://127.0.0.1:5500/callback.html?code=abc123
4. callback.html sends the code to Cognito   ->  receives the tokens   (step 9)
```

The tokens never travel in the URL. Only a short-lived, one-time `code` does, and it is useless without the second call in step 4. This is why the **code flow** is the recommended one for web apps.

### Public client, no secret

A JavaScript app runs in the user's browser, so anyone can read its code. A client secret in such code would not be secret. The client therefore has `generate_secret = false`. The code exchange is protected by **PKCE**, a one-time proof that the frontend creates and sends in step 9.

### Tokens, and which one the app uses

After the code exchange the frontend receives three tokens:

| Token | Contains | Used for |
|---|---|---|
| **ID token** | Who the user is: `sub` (unique ID) and `email` | Sent to our API. The API authorizer checks it, and the Lambda functions read `sub` and `email` from it |
| **Access token** | What the client may do (scopes) | Not used by our API |
| **Refresh token** | Nothing readable | Gets new tokens without a new login |

### What each setting means

| Setting | Meaning |
|---|---|
| `username_attributes = ["email"]` | Users log in with their e-mail address. There is no separate user name |
| `auto_verified_attributes = ["email"]` | Cognito sends a confirmation code to the e-mail address and marks it as verified |
| `account_recovery_setting` | "Forgot password" sends a code to the verified e-mail address |
| `email_sending_account = "COGNITO_DEFAULT"` | Cognito itself sends the e-mails. No extra setup is needed, but the daily limit is small |
| `allowed_oauth_flows = ["code"]` | Only the authorization code flow is allowed |
| `allowed_oauth_scopes` | `openid` makes the ID token available, `email` and `profile` add the matching claims |
| `callback_urls` | The only addresses Cognito may redirect to after a login |
| `prevent_user_existence_errors = "ENABLED"` | A wrong user name and a wrong password give the same error message, so an attacker cannot find out which e-mail addresses are registered |

## 4. The code

Step 2 fills four files in `infra/` and adds one example file.

### `infra/main.tf`

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
  }
}

provider "aws" {
  region = var.aws_region
}

locals {
  common_tags = {
    Project   = var.project_name
    ManagedBy = "terraform"
  }
}
```

Step 5 adds the `archive` provider to this block. The version constraints are deliberately loose. After `tf init`, the file `.terraform.lock.hcl` records the exact versions that were installed. It is committed together with this step.

### `infra/variables.tf`

```hcl
variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "eu-central-1"
}

variable "project_name" {
  description = "Prefix for resource names"
  type        = string
  default     = "tutorials-app"
}

variable "callback_urls" {
  description = "Addresses Cognito may redirect to after login"
  type        = list(string)
  default     = ["http://127.0.0.1:5500/callback.html"]
}

variable "logout_urls" {
  description = "Addresses Cognito may redirect to after logout"
  type        = list(string)
  default     = ["http://127.0.0.1:5500/index.html"]
}
```

### `infra/cognito.tf`

```hcl
resource "aws_cognito_user_pool" "tutorials_pool" {
  name = "${var.project_name}-users"

  # Users log in with their e-mail address
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = false
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  # Cognito sends the e-mails itself (no extra service needed)
  email_configuration {
    email_sending_account = "COGNITO_DEFAULT"
  }

  tags = local.common_tags
}

resource "aws_cognito_user_pool_client" "tutorials_client" {
  name         = "${var.project_name}-web-client"
  user_pool_id = aws_cognito_user_pool.tutorials_pool.id

  # Browser app: no client secret, PKCE protects the code exchange
  generate_secret = false

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"]

  callback_urls = var.callback_urls
  logout_urls   = var.logout_urls

  # Same error for "unknown user" and "wrong password"
  prevent_user_existence_errors = "ENABLED"

  explicit_auth_flows = ["ALLOW_REFRESH_TOKEN_AUTH"]

  id_token_validity      = 60
  access_token_validity  = 60
  refresh_token_validity = 30

  token_validity_units {
    id_token      = "minutes"
    access_token  = "minutes"
    refresh_token = "days"
  }
}

# The domain prefix must be unique worldwide, so a random suffix is added
resource "random_id" "cognito_domain_suffix" {
  byte_length = 4
}

resource "aws_cognito_user_pool_domain" "tutorials_domain" {
  domain       = "${var.project_name}-${random_id.cognito_domain_suffix.hex}"
  user_pool_id = aws_cognito_user_pool.tutorials_pool.id
}
```

### `infra/outputs.tf`

```hcl
output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.tutorials_pool.id
}

output "cognito_user_pool_client_id" {
  value = aws_cognito_user_pool_client.tutorials_client.id
}

output "cognito_hosted_ui_domain" {
  value = "https://${aws_cognito_user_pool_domain.tutorials_domain.domain}.auth.${var.aws_region}.amazoncognito.com"
}

output "cognito_login_url" {
  value = "https://${aws_cognito_user_pool_domain.tutorials_domain.domain}.auth.${var.aws_region}.amazoncognito.com/login?client_id=${aws_cognito_user_pool_client.tutorials_client.id}&response_type=code&scope=email+openid+profile&redirect_uri=${urlencode(var.callback_urls[0])}"
}
```

### `infra/terraform.tfvars.example`

```hcl
aws_region    = "eu-central-1"
project_name  = "tutorials-app"
callback_urls = ["http://127.0.0.1:5500/callback.html"]
logout_urls   = ["http://127.0.0.1:5500/index.html"]
```

A copy named `terraform.tfvars` overrides the defaults. All four variables have defaults, so the file is optional in this step. It contains no secret yet, because the database password arrives in step 4.

## 5. Why it is done this way

| Decision | Reason |
|---|---|
| **Cognito instead of our own login** | Storing passwords, sending codes and issuing signed tokens are security tasks. A managed service does them more reliably than code written for one project |
| **Hosted UI** | A working login page without any frontend code. It can be replaced later |
| **E-mail as the user name** | Fewer things for the user to remember, and the `email` claim ends up in the token |
| **Code flow, no secret, PKCE** | The recommended flow for browser apps. No token in the URL and no secret in public code |
| **Only `code` in `allowed_oauth_flows`** | The simpler "implicit" flow puts tokens in the URL, so it stays switched off |
| **`prevent_user_existence_errors`** | Stops attackers from testing which e-mail addresses are registered |
| **`random_id` for the domain** | Domain prefixes are unique across all AWS accounts in a region, so a fixed name may already be taken |
| **ID token valid for 60 minutes** | Short enough to limit the damage if a token leaks. The refresh token (30 days) keeps the user logged in |
| **`callback_urls` as a variable** | When the frontend moves to CloudFront, its address is added without editing the resource |
| **`COGNITO_DEFAULT` for e-mails** | No extra service, enough for learning. A production app would use Amazon SES |
| **No MFA, no SMS** | Not needed here. SMS would also bring costs and an extra registration |

## 6. Run and verify

```bash
cd infra
tf init          # downloads the aws and random providers
tf fmt
tf validate
tf plan -out="actions.tfplan"
```

Expected: **4 to add, 0 to change, 0 to destroy**, and four new outputs marked `(known after apply)`.

```bash
tf apply actions.tfplan
tf output
```

One plan file name is used consistently, and each apply uses the plan that was created last. A plan file that was already applied, or that is older than the last change of the state, ends with `Saved plan is stale`. A new `tf plan -out=...` solves it.

### Test 1: sign-up

1. Live Server runs on port 5500. The page `callback.html` is still empty, which is fine here.
2. The value of `cognito_login_url` opens the Cognito login page in the browser.
3. **Sign up** asks for an e-mail address and a password that follows the rules.
4. Cognito sends a code to the mailbox. The spam folder sometimes holds it. The code is entered on the next page.
5. After the confirmation the browser is redirected to `http://127.0.0.1:5500/callback.html?code=...`.

The browser may show a blank page, because `callback.html` is empty. What counts is the `code=` in the address bar.

### Test 2: login and password reset

1. The login URL opens again, and the same user logs in. The browser lands on `callback.html?code=...` again.
2. On the login page, **Forgot your password?** asks for the e-mail address, then the code that arrives by e-mail, then a new password. A login with the new password follows.

### Test 3: the CLI view

```bash
POOL=$(tf output -raw cognito_user_pool_id)

aws cognito-idp list-users --user-pool-id "$POOL" \
  --query "Users[].[Username,UserStatus]" --output table

aws cognito-idp describe-user-pool-client \
  --user-pool-id "$POOL" \
  --client-id "$(tf output -raw cognito_user_pool_client_id)" \
  --query "UserPoolClient.[AllowedOAuthFlows,CallbackURLs,PreventUserExistenceErrors]"
```

The user has the status `CONFIRMED`. The client shows the flow `code` and the callback URL.

### Removing test users

```bash
aws cognito-idp admin-delete-user --user-pool-id "$POOL" --username "<the Username from list-users>"
```

### Commit, merge, tag

```bash
git status                  # no tfvars, no tfstate, no tfplan in the list
git add -A
git commit -m "Step 2: Cognito user pool, app client and domain"
git switch main
git merge --no-ff step-02-cognito
git tag -a step-02 -m "Cognito login working"
git push origin main --tags
git branch -d step-02-cognito
```

`infra/.terraform.lock.hcl` and `docs/step-02-cognito.md` are part of this commit.

## 7. Typical problems

| Symptom | Likely cause |
|---|---|
| Cognito page: `redirect_mismatch` | `redirect_uri` is not in `callback_urls`. The comparison is character by character: `127.0.0.1` is not `localhost`, and the port and `http` have to match |
| Cognito page: `invalid_request` or `Invalid client_id` | The login URL comes from an earlier apply. After a destroy and an apply, the client ID and the domain change, so the new `cognito_login_url` is the valid one |
| `Error: ... domain ... already exists` or `Domain already associated` | The prefix is taken. `tf apply -replace=random_id.cognito_domain_suffix` generates a new suffix |
| `InvalidParameterException` about the domain | The prefix may only contain lowercase letters, digits and hyphens, and AWS reserves some words |
| No confirmation e-mail arrives | The spam folder is the first place to look. With `COGNITO_DEFAULT` the number of e-mails per day is small, so many test sign-ups can use it up. The current limit is in the Cognito documentation, and `admin-confirm-sign-up` confirms a user without an e-mail |
| Browser shows `404` on `callback.html` | Live Server is not running, it runs on another port, or the file does not exist |
| Console banner `SubscriptionRequiredException ... AWS End User Messaging SMS` | The console page for authentication methods tries to read SMS settings. The project uses no SMS, so the banner has no effect |
| `tf plan` wants to replace the domain | The domain depends on `random_id`, which stays stable as long as the state exists. Without the state, a new suffix is generated, and with it a new login URL |
| `NoCredentialProviders` or `ExpiredToken` | The AWS credentials are missing or expired. `aws sts get-caller-identity` shows which |

## 8. Cost and cleanup

Cognito has a free tier for monthly active users, which a learning project does not reach. The current figures are on the Cognito pricing page. Nothing in this step is billed per hour, so the pool can stay up between sessions. `tf destroy` removes everything, including all users in the pool. The next `apply` creates a **new** pool, a new client ID and a new domain, so the login URL changes and the users register again.

## 9. What to remember

- Cognito does the login, so the frontend never handles a password.
- Three objects: the **pool** (users), the **client** (our app) and the **domain** (the address of the login page).
- After a successful login the browser arrives at `callback.html?code=...`. The code becomes tokens in step 9.
- The **ID token** carries `sub` and `email`, and it is the token that the API uses.
- `callback_urls` has to match the redirect address exactly.
- There is one `infra/` folder and one state. This step only adds files, and step 3 adds the network next to them.

## 10. Next step

Step 3 fills `infra/vpc.tf`: the VPC, two private subnets in two availability zones, a route table and two security groups. It is free of charge and prepares the place where the database and the functions will live.
