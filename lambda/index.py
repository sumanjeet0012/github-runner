import hashlib
import hmac
import json
import logging
import os

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# AWS_REGION is injected automatically by the Lambda runtime
ec2 = boto3.client("ec2")

WINDOWS_SKIP   = {"windows"}
LINUX_REQUIRED = {"self-hosted", "linux"}


def should_handle(labels):
    s = {l.lower() for l in labels}
    return not (s & WINDOWS_SKIP) and bool(s & LINUX_REQUIRED)


def verify_signature(body, header):
    secret = os.environ.get("WEBHOOK_SECRET", "")
    if not secret:
        logger.warning("WEBHOOK_SECRET not set - skipping verification")
        return True
    if not header or not header.startswith("sha256="):
        return False
    expected = "sha256=" + hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, header)


def launch_runner(job_id, job_name):
    lt_id      = os.environ["LAUNCH_TEMPLATE_ID"]
    lt_version = os.environ.get("LAUNCH_TEMPLATE_VERSION", "$Latest")
    inst_type  = os.environ.get("INSTANCE_TYPE", "")
    prefix     = os.environ.get("RUNNER_NAME_PREFIX", "ec2-runner")
    name       = "{}-{}".format(prefix, job_id)

    kwargs = dict(
        MinCount=1,
        MaxCount=1,
        LaunchTemplate={"LaunchTemplateId": lt_id, "Version": lt_version},
        TagSpecifications=[{
            "ResourceType": "instance",
            "Tags": [
                {"Key": "Name",          "Value": name},
                {"Key": "Role",          "Value": "github-runner"},
                {"Key": "GitHubJobId",   "Value": str(job_id)},
                {"Key": "GitHubJobName", "Value": job_name[:255]},
                {"Key": "ManagedBy",     "Value": "Terraform"},
                {"Key": "RunnerName",    "Value": name},
            ],
        }],
    )

    if inst_type:
        kwargs["InstanceType"] = inst_type

    r   = ec2.run_instances(**kwargs)
    iid = r["Instances"][0]["InstanceId"]
    logger.info("Launched %s for job %s (%s)", iid, job_id, job_name)
    return iid


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
        try:
            iid = launch_runner(job_id, job_name)
        except Exception as exc:
            logger.exception("Failed to launch runner for job %s", job_id)
            return {"statusCode": 500, "body": json.dumps({"error": str(exc)})}
        return {"statusCode": 200, "body": json.dumps({"launched": iid})}

    return {"statusCode": 200, "body": json.dumps({"status": "ok"})}
