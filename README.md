# Bedrock LLM API + Web Console (Terraform)

This project deploys a simple **ChatGPT-style console** backed by **AWS Bedrock** using **Terraform**.  
It includes:

- 🚀 API Gateway + Lambda that calls **Claude 3 Haiku** on Bedrock  
- 🗂️ S3 bucket for file uploads (up to 5 GB per single upload)  
- 🌐 Web UI hosted via GitHub Pages (same-page prompt + file upload)  

---

## 🌐 Live Demo (GitHub Pages)

👉 [Bedrock LLM Console](https://tawanmaurice.github.io/bedrock-llm-terraform-api/)  

---

## 📦 Quick Start (Terraform)

```bash
# 1. Initialize providers
terraform init

# 2. Deploy (set region + optional API key)
terraform apply -auto-approve \
  -var="aws_region=us-east-1" \
  -var="api_key=MY_SECRET"

# 3. Get outputs
terraform output -raw api_invoke_url
terraform output -raw uploads_bucket
