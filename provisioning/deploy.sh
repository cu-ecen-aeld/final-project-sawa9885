#!/bin/bash
# Deploy the gateway provisioning function (issue #10) to the AWS account and region that the
# AWS CLI is signed in to. Run it from Git Bash on Windows or from any Linux shell.
#
#   provisioning/deploy.sh [stack-name]        default stack name: aesd-gateway-provisioning
#
# Step 1 creates or updates one CloudFormation stack from template.yaml: the function, its IAM
#        role, the allow-list table, the log group and the function's public address.
# Step 2 uploads provisioning/src as the function's code. The template holds only a
#        placeholder, so that no S3 bucket is needed.
#
# It touches nothing outside that stack. To remove everything again:
#   aws cloudformation delete-stack --stack-name aesd-gateway-provisioning
# (gateways and certificates that the function registered stay; see the README, "Revoke").
#
# The function's address is not printed here. flash-gateway.ps1 reads it from the stack, and
# this shows it:
#   aws cloudformation describe-stacks --stack-name aesd-gateway-provisioning \
#       --query "Stacks[0].Outputs[?OutputKey=='ProvisionUrl'].OutputValue" --output text
#
# Needs: the AWS CLI v2, signed in ("aws login"), and python3 or python (to make the zip file).
# The README lists the IAM permissions that the signed-in user needs.
#
# Exit status: 0 deployed, 1 a step failed (its error is printed), 2 a tool is missing.
#
# This file was partially generated using Claude Code using the chat session at:
# Link to chat session (issue #10): ISSUE10_SESSION_LINK

set -eu
cd "$(dirname "$0")"

STACK=${1:-aesd-gateway-provisioning}

PYTHON=$(command -v python3 || command -v python || true)
if [ -z "$PYTHON" ] || ! command -v aws >/dev/null; then
	echo "deploy: the AWS CLI and python are needed" >&2
	exit 2
fi

echo "deploy: host tests"
"$PYTHON" -m unittest discover -s test

echo "deploy: stack $STACK"
aws cloudformation deploy \
	--stack-name "$STACK" \
	--template-file template.yaml \
	--capabilities CAPABILITY_IAM \
	--no-fail-on-empty-changeset

# The function has the stack's name (template.yaml, FunctionName).
echo "deploy: function code"
mkdir -p build
rm -f build/function.zip
(cd src && "$PYTHON" -m zipfile -c ../build/function.zip ./*.py)
sha=$(aws lambda update-function-code \
	--function-name "$STACK" \
	--zip-file fileb://build/function.zip \
	--query CodeSha256 --output text)
aws lambda wait function-updated-v2 --function-name "$STACK"
echo "deploy: done, code SHA-256 (base64) $sha"
