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
