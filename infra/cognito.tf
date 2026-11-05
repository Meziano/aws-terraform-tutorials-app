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

# The domain prefix must be unique worldwide, so we add a random suffix
resource "random_id" "cognito_domain_suffix" {
  byte_length = 4
}

resource "aws_cognito_user_pool_domain" "tutorials_domain" {
  domain       = "${var.project_name}-${random_id.cognito_domain_suffix.hex}"
  user_pool_id = aws_cognito_user_pool.tutorials_pool.id
}
