# Step 6: API Gateway, the front door

## 1. What are we going to build?

In this step the app gets its **front door**: an HTTP address on the internet that the browser can call. **Amazon API Gateway** receives the request, checks the login token, and only then starts the Lambda function. Without a valid token, the request never reaches our code.

Six Terraform resources are created:

| # | Resource | Job |
|---|---|---|
| 1 | `aws_apigatewayv2_api` | The API itself: its public address and the CORS rules for the browser |
| 2 | `aws_apigatewayv2_authorizer` | The token check. It accepts only tokens issued by our Cognito user pool |
| 3 | `aws_apigatewayv2_integration` | The link between the API and the Lambda function `get_tutorials` |
| 4 | `aws_apigatewayv2_route` | The rule "`GET /tutorials` goes to that integration, and needs a valid token" |
| 5 | `aws_apigatewayv2_stage` | The published version of the API (`$default`, deployed automatically) |
| 6 | `aws_lambda_permission` | Allows API Gateway to start the function |

Together with steps 2 to 5 the project now has **26 resources**.

This step builds **one route only**, `GET /tutorials`. It still ends in the placeholder of step 5, which reports `db_reachable`. The other routes and the real code come in step 7.

At the end of this step:

- `curl` **without** a token answers `401 Unauthorized`,
- `curl` with a **wrong** token also answers `401`,
- `curl` with a **valid** token answers `200`, and the body shows `"db_reachable": true`,
- the browser preflight (CORS) works for the origin `http://127.0.0.1:5500`.

## 2. Prerequisites

- Step 5 is done and merged: `main` contains the tag `step-05`. The route needs `aws_lambda_function.get_tutorials`, and the authorizer needs the Cognito pool and client of step 2.
- If you destroyed the stack after step 5, the plan below shows **26 to add** instead of 6. The database is created again and takes about 8 minutes, and Cognito gets new IDs (see step 2).
- The four `handler.py` files contain the placeholder of step 5 (`wc -l backend/*/handler.py`, all above 0). Otherwise the apply fails halfway (see step 5).
- The AWS credentials work:

```bash
aws sts get-caller-identity
```

- For the optional token test: Live Server on port 5500 and a registered user (see step 2).
- Start the step on its own branch:

```bash
git switch main
git switch -c step-06-api-gateway
```

## 3. The concepts

### The path of a request

```
Browser / curl
     |  HTTPS  GET /tutorials   + header  Authorization: Bearer <token>
     v
API Gateway (HTTP API)
     |  1. find the route "GET /tutorials"
     |  2. authorizer: is the token valid?   no -> 401, the Lambda is never started
     |  3. start the Lambda function (through the Lambda service)
     v
Lambda get_tutorials  (inside the VPC)  ->  RDS
```

API Gateway and the Lambda service both live outside our VPC. API Gateway calls the Lambda **service**, which runs the function in the VPC. That is why the private network of step 3 needs no door for the API.

### HTTP API, not REST API

API Gateway has two products with similar names:

| | HTTP API (`aws_apigatewayv2_*`) | REST API (`aws_api_gateway_*`) |
|---|---|---|
| Price | Cheaper | More expensive |
| JWT check with Cognito | Built in (JWT authorizer) | Built in (Cognito authorizer) |
| Extras (API keys, request validation, caching) | Few | Many |
| Setup | Short | Longer |

We need a token check and a proxy to Lambda, so the HTTP API is enough. That is why the resource names start with `aws_apigatewayv2`. The "v2" is the name of the API generation.

### API, route, integration, stage

| Term | Meaning |
|---|---|
| **API** | The container with the public address `https://<id>.execute-api.<region>.amazonaws.com` |
| **Route** | A combination of method and path, for example `GET /tutorials`. Each route has a target and an authorization setting |
| **Integration** | What the route calls. Here a Lambda function in **proxy** mode: API Gateway hands the whole request to the function and returns what the function answers |
| **Stage** | A published version of the API. The stage named `$default` has no name in the URL, so the address stays short |
| **`auto_deploy`** | Every change of the API goes live at once. Without it, you would have to create a deployment by hand |

### The proxy integration and payload format 2.0

With `integration_type = "AWS_PROXY"` the function receives an event that describes the HTTP request: method, path, headers, query, body and path parameters. With `payload_format_version = "2.0"` the function simply returns a dictionary with `statusCode`, `headers` and `body`, and API Gateway turns it into the HTTP response. Our placeholder already does this.

After a successful token check, the claims of the token are added to the event:

```
event["requestContext"]["authorizer"]["jwt"]["claims"]   ->   {"sub": "...", "email": "...", ...}
```

The step 7 code reads the user from here. The function never sees an unchecked identity: the authorizer has already validated the token.

