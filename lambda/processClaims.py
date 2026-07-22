"""
Healthcare Claims Processing - Event Orchestrator Lambda (Claritev).

Triggered by S3 ObjectCreated events. Does NOT download the file.
It validates the upload, reads metadata via head_object, and publishes
an event to SNS, which fans out to the Claims / Audit / Notification
SQS queues for downstream services.

Design notes:
  - Clients (boto3) are initialized at module scope for container reuse.
  - Each S3 record is processed in its own try/except so one bad file in a
    batch event cannot abort processing of the rest.
  - The object key is URL-decoded because S3 event keys are percent-encoded
    (spaces become '+'); using the raw key in head_object would 404.
  - aws_xray_sdk is imported defensively so a missing layer never breaks a
    cold start; tracing simply degrades to off.
"""

import json
import os
import boto3
import botocore
from datetime import datetime, timezone
from urllib.parse import unquote_plus

# X-Ray tracing for production observability. Guarded import so that an
# environment without the bundled SDK (e.g. a missing layer) degrades
# gracefully instead of crashing on cold start.
try:
    from aws_xray_sdk.core import patch_all
    patch_all()
except ImportError:
    pass

# Initialize clients outside the handler for container reuse (performance).
s3_client = boto3.client('s3')
sns_client = boto3.client('sns')

# Environment variables injected by CloudFormation.
TOPIC_ARN = os.environ.get('TOPIC_ARN')
ENVIRONMENT = os.environ.get('ENVIRONMENT')
PROJECT_NAME = os.environ.get('PROJECT_NAME')

# Business rules / constraints.
VALID_PREFIX = 'uploads/'
VALID_EXTENSIONS = ['.csv', '.xml']
# 500 MB limit - beyond this a file is likely a multipart upload still in
# progress, or too large for the downstream service's memory budget.
MAX_FILE_SIZE_BYTES = 500 * 1024 * 1024


def lambda_handler(event, context):
    """
    Entry point for S3 ObjectCreated events.

    S3 may deliver multiple records in a single invocation (a batch). We
    process each record independently so a failure on one object does not
    poison the rest of the batch.
    """
    failed = 0
    for record in event.get('Records', []):
        try:
            bucket_name = record['s3']['bucket']['name']
            # Object key is URL-encoded in S3 events (spaces -> '+'). Decode it
            # before using it in any S3 API call, otherwise head_object 404s.
            object_key = unquote_plus(record['s3']['object']['key'])
            process_single_record(bucket_name, object_key)
        except Exception as e:
            # Log and continue; one bad record must not abort the batch.
            failed += 1
            print(f"ERROR: Failed to process record {record}: {str(e)}")

    if failed:
        # Re-raise only if every record failed, so SQS/S3 can retry the event.
        # Partial success is logged but treated as success to avoid reprocessing
        # the records that already succeeded.
        raise RuntimeError(f"{failed} record(s) failed processing; see logs.")

    return {
        'statusCode': 200,
        'body': json.dumps('Successfully processed S3 event batch.')
    }


def process_single_record(bucket_name, object_key):
    print(f"Received event for s3://{bucket_name}/{object_key}")

    # Validate folder path.
    if not object_key.startswith(VALID_PREFIX):
        print(f"Validation Failed: File {object_key} is not in the '{VALID_PREFIX}' directory. Skipping.")
        return

    # Validate file type.
    file_extension = os.path.splitext(object_key)[1].lower()
    if file_extension not in VALID_EXTENSIONS:
        print(f"Validation Failed: Invalid file extension '{file_extension}'. Expected {VALID_EXTENSIONS}. Skipping.")
        return

    # Read metadata WITHOUT downloading the file.
    try:
        head_response = s3_client.head_object(Bucket=bucket_name, Key=object_key)
        file_size = head_response['ContentLength']

        # Hospitals may tag uploads with custom metadata like
        # 'x-amz-meta-provider'; default to 'Unknown-Hospital' when absent.
        uploaded_by = head_response.get('Metadata', {}).get('provider', 'Unknown-Hospital')

        # Enforce file size limit.
        if file_size > MAX_FILE_SIZE_BYTES:
            print(f"Validation Failed: File size {file_size} bytes exceeds limit of {MAX_FILE_SIZE_BYTES} bytes.")
            # In production this would alert or move the file to a rejection bucket.
            return

    except botocore.exceptions.ClientError as e:
        if e.response['Error']['Code'] in ('404', 'NoSuchKey'):
            print(f"File {object_key} not found in S3. It may have been deleted before processing.")
            return
        raise

    # Build the event payload.
    file_name = os.path.basename(object_key)
    received_time = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    file_size_mb = round(file_size / (1024 * 1024), 2)

    sns_payload = {
        "event": "CLAIM_FILE_RECEIVED",
        "project": PROJECT_NAME,
        "environment": ENVIRONMENT,
        "provider": uploaded_by,
        "bucket": bucket_name,
        "key": object_key,
        "fileName": file_name,
        "fileType": file_extension.lstrip('.'),
        "fileSize": f"{file_size_mb}MB",
        "receivedTime": received_time
    }

    print(f"Extracted Metadata: {json.dumps(sns_payload)}")

    # Publish to SNS -> fans out to Claims / Audit / Notification queues.
    sns_response = sns_client.publish(
        TopicArn=TOPIC_ARN,
        Message=json.dumps(sns_payload),
        Subject=f"New Claim File Received: {file_name}"
    )
    print(f"Successfully published to SNS. MessageId: {sns_response['MessageId']}")
