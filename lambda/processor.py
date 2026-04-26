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

        logger.info("Processing action=%s job_id=%s", action, job_id)

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

        try:
            iid = launch_runner(job_id, job_name)
            logger.info("Launched %s for job %s", iid, job_id)
        except Exception:
            decrement_count()
            logger.exception("Failed to launch runner for job %s, decremented counter", job_id)
            raise