### The JWT authorizer

A **JWT** (JSON Web Token) is a signed document. Cognito signs it with a private key, and anybody can verify it with the public keys of the user pool. The authorizer does this for every call:

| Check | What is compared |
|---|---|
| **Signature** | Made by our user pool (the keys come from the issuer address) |
| **`iss`** (issuer) | Equals `https://cognito-idp.<region>.amazonaws.com/<pool id>` |
| **`aud`** or **`client_id`** | Equals the ID of our app client |
| **`exp`** | The token has not expired |

If a check fails or the header is missing, API Gateway answers `401` and does **not** start the function. The function never has to check the token itself.

- `identity_sources = ["$request.header.Authorization"]` says where the token is read from.
- The ID token carries our client ID in `aud`. The access token carries it in `client_id`. Because our routes require **no scopes**, both kinds of token pass this check. I took this from the AWS documentation: the authorizer cannot tell the two kinds apart.
- **We still send the ID token** from the frontend. The functions of step 7 need the `email` claim, and only the ID token has it.

### Two kinds of permission for Lambda

| Permission | Question | Where |
|---|---|---|
| **IAM role** of the function (step 5) | What may the function do? | `aws_iam_role` |
| **Resource-based permission** (this step) | Who may **start** the function? | `aws_lambda_permission` |

Without the second one, the API Gateway integration exists but every call fails with an error (`500`), because Lambda refuses the caller. `source_arn` limits the permission to our API only. The ending `/*/*` stands for any stage and any route of this API.

### CORS

The browser blocks calls from one origin (`http://127.0.0.1:5500`) to another (`https://...execute-api...`), unless the API says it is fine. For some calls, such as a `POST` with a JSON body and an `Authorization` header, the browser first sends a **preflight** request: an `OPTIONS` call that asks "may I?". The HTTP API can answer this itself when `cors_configuration` is set. It adds the CORS headers to the answers of our functions too. So our Lambda code needs no CORS headers.

An **origin** is scheme, host and port, with **no path**: `http://127.0.0.1:5500` is correct, `http://127.0.0.1:5500/callback.html` is not.

## 4. The code

Step 6 fills `infra/api_gateway.tf` and extends `variables.tf` and `outputs.tf`.

### `infra/variables.tf` (add at the end)

```hcl
variable "cors_allowed_origins" {
  description = "Origins (scheme, host, port; no path) that may call the API from a browser"
  type        = list(string)
  default     = ["http://127.0.0.1:5500"]
}
```

### `infra/api_gateway.tf`

```hcl
# ---------------------------------------------------------------------------
# The API: public address and CORS rules
# ---------------------------------------------------------------------------

resource "aws_apigatewayv2_api" "tutorials_api" {
  name          = "${var.project_name}-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = var.cors_allowed_origins
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["authorization", "content-type"]
    max_age       = 3600
  }

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# The authorizer: only tokens from our Cognito user pool pass
# ---------------------------------------------------------------------------

resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.tutorials_api.id
  name             = "cognito-jwt"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.tutorials_client.id]
    issuer   = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.tutorials_pool.id}"
  }
}

# ---------------------------------------------------------------------------
# The stage: the published API. "$default" keeps the URL short.
# ---------------------------------------------------------------------------

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.tutorials_api.id
  name        = "$default"
  auto_deploy = true

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# get_tutorials: GET /tutorials
# ---------------------------------------------------------------------------

resource "aws_apigatewayv2_integration" "get_tutorials" {
  api_id                 = aws_apigatewayv2_api.tutorials_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.get_tutorials.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "get_tutorials" {
  api_id             = aws_apigatewayv2_api.tutorials_api.id
  route_key          = "GET /tutorials"
  target             = "integrations/${aws_apigatewayv2_integration.get_tutorials.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

# Allows API Gateway (and only this API) to start the function
resource "aws_lambda_permission" "get_tutorials_from_api" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.get_tutorials.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.tutorials_api.execution_arn}/*/*"
}
```

`var.aws_region` comes from step 2. The names `aws_cognito_user_pool.tutorials_pool` and `aws_cognito_user_pool_client.tutorials_client` also come from step 2. If you named them differently, change them here.

### `infra/outputs.tf` (add at the end)

```hcl
output "api_url" {
  description = "Base address of the API"
  value       = aws_apigatewayv2_api.tutorials_api.api_endpoint
}
```

The address has no trailing slash and no stage name. A call goes to `$(tf output -raw api_url)/tutorials`.

## 5. Why it is done this way

