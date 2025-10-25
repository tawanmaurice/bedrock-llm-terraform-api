# ==========================================
# Terraform: Serverless LLM Endpoint on AWS
# Stack: API Gateway HTTP API -> Lambda (Python) -> Amazon Bedrock
# One-file project. Save as main.tf and apply.
# ==========================================

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.50.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4.0"
    }
  }
}

# ----------------------
# Variables (override via -var or terraform.tfvars)
# ----------------------
variable "project_name" {
  description = "Project name prefix"
  type        = string
  default     = "bedrock-llm-demo"
}

variable "aws_region" {
  description = "AWS region that supports your chosen Bedrock model (e.g., us-east-1, us-west-2)"
  type        = string
  default     = "us-east-1"
}

# Popular, low-cost model for demos; change if needed.
# Tip: ensure the model is available in your region and enabled in your account.
variable "bedrock_model_id" {
  description = "Bedrock model ID to invoke"
  type        = string
  default     = "anthropic.claude-3-haiku-20240307-v1:0"
}

provider "aws" {
  region = var.aws_region
}

# ----------------------
# IAM for Lambda
# ----------------------
resource "aws_iam_role" "lambda_role" {
  name               = "${var.project_name}-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action   = "sts:AssumeRole"
    }]
  })
}

# Basic logging
resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Allow invoking Bedrock models
resource "aws_iam_policy" "bedrock_invoke_policy" {
  name        = "${var.project_name}-bedrock-invoke"
  description = "Allow Lambda to invoke Bedrock models"
  policy      = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow",
        Action   = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ],
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "attach_bedrock_invoke" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.bedrock_invoke_policy.arn
}

# ----------------------
# Lambda source (Python 3.12)
# ----------------------
# We generate the handler file locally, zip it, and deploy.
resource "local_file" "lambda_handler_py" {
  filename = "lambda_src/handler.py"
  content  = <<PY
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
PY
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "lambda_src"
  output_path = "lambda.zip"
  depends_on  = [local_file.lambda_handler_py]
}

resource "aws_lambda_function" "llm" {
  function_name = "${var.project_name}-handler"
  role          = aws_iam_role.lambda_role.arn
  handler       = "handler.lambda_handler"
  runtime       = "python3.12"

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  timeout     = 30
  memory_size = 512

  environment {
    variables = {
      BEDROCK_MODEL_ID = var.bedrock_model_id
    }
  }
}

resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${aws_lambda_function.llm.function_name}"
  retention_in_days = 14
}

# ----------------------
# API Gateway HTTP API (v2)
# ----------------------
resource "aws_apigatewayv2_api" "http_api" {
  name          = "${var.project_name}-api"
  protocol_type = "HTTP"
  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["POST", "OPTIONS"]
    allow_headers = ["content-type"]
  }
}

resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id                 = aws_apigatewayv2_api.http_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.llm.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "invoke_route" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "POST /invoke"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http_api.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "apigw_invoke" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.llm.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}

# ----------------------
# Outputs
# ----------------------
output "api_invoke_url" {
  description = "HTTP POST endpoint to invoke the LLM"
  value       = aws_apigatewayv2_api.http_api.api_endpoint
}

output "invoke_example" {
  description = "cURL to test the endpoint"
  value       = "curl -s -X POST ${aws_apigatewayv2_api.http_api.api_endpoint}/invoke -H 'content-type: application/json' -d '{\"prompt\": \"Write a 1-sentence pep talk for passing AWS SAA.\", \"max_tokens\": 128, \"temperature\": 0.2}' | jq ."
}

# ----------------------
# README (notes)
# ----------------------
# 1) Prereqs: AWS CLI configured, Terraform >= 1.6, and permissions to create IAM/Lambda/API GW.
# 2) Save this file as main.tf in an empty folder. Then run:
#    terraform init
#    terraform apply -auto-approve
# 3) Copy output api_invoke_url and test with the invoke_example cURL.
# 4) To change the model, set -var="bedrock_model_id=..." and re-apply.
#    Examples:
#      anthropic.claude-3-haiku-20240307-v1:0
#      anthropic.claude-3-sonnet-20240229-v1:0
#      meta.llama3-8b-instruct-v1:0
#      cohere.command-r-v1:0
#    (Availability varies by region/account; enable models in Bedrock console if needed.)
# 5) Cleanup to avoid charges: terraform destroy -auto-approve
#    (API GW + Lambda are low-cost in free tier for light testing.)
