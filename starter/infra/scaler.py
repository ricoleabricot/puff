import json, os
import boto3

ecs = boto3.client("ecs")

def handler(event, context):
    cluster, service = os.environ["CLUSTER"], os.environ["SERVICE"]
    low, high = int(os.environ["MIN"]), int(os.environ["MAX"])
    now = ecs.describe_services(cluster=cluster, services=[service])["services"][0]["desiredCount"]
    if "Records" in event:                       # an alarm, through SNS
        state = json.loads(event["Records"][0]["Sns"]["Message"])["NewStateValue"]
        want = now + 1 if state == "ALARM" else now - 1
    else:                                        # a direct call or a schedule: {"desired": 4}
        want = int(event["desired"])
    want = max(low, min(high, want))
    ecs.update_service(cluster=cluster, service=service, desiredCount=want)
    print(f"{service}: {now} -> {want}")
    return {"from": now, "to": want}
