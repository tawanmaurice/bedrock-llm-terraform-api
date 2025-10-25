import json
import os
import boto3

bedrock = boto3.client("bedrock-runtime", region_name=os.getenv("AWS_REGION"))
MODEL_ID = os.getenv("BEDROCK_MODEL_ID")

# API Gateway HTTP API (v2) Lambda proxy format
# Event body: {"prompt": "...", "max_tokens": 256, "temperature": 0.2}

def lambda_handler(event, context):
    try:
        if event.get("isBase64Encoded"):
            body = json.loads(base64.b64decode(event.get("body", "") or "{}"))
        else:
            body = json.loads(event.get("body", "") or "{}")

        prompt = body.get("prompt") or "Say hello in one sentence."
        max_tokens = int(body.get("max_tokens", 256))
        temperature = float(body.get("temperature", 0.2))

        # Anthropics Messages API format on Bedrock
        request = {
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": max_tokens,
            "temperature": temperature,
            "messages": [
                {"role": "user", "content": [{"type": "text", "text": prompt}]}
            ]
        }

        resp = bedrock.invoke_model(
            modelId=MODEL_ID,
            body=json.dumps(request)
        )

        payload = json.loads(resp["body"].read())
        # Extract text from first content block if present
        text = ""
        for block in payload.get("content", []):
            if block.get("type") == "text":
                text += block.get("text", "")

        result = {
            "model": MODEL_ID,
            "prompt": prompt,
            "completion": text,
            "usage": payload.get("usage", {}),
        }

        return {
            "statusCode": 200,
            "headers": {"content-type": "application/json"},
            "body": json.dumps(result)
        }

    except Exception as e:
        return {
            "statusCode": 500,
            "headers": {"content-type": "application/json"},
            "body": json.dumps({
                "error": str(e),
                "hint": "Ensure the model is enabled in this region and your IAM role allows bedrock:InvokeModel."
            })
        }
