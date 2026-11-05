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
