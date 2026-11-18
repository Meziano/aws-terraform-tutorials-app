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

output "vpc_id" {
  value = aws_vpc.main.id
}

output "lambda_sg_id" {
  value = aws_security_group.lambda_sg.id
}

output "rds_sg_id" {
  value = aws_security_group.rds_sg.id
}
