import json
import logging
import os
import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ec2      = boto3.client("ec2")
dynamodb = boto3.resource("dynamodb")


def get_table():
    return dynamodb.Table(os.environ["DYNAMODB_TABLE"])


def get_active_count():
    resp = get_table().get_item(Key={"pk": "pool"})
    return int(resp.get("Item", {}).get("active_count", 0))


def increment_count():
    resp = get_table().update_item(
        Key={"pk": "pool"},
        UpdateExpression="ADD active_count :inc",
        ExpressionAttributeValues={":inc": 1},
        ReturnValues="UPDATED_NEW",
    )
    return int(resp["Attributes"]["active_count"])


def decrement_count():
    try:
        resp = get_table().update_item(
            Key={"pk": "pool"},
            UpdateExpression="ADD active_count :dec",
            ConditionExpression="active_count > :zero",
            ExpressionAttributeValues={":dec": -1, ":zero": 0},
            ReturnValues="UPDATED_NEW",
        )
        return int(resp["Attributes"]["active_count"])
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            logger.warning("active_count already 0, skipping decrement")
            return 0
        raise


def get_runner_type(labels):
    """Determine runner type (linux or windows) based on labels"""
    s = {l.lower() for l in labels}
    if "windows" in s:
        return "windows"
    return "linux"  # default to linux


def launch_runner(job_id, job_name, runner_type):
    """Launch an EC2 instance for a GitHub Actions runner
    
    Args:
        job_id: GitHub workflow job ID
        job_name: GitHub workflow job name
        runner_type: 'linux' or 'windows'
    """
    if runner_type == "windows":
        lt_id = os.environ.get("LAUNCH_TEMPLATE_ID_WINDOWS", os.environ.get("LAUNCH_TEMPLATE_ID"))
    else:
        lt_id = os.environ["LAUNCH_TEMPLATE_ID"]
    
    lt_version = os.environ.get("LAUNCH_TEMPLATE_VERSION", "$Default")
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
                {"Key": "OS",            "Value": runner_type.capitalize()},
                {"Key": "GitHubJobId",   "Value": str(job_id)},
                {"Key": "GitHubJobName", "Value": job_name[:255]},
                {"Key": "ManagedBy",     "Value": "Terraform"},
                {"Key": "RunnerName",    "Value": name},
            ],
        }],
    )
    # Only override instance type for Linux runners (Windows uses launch template default)
    if inst_type and runner_type == "linux":
        kwargs["InstanceType"] = inst_type

    r   = ec2.run_instances(**kwargs)
    iid = r["Instances"][0]["InstanceId"]
    logger.info("Launched %s (%s) for job %s (%s)", iid, runner_type, job_id, job_name)
    return iid


def handler(event, context):
    max_pool = int(os.environ.get("MAX_POOL_SIZE", "5"))

    for record in event.get("Records", []):
        try:
            msg = json.loads(record["body"])
        except (json.JSONDecodeError, KeyError):
            logger.error("Bad SQS message: %s", record.get("body"))
            continue

        action   = msg.get("action", "")
        job_id   = msg.get("job_id", 0)
        job_name = msg.get("job_name", "unknown")
        labels   = msg.get("labels", [])

        logger.info("Processing action=%s job_id=%s labels=%s", action, job_id, labels)

        if action == "completed":
            new_count = decrement_count()
            logger.info("Job %s completed. Pool active_count now %s", job_id, new_count)
            continue

        if action != "queued":
            continue

        active = get_active_count()
        logger.info("Pool: active=%s max=%s", active, max_pool)

        if active >= max_pool:
            # Pool is full - raise so SQS makes this message invisible for
            # visibility_timeout (300s) then retries automatically.
            # This is NOT an error - it is the expected flow.
            logger.info(
                "Pool full (%s/%s). Job %s will be retried by SQS in ~5 min.",
                active, max_pool, job_id,
            )
            raise Exception("pool-full-retry")

        try:
            increment_count()
        except Exception:
            logger.exception("Failed to increment pool counter for job %s", job_id)
            raise

        # Determine runner type based on job labels
        runner_type = get_runner_type(labels)
        logger.info("Job %s requires %s runner", job_id, runner_type)

        try:
            iid = launch_runner(job_id, job_name, runner_type)
            logger.info("Launched %s for job %s", iid, job_id)
        except Exception:
            decrement_count()
            logger.exception("Failed to launch runner for job %s, decremented counter", job_id)
            raise
