# MedTech Data Platform Project

This project is a hands-on demonstration of a scalable, automated data platform built on AWS, designed for a high-availability MedTech environment. It showcases a complete DevOps workflow, including Infrastructure-as-Code (Terraform), containerization (Docker/ECS), CI/CD (GitHub Actions), and a full data lifecycle (SQS, Lambda, S3, RDS, Athena, Redshift).

## Project Architecture

A high-level diagram will be added here once the components are built.

## Phase 1: The Core Data Pipeline

**Goal**: Build the backend processing pipeline. Data sent to an SQS queue will be automatically processed by a Lambda, fanning out to S3 (for the data lake) and RDS (for live status).

## How to Build & Deploy Phase 1

### Prerequisites

- AWS Account
- Terraform CLI installed
- AWS CLI installed and configured (with credentials)  
- Python 3.11+ and pip installed

### Package the Lambda Function

The Lambda function has a Python dependency (psycopg2-binary) that must be included in its deployment package. Run these commands from the root of the `medtech-project/` directory:

```bash
# 1. Install dependencies into a temporary 'pkg' folder
pip install -r processor-lambda/requirements.txt -t processor-lambda/pkg

# 2. Go into the 'pkg' folder and zip its contents
cd processor-lambda/pkg
zip -r ../../processor_lambda.zip .

# 3. Go back to the root and add your function code to the zip
cd ../..
cd processor-lambda
zip -g ../processor_lambda.zip lambda_function.py
cd ..

# 4. Move the final zip file to the Terraform directory so it can be deployed
mv processor_lambda.zip iac_phase1/
```

### Deploy with Terraform

Navigate to the Terraform directory and deploy the infrastructure:

```bash
cd iac_phase1
terraform init
terraform apply
```

This will take 10-15 minutes (mostly for the RDS database). On success, it will output an `sqs_queue_url`. Copy this.

### Test the Pipeline

Use the AWS CLI to send a test message to the queue (replace `YOUR_SQS_QUEUE_URL_HERE` with the output from Terraform):

```bash
aws sqs send-message \
    --queue-url "YOUR_SQS_QUEUE_URL_HERE" \
    --message-body '{
        "robot_id": "robot-A1-test",
        "procedure_id": "proc-999-test",
        "timestamp": "2025-10-24T14:30:00Z",
        "status": "nominal",
        "voltage": 12.5,
        "position": {"x": 100, "y": 250, "z": 80}
    }'
```

### Verify the Results

- **S3**: Check your `medtech-data-lake...` bucket. You should see a new JSON file in the `raw_logs/` directory.
- **CloudWatch**: Go to the `medtech-processor-lambda` function's logs in CloudWatch. You should see print statements confirming the database write was successful.
