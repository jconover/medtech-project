# --- Phase 1: Core Data Pipeline ---

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1" # You can change this
}

# --- Networking ---
# We create a new VPC to house our infrastructure securely.
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  tags = {
    Name = "medtech-vpc"
  }
}

# A public subnet (for things that need internet access, like our Lambda)
resource "aws_subnet" "public_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-1a"
  map_public_ip_on_launch = true

  tags = {
    Name = "medtech-public-a"
  }
}

# An internet gateway to allow communication with the internet
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "medtech-igw"
  }
}

# A route table to route non-local traffic to the internet gateway
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }
  tags = {
    Name = "medtech-public-rt"
  }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

# --- Security Groups ---
# A security group for our Lambda to allow outbound internet access
resource "aws_security_group" "lambda_sg" {
  name        = "medtech-lambda-sg"
  description = "Allow outbound traffic for Lambda"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "medtech-lambda-sg"
  }
}

# A security group for our RDS database
resource "aws_security_group" "rds_sg" {
  name        = "medtech-rds-sg"
  description = "Allow traffic from Lambda to RDS"
  vpc_id      = aws_vpc.main.id

  # Ingress rule: Allow PostgreSQL traffic ONLY from our Lambda
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda_sg.id] # IMPORTANT!
  }

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

# --- S3: Data Lake ---
resource "aws_s3_bucket" "data_lake" {
  bucket = "medtech-data-lake-auris-${random_id.bucket_suffix.hex}" # Needs a unique name

  tags = {
    Name = "medtech-data-lake"
  }
}

resource "random_id" "bucket_suffix" {
  byte_length = 8
}

# --- RDS: Live Status Database ---
resource "aws_db_subnet_group" "rds_subnets" {
  name       = "medtech-rds-subnet-group"
  # We need to add at least two subnets for RDS
  # For simplicity in Phase 1, we'll just use the one we made.
  # A real-world setup would have private subnets.
  subnet_ids = [aws_subnet.public_a.id]

  tags = {
    Name = "medtech-rds-subnets"
  }
}

resource "aws_db_instance" "status_db" {
  allocated_storage      = 20
  storage_type           = "gp2"
  engine                 = "postgres"
  engine_version         = "15.3"
  instance_class         = "db.t3.micro" # Free tier eligible
  db_name                = "robotstatus"
  username               = "admin"
  password               = "YourSecurePassword123!" # CHANGE THIS
  db_subnet_group_name   = aws_db_subnet_group.rds_subnets.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  skip_final_snapshot    = true
  publicly_accessible    = false # Keep it private
}

# --- SQS: Ingestion Queue ---
resource "aws_sqs_queue" "data_queue" {
  name = "medtech-data-queue"
  tags = {
    Name = "medtech-data-queue"
  }
}

# --- IAM: Permissions for Lambda ---
resource "aws_iam_role" "processor_lambda_role" {
  name = "medtech-processor-lambda-role"

  # Trust policy: allows Lambda to assume this role
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# This policy grants all the permissions our Lambda needs
resource "aws_iam_policy" "lambda_policy" {
  name        = "medtech-lambda-permissions"
  description = "Policy for the processor Lambda"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "logs:CreateLogGroup"
        Resource = "arn:aws:logs:us-east-1:*:*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:us-east-1:*:log-group:/aws/lambda/medtech-processor-lambda:*"
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = aws_sqs_queue.data_queue.arn
      },
      {
        Effect   = "Allow"
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.data_lake.arn}/*"
      },
      {
        # Permissions needed for Lambda to connect to the VPC
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface",
          "ec2:AssignPrivateIpAddresses",
          "ec2:UnassignPrivateIpAddresses"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_policy_attach" {
  role       = aws_iam_role.processor_lambda_role.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}

# --- Lambda: The Processor ---
# We'll upload the code in the next step
resource "aws_lambda_function" "processor_lambda" {
  function_name = "medtech-processor-lambda"
  role          = aws_iam_role.processor_lambda_role.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.11"
  timeout       = 30
  memory_size   = 256

  # We need to deploy the code. 
  # We'll create a zip file `processor_lambda.zip`
  filename      = "processor_lambda.zip"
  source_code_hash = filebase64sha256("processor_lambda.zip")

  # Connect the Lambda to our VPC
  vpc_config {
    subnet_ids         = [aws_subnet.public_a.id]
    security_group_ids = [aws_security_group.lambda_sg.id]
  }

  # Pass database details to the Lambda securely
  environment {
    variables = {
      DB_HOST     = aws_db_instance.status_db.address
      DB_NAME     = aws_db_instance.status_db.db_name
      DB_USER     = aws_db_instance.status_db.username
      DB_PASSWORD = aws_db_instance.status_db.password
      S3_BUCKET   = aws_s3_bucket.data_lake.bucket
    }
  }

  # This tells Lambda to poll our SQS queue
  depends_on = [aws_iam_role_policy_attachment.lambda_policy_attach]
}

# --- Event Source Mapping: SQS -> Lambda ---
resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn = aws_sqs_queue.data_queue.arn
  function_name    = aws_lambda_function.processor_lambda.arn
  batch_size       = 1 # Process one message at a time for simplicity
}

# --- Outputs ---
# This will print the queue URL so we can test it
output "sqs_queue_url" {
  value = aws_sqs_queue.data_queue.id
}