| Decision | Reason |
|---|---|
| **HTTP API instead of REST API** | Cheaper and shorter to configure. We need none of the REST-only extras. |
| **JWT authorizer in API Gateway** | The token check happens before the function starts. Unauthenticated calls cost no Lambda time and cannot reach the database. |
| **`audience` = client ID, `issuer` = pool address** | Only tokens that Cognito issued for **our** app client pass. A token from another pool or another app is rejected. |
| **No scopes on the route** | Keeps the first version simple. The `sub` of the token identifies the user, and every logged-in user may use every route. |
| **ID token sent by the frontend** | It carries `email`. The functions need it for `users` in step 7. |
| **`AWS_PROXY` and payload format `2.0`** | The simplest contract: the function gets the whole request and returns `statusCode`, `headers`, `body`. |
| **One Lambda per route group, one integration per function** | In step 7 two routes share the integration of `get_tutorials`. |
| **`aws_lambda_permission` with `source_arn`** | Without it, API Gateway cannot start the function. With `source_arn` only this API can, and no other API in the account. |
| **`/*/*` at the end of `source_arn`** | Any stage and any route of this API. Narrower is possible (one permission per route) but it adds resources. |
| **Stage `$default` with `auto_deploy`** | A short URL and no manual deployment step. |
| **CORS in the API, not in the Lambda code** | One place for the rules, and the preflight is answered without starting a function. |
| **`cors_allowed_origins` as a variable** | When the frontend moves to CloudFront, you add its origin without editing the resource. |
| **Allowed headers `authorization` and `content-type`** | These are the two headers the frontend sends. The browser blocks the call if a header is missing in this list. |
| **No access logs, no throttling settings** | Not needed for learning. A real API would log requests and limit the rate. |

## 6. Run and verify

```bash
cd infra
tf fmt
tf validate
tf plan -out="actions.tfplan"
```

Expected: **6 to add, 0 to change, 0 to destroy**. The resources of steps 2 to 5 must not be in the plan. If the plan shows 26 to add, the state is empty (see section 2).

```bash
tf apply actions.tfplan
tf output api_url
```

An HTTP API is created in seconds. If the database was destroyed before, the apply first waits for it.

### Test 1: no token, expect 401

```bash
curl -i "$(tf output -raw api_url)/tutorials"
```

Expected: `HTTP/2 401` and the body `{"message":"Unauthorized"}`. The function was **not** started. You can check this in the logs: no new `START` line appears.

### Test 2: a wrong token, expect 401

```bash
curl -i -H "Authorization: Bearer not-a-real-token" "$(tf output -raw api_url)/tutorials"
```

Expected: `401` again. The header is present but the token is not a valid JWT.

### Test 3: the CORS preflight

```bash
curl -i -X OPTIONS "$(tf output -raw api_url)/tutorials" \
  -H "Origin: http://127.0.0.1:5500" \
  -H "Access-Control-Request-Method: GET" \
  -H "Access-Control-Request-Headers: authorization"
```

Expected: a success status (`204` or `200`) with the headers `access-control-allow-origin: http://127.0.0.1:5500`, `access-control-allow-methods` and `access-control-allow-headers`. The preflight needs **no token**.

Repeat it with `-H "Origin: http://example.com"`. The answer must **not** contain `access-control-allow-origin` for that origin.

I have not run this test against your API. Compare the exact status code on your side.

### Test 4 (optional): a valid token, expect 200

This is the real test of the chain **token -> authorizer -> Lambda -> RDS**. You need an ID token. The frontend will do the exchange in step 7. Here we do it by hand, once.

1. Start Live Server on port 5500, open the value of `cognito_login_url` and log in.
2. The browser lands on `http://127.0.0.1:5500/callback.html?code=...`. Copy the value after `code=` from the address bar. It works **once** and only for a few minutes.
3. Exchange the code for tokens (the client has no secret, and Cognito does not require PKCE for such a client):

```bash
CODE="paste-the-code-here"

ID_TOKEN=$(curl -s -X POST "$(tf output -raw cognito_hosted_ui_domain)/oauth2/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "grant_type=authorization_code" \
  --data-urlencode "client_id=$(tf output -raw cognito_user_pool_client_id)" \
  --data-urlencode "code=$CODE" \
  --data-urlencode "redirect_uri=http://127.0.0.1:5500/callback.html" \
  | jq -r .id_token)

echo "${#ID_TOKEN} characters"
```

A real token has more than 800 characters. If the output is `4 characters`, the answer was an error (`null`). Run the `curl` without `| jq -r .id_token` to read the error message. The usual causes are an expired or already used code, and a `redirect_uri` that differs from the one in the login URL.

4. Call the API with the token:

```bash
curl -i -H "Authorization: Bearer $ID_TOKEN" "$(tf output -raw api_url)/tutorials"
```

Expected: `HTTP/2 200` and a body with `"db_reachable": true` (the placeholder of step 5). The same call without the header is `401`.

