import boto3
import json
import time
import os
import requests

REGION = os.environ.get("AWS_REGION", "ap-northeast-2")
QUEUE_URL = os.environ["QUEUE_URL"]
LOKI_URL = os.environ.get("LOKI_URL", "http://loki:3100/loki/api/v1/push")

sqs = boto3.client("sqs", region_name=REGION)

def push_to_loki(log_group, log_stream, timestamp_ms, message):
    payload = {
        "streams": [
            {
                "stream": {
                    "job": "cw-nginx",
                    "log_group": log_group,
                    "log_stream": log_stream,
                },
                "values": [
                    [str(int(timestamp_ms) * 1_000_000), message]
                ]
            }
        ]
    }
    resp = requests.post(LOKI_URL, json=payload, timeout=5)
    if resp.status_code not in (200, 204):
        print(f"Loki push failed: {resp.status_code} {resp.text}")

def main():
    print("SQS worker started, polling", QUEUE_URL, flush=True)
    while True:
        resp = sqs.receive_message(
            QueueUrl=QUEUE_URL,
            MaxNumberOfMessages=10,
            WaitTimeSeconds=10,
        )
        messages = resp.get("Messages", [])
        for msg in messages:
            try:
                body = json.loads(msg["Body"])
                push_to_loki(
                    body.get("logGroup", "unknown"),
                    body.get("logStream", "unknown"),
                    body.get("timestamp", int(time.time() * 1000)),
                    body.get("message", "")
                )
                sqs.delete_message(QueueUrl=QUEUE_URL, ReceiptHandle=msg["ReceiptHandle"])
                print("pushed 1 message to loki", flush=True)
            except Exception as e:
                print("Error processing message:", e, flush=True)

if __name__ == "__main__":
    main()