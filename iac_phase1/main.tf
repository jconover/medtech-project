terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# ------------------------------------------------------------------------------
# VPC & NETWORKING
# ------------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "medtech-vpc"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "medtech-igw"
  }
}

# We need subnets in at least 2 Availability Zones for RDS
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.${10 + count.index}.0/24" # 10.0.10.0/24, 10.0.11.0/24
  availability_zone       = "us-east-1${element(["a", "b"], count.index)}"
  map_public_ip_on_launch = true

  tags = {
    Name = "medtech-public-subnet-${count.index + 1}"
  }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${20 + count.index}.0/24" # 10.0.20.0/24, 10.0.21.0/24
  availability_zone = "us-east-1${element(["a", "b"], count.index)}"

  tags = {
    Name = "medtech-private-subnet-${count.index + 1}"
  }
}

# Route table for public subnets to have internet access
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "medtech-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ------------------------------------------------------------------------------
# RESOURCES FOR DATA LAKE & QUEUEING
# ------------------------------------------------------------------------------

resource "aws_s3_bucket" "data_lake" {
  bucket = "medtech-data-lake-${random_id.bucket_suffix.hex}"

  tags = {
    Name = "medtech-data-lake"
  }
}

resource "aws_s3_bucket_public_access_block" "data_lake_pac" {
  bucket                  = aws_s3_bucket.data_lake.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_sqs_queue" "data_queue" {
  name                      = "medtech-data-queue"
  visibility_timeout_seconds = 300 # Give Lambda 5 mins to process
  message_retention_seconds = 86400 # 1 day

  tags = {
    Name = "medtech-data-queue"
  }
}

resource "random_id" "bucket_suffix" {
  byte_length = 8
}

# ------------------------------------------------------------------------------
# RESOURCES FOR "LIVE" DATABASE
# ------------------------------------------------------------------------------

resource "aws_security_group" "rds_sg" {
  name        = "medtech-rds-sg"
  description = "Allow access to RDS from Lambda"
  vpc_id      = aws_vpc.main.id

  # Ingress from Lambda (will be defined later)
  # Egress to anywhere (for updates, etc.)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "medtech-rds-sg"
  }
}

resource "aws_db_subnet_group" "rds_subnets" {
  name       = "medtech-rds-subnet-group"
  subnet_ids = aws_subnet.private.*.id 

  tags = {
    Name = "medtech-rds-subnets"
  }
}

resource "random_password" "db_password" {
  length  = 16
  special = false
}

resource "aws_db_instance" "main_db" {
  allocated_storage      = 20
  engine                 = "postgres"
  engine_version         = "15.4"
  instance_class         = "db.t3.micro"
  identifier             = "medtech-db"
  db_name                = "medtechdb"
  username               = "dbadmin"
  password               = random_password.db_password.result
  db_subnet_group_name   = aws_db_subnet_group.rds_subnets.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  skip_final_snapshot    = true
  publicly_accessible    = false # Keep it private

  tags = {
    Name = "medtech-main-db"
  }
}

# ------------------------------------------------------------------------------
# RESOURCES FOR PROCESSING LOGIC
# ------------------------------------------------------------------------------

resource "aws_security_group" "lambda_sg" {
  name        = "medtech-lambda-sg"
  description = "Allow Lambda to access RDS and S3"
  vpc_id      = aws_vpc.main.id

  # Allow egress to RDS
  egress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.rds_sg.id]
  }
  
  # Allow egress to S3 (via VPC Endpoint)
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    prefix_list_ids = [aws_vpc_endpoint.s3.prefix_list_id]
  }

  tags = {
    Name = "medtech-lambda-sg"
  }
}

# Allow RDS to accept connections from Lambda
resource "aws_security_group_rule" "lambda_to_rds" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.lambda_sg.id
  security_group_id        = aws_security_group.rds_sg.id
}

# Create a VPC Endpoint for S3 so the private Lambda can reach it
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  route_table_ids   = [aws_vpc.main.private_route_table_ids[0], aws_vpc.main.private_route_table_ids[1]]
}

# IAM Role for Lambda
resource "aws_iam_role" "lambda_role" {
  name = "medtech-processor-lambda-role"

  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "medtech-lambda-role"
  }
}

# Policy for Lambda
resource "aws_iam_policy" "lambda_policy" {
  name        = "medtech-lambda-policy"
  description = "Policy for Lambda to access SQS, S3, RDS, and create ENIs"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # SQS Permissions
      {
        Effect = "Allow",
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ],
        Resource = aws_sqs_queue.data_queue.arn
      },
      # S3 Permissions
      {
        Effect = "Allow",
        Action = [
          "s3:PutObject"
        ],
        Resource = "${aws_s3_bucket.data_lake.arn}/*"
      },
      # VPC ENI Permissions (for running in a VPC)
      {
        Effect = "Allow",
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface",
          "ec2:AssignPrivateIpAddresses",
          "ec2:UnassignPrivateIpAddresses"
        ],
        Resource = "*"
      },
      # CloudWatch Logs
      {
        Effect = "Allow",
        Action = [
            "logs:CreateLogGroup",
            "logs:CreateLogStream",
            "logs:PutLogEvents"
        ],
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_policy_attach" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}

resource "aws_lambda_function" "processor_lambda" {
  function_name = "medtech-processor-lambda"
  role          = aws_iam_role.lambda_role.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.11"
  timeout       = 300 # 5 minutes

  filename         = "processor_lambda.zip"
  source_code_hash = filebase64sha256("processor_lambda.zip")

  # Environment variables to pass DB info to the Lambda
  environment {
    variables = {
      DB_HOST     = aws_db_instance.main_db.address
      DB_NAME     = aws_db_instance.main_db.db_name
      DB_USER     = aws_db_instance.main_db.username
      DB_PASSWORD = aws_db_instance.main_db.password
      S3_BUCKET   = aws_s3_bucket.data_lake.bucket
    }
  }

  # Connect Lambda to our VPC
  vpc_config {
    subnet_ids         = aws_subnet.private.*.id
    security_group_ids = [aws_security_group.lambda_sg.id]
  }

  depends_on = [
    aws_db_instance.main_db,
    aws_vpc_endpoint.s3
  ]

  tags = {
    Name = "medtech-processor-lambda"
  }
}

# Trigger Lambda from SQS
resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn = aws_sqs_queue.data_queue.arn
  function_name    = aws_lambda_function.processor_lambda.arn
  batch_size       = 1 # Process one message at a time
}

# ------------------------------------------------------------------------------
# VARIABLES & OUTPUTS
# ------------------------------------------------------------------------------

variable "aws_region" {
  description = "The AWS region to deploy resources in."
  type        = string
  default     = "us-east-1"
}

output "sqs_queue_url" {
  description = "The URL of the SQS data queue"
  value       = aws_sqs_queue.data_queue.id
}

output "s3_bucket_name" {
  description = "The name of the S3 data lake bucket"
  value       = aws_s3_bucket.data_lake.bucket
}

output "rds_hostname" {
  description = "The hostname of the RDS database"
  value       = aws_db_instance.main_db.address
}