The token stays in a shell variable, not in a file. Do not paste it anywhere. It is valid for 60 minutes and identifies you.

### Test 5: look at the configuration

```bash
API_ID=$(aws apigatewayv2 get-apis \
  --query "Items[?Name=='tutorials-app-api'].ApiId | [0]" --output text)

aws apigatewayv2 get-routes --api-id "$API_ID" \
  --query "Items[].[RouteKey,AuthorizationType]" --output text

aws apigatewayv2 get-authorizers --api-id "$API_ID" \
  --query "Items[].[Name,JwtConfiguration.Issuer,JwtConfiguration.Audience[0]]" --output text

tf output cognito_user_pool_id
tf output cognito_user_pool_client_id
```

Expected: the route `GET /tutorials` with `JWT`, and an authorizer whose issuer ends with the pool ID and whose audience equals the client ID.

### Commit, merge, tag

```bash
git status                  # no tfvars, no tfstate, no tfplan, no infra/build in the list
git add -A
git commit -m "Step 6: HTTP API, Cognito JWT authorizer and route GET /tutorials"
git switch main
git merge --no-ff step-06-api-gateway
git tag -a step-06 -m "API Gateway"
git push origin main --tags
git branch -d step-06-api-gateway
```

## 7. Typical problems

The texts below are written from memory, except where the table says otherwise. Compare them with what you see.

| Symptom | Likely cause |
|---|---|
| `401` **with** a token you believe is valid | The token is expired (60 minutes), comes from an old user pool (after a destroy and apply the pool and the client ID change), or the `Authorization` header is not sent. Get a new token. |
| `401` for every token, also fresh ones | `issuer` or `audience` in the authorizer does not match. Compare them with Test 5. The issuer has no trailing slash. |
| `500 Internal Server Error` or `{"message":"Internal Server Error"}` with a valid token | The function failed or API Gateway cannot start it. Check the log group `/aws/lambda/tutorials-app-get-tutorials`. If no new `START` line appears, check the `aws_lambda_permission` and its `source_arn`. |
| `404 Not Found` | The method or the path matches no route. Only `GET /tutorials` exists in this step. |
| `403 Forbidden` | Check the stage and the address. A wrong host name usually gives another error, so compare `api_url` with what you call. |
| The browser says "blocked by CORS policy" | The origin is missing in `cors_allowed_origins`, or it has a path, a trailing slash or another port. Also check that the header you send is in `allow_headers`. |
| Preflight works in `curl` but the browser still fails | Look at the real call in the browser's developer tools. A `401` or `500` answer without CORS headers is shown as a CORS error too. Test the call with `curl` first. |
| `tf apply` error: the integration cannot be created because the function does not exist | The function resource has a different name. Check `aws_lambda_function.get_tutorials` in `lambda.tf`. |
| `tf plan` wants to replace the stage | The `name` was changed. Keep `$default`. |
| After `tf destroy` and `apply` the API address changed | The API ID is part of the address. Update the address in the frontend config. |
| `jq: command not found` | Install it: `brew install jq`. |
| `ConflictException` on `aws_lambda_permission` (statement already exists) | The same `statement_id` exists on the function, for example added by hand in the console. Delete it there or use another `statement_id`. |

## 8. Cost and cleanup

An HTTP API is billed per request, with a small price per million calls. A learning project makes a few hundred calls. Check the current price on the API Gateway pricing page and whether your account has a free tier for it. The authorizer, routes and stage are free.

The costly part is still the database from step 4. Run `tf destroy` at the end of each session. After the next `apply` the API address, the client ID and the login URL are new.

## 9. What to remember

- API Gateway is the only public door. The database, the network and the functions stay private.
- A **route** needs a target and an authorization setting. The **authorizer** checks the token before the function starts.
- The JWT authorizer checks signature, issuer, audience (or client ID) and expiry. A missing or wrong token gives `401`.
- Our routes ask for no scopes, so ID tokens and access tokens both pass. We send the **ID token**, because it carries `email`.
- The identity reaches the function in `event["requestContext"]["authorizer"]["jwt"]["claims"]`.
- Without the `aws_lambda_permission`, API Gateway cannot start the function.
- CORS rules live in the API and are answered without starting a function. An origin has no path.
- `stage = $default` with `auto_deploy` keeps the address short and deploys every change.

## 10. Next step

Step 7 is the application itself. It adds the database schema, the shared Python code, the real handlers of the four functions, and the build script that packages the libraries. It also adds the remaining routes: `GET /tutorials/{id}`, `POST /tutorials` and `POST /tutorials/{id}/rating`, which brings the project to **33 resources**. The frontend (login, API calls) follows after it.
