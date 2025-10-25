# Bedrock LLM Terraform API
Serverless LLM endpoint on AWS using Terraform:
API Gateway (HTTP) → Lambda (Python) → Amazon Bedrock.

## Quick Start
terraform init
terraform apply -auto-approve

Then test with the curl below (replace <api_invoke_url> with the output).
