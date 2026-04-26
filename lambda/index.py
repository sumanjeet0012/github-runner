import hashlib
import hmac
import json
import logging
import os
import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

sqs = boto3.client("sqs")

REQUIRED = {"self-hosted"}
LINUX_LABELS = {"linux"}
WINDOWS_LABELS = {"windows"}


def get_runner_type(labels):
    """Determine runner type (linux, windows, or None) based on labels"""
    s = {l.lower() for l in labels}
    # Must have self-hosted label
    if not (s & REQUIRED):
        return None
    # Check for OS-specific label
    if s & WINDOWS_LABELS:
        return "windows"
    if s & LINUX_LABELS:
        return "linux"
    return None


def should_handle(labels):
    """Check if we should handle this job"""
    return get_runner_type(labels) is not None


def verify_signature(body, header):
    secret = os.environ.get("WEBHOOK_SECRET", "")
    if not secret:
        logger.warning("WEBHOOK_SECRET not set - skipping verification")
        return True
    if not header or not header.startswith("sha256="):
        return False
    expected = "sha256=" + hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, header)


def handler(event, context):
    body_str   = event.get("body") or ""
    body_bytes = body_str.encode()
    headers    = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    sig        = headers.get("x-hub-signature-256", "")

    if not verify_signature(body_bytes, sig):
        logger.warning("Signature verification failed")
        return {"statusCode": 401, "body": "Unauthorized"}

    gh_event = headers.get("x-github-event", "")
    if gh_event != "workflow_job":
        logger.info("Ignoring event: %s", gh_event)
        return {"statusCode": 200, "body": "ignored"}

    try:
        payload = json.loads(body_str)
    except json.JSONDecodeError:
        return {"statusCode": 400, "body": "Bad Request"}

    action     = payload.get("action", "")
    job        = payload.get("workflow_job", {})
    job_id     = job.get("id", 0)
    job_name   = job.get("name", "unknown")
    job_labels = job.get("labels", [])

    logger.info("workflow_job action=%s job_id=%s labels=%s", action, job_id, job_labels)

    if action == "queued":
        if not should_handle(job_labels):
            logger.info("Skipping job %s - labels %s not for this runner", job_id, job_labels)
            return {"statusCode": 200, "body": json.dumps({"status": "skipped"})}
        queue_url = os.environ["JOB_QUEUE_URL"]
        sqs.send_message(
            QueueUrl=queue_url,
            MessageBody=json.dumps({
                "action":   action,
                "job_id":   job_id,
                "job_name": job_name,
                "labels":   job_labels,
            }),
        )
        logger.info("Enqueued job %s to SQS", job_id)
        return {"statusCode": 200, "body": json.dumps({"status": "queued", "job_id": job_id})}

    if action == "completed":
        queue_url = os.environ["JOB_QUEUE_URL"]
        sqs.send_message(
            QueueUrl=queue_url,
            MessageBody=json.dumps({
                "action":   action,
                "job_id":   job_id,
                "job_name": job_name,
                "labels":   job_labels,
            }),
        )
        logger.info("Enqueued completed event for job %s", job_id)
        return {"statusCode": 200, "body": json.dumps({"status": "ok"})}

    return {"statusCode": 200, "body": json.dumps({"status": "ok"})}
