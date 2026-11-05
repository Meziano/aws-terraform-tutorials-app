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
