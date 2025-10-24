import json
import os
import boto3
import psycopg2
import sys
from datetime import datetime

# Get environment variables
DB_HOST = os.environ.get("DB_HOST")
DB_NAME = os.environ.get("DB_NAME")
DB_USER = os.environ.get("DB_USER")
DB_PASSWORD = os.environ.get("DB_PASSWORD")
S3_BUCKET = os.environ.get("S3_BUCKET")

# Initialize clients
s3_client = boto3.client("s3")
db_conn = None

def get_db_connection():
    """Establishes a connection to the PostgreSQL database."""
    global db_conn
    if db_conn:
        return db_conn
    try:
        print(f"Connecting to database {DB_NAME} at {DB_HOST}...")
        conn = psycopg2.connect(
            host=DB_HOST,
            dbname=DB_NAME,
            user=DB_USER,
            password=DB_PASSWORD,
            port=5432
        )
        print("Database connection successful.")
        return conn
    except Exception as e:
        print(f"ERROR: Could not connect to database: {e}")
        sys.exit(1) # Exit if we can't connect

def init_database():
    """
    Initializes the database table if it doesn't exist.
    This is a good practice for the first run.
    """
    conn = get_db_connection()
    try:
        with conn.cursor() as cur:
            cur.execute("""
                CREATE TABLE IF NOT EXISTS robot_status (
                    id SERIAL PRIMARY KEY,
                    robot_id VARCHAR(50) NOT NULL,
                    procedure_id VARCHAR(50) NOT NULL,
                    status VARCHAR(20) NOT NULL,
                    recorded_at TIMESTAMP NOT NULL
                );
            """)
            conn.commit()
            print("Table 'robot_status' initialized.")
    except Exception as e:
        print(f"ERROR: Could not initialize table: {e}")
        conn.rollback()


# --- Main Handler ---
# Initialize the DB connection and table *outside* the handler
# This allows AWS Lambda to reuse the connection across invocations
init_database()

def lambda_handler(event, context):
    print(f"Received {len(event['Records'])} records from SQS.")
    
    conn = get_db_connection()

    for record in event['Records']:
        try:
            # 1. Parse the message body
            body_str = record['body']
            print(f"Processing message: {body_str}")
            data = json.loads(body_str)

            # Ensure required data is present
            if 'robot_id' not in data or 'procedure_id' not in data:
                print("Skipping record, missing 'robot_id' or 'procedure_id'.")
                continue

            robot_id = data.get('robot_id')
            procedure_id = data.get('procedure_id')
            status = data.get('status', 'unknown')
            timestamp = data.get('timestamp', datetime.now().isoformat())
            
            # --- Path 2: Write to S3 Data Lake ---
            # Use the timestamp to create a unique file name
            now = datetime.now()
            s3_key = f"raw_logs/year={now.year}/month={now.month:02d}/day={now.day:02d}/{timestamp}_{robot_id}.json"
            
            print(f"Writing full log to S3: s3://{S3_BUCKET}/{s3_key}")
            s3_client.put_object(
                Bucket=S3_BUCKET,
                Key=s3_key,
                Body=body_str,
                ContentType='application/json'
            )

            # --- Path 1: Write to RDS Database ---
            print(f"Writing status to RDS: {robot_id}, {status}")
            
            with conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO robot_status (robot_id, procedure_id, status, recorded_at)
                    VALUES (%s, %s, %s, %s)
                    """,
                    (robot_id, procedure_id, status, timestamp)
                )
            conn.commit() # Commit the transaction

            print(f"Successfully processed message for robot {robot_id}.")

        except json.JSONDecodeError:
            print(f"ERROR: Failed to decode JSON from SQS message: {record['body']}")
        except Exception as e:
            print(f"ERROR: Failed to process record: {e}")
            conn.rollback() # Rollback DB transaction on failure

    return {
        'statusCode': 200,
        'body': json.dumps('Processing complete.')
    }
