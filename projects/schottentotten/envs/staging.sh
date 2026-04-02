#!/bin/bash
# ============================================================
# Environment: staging — schottentotten
# ============================================================
export ENV_NAME="staging"
export DEPLOY_BRANCH="staging"
export DEPLOY_URL="http://schottentotten-staging.s3-website-eu-west-1.amazonaws.com"
export TF_DIR="infra/terraform/staging"
export TF_STATE_KEY="schottentotten/staging.tfstate"
export TF_VARS_FILE="local.tfvars"
export IAM_ROLE_ARN="arn:aws:iam::635703137081:role/schottentotten-staging-deploy"
export S3_BUCKET="schottentotten-staging"
