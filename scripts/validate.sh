#!/bin/bash
# Validate the CloudFormation template syntax before attempting a deploy.
# Catches malformed YAML / bad intrinsic functions early so deploys don't fail.
#
# Usage: ./scripts/validate.sh
set -euo pipefail

echo "==> Validating cloudformation/main.yaml"
aws cloudformation validate-template \
    --template-body file://cloudformation/main.yaml

echo "==> Validating cloudformation/jenkins-agent.yaml"
aws cloudformation validate-template \
    --template-body file://cloudformation/jenkins-agent.yaml

echo "==> Templates are valid."
