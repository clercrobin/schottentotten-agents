#!/bin/bash
# ============================================================
# Environment: prod — schottentotten
# ============================================================
export ENV_NAME="prod"
export DEPLOY_BRANCH="main"
export DEPLOY_URL="https://schottentotten.com"
export TF_DIR="infra/terraform/app"
export TF_STATE_KEY="schottentotten/app.tfstate"
export TF_VARS_FILE="local.tfvars"
export IAM_ROLE_ARN="arn:aws:iam::635703137081:role/schottentotten-gha-deploy"
export S3_BUCKET="schottentotten.raceroadmap.com"
export CLOUDFRONT_ID="E21XOEDIDTRQFP"
