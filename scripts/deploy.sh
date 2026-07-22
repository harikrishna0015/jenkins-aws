#!/bin/bash
# Deploy the healthcare claims stack to a given environment.
#
# Deploys through the CloudFormation Execution Role (least privilege) rather
# than the Jenkins user's identity, so Jenkins itself never holds broad
# resource-creation permissions. See docs/bootstrap-iam.md for role setup.
#
# Usage: ./scripts/deploy.sh <dev|qa|prod>
# Env:   LAMBDA_ARTIFACT_BUCKET (required) - passed as LambdaArtifactBucket
set -euo pipefail

ENV="${1:?Usage: ./deploy.sh <dev|qa|prod>}"
case "${ENV}" in
    dev|qa|prod) ;;
    *) echo "Invalid environment '${ENV}'. Use dev, qa, or prod."; exit 1 ;;
esac

LAMBDA_ARTIFACT_BUCKET="${LAMBDA_ARTIFACT_BUCKET:?LAMBDA_ARTIFACT_BUCKET is required.}"

STACK_NAME="claims-${ENV}"
PARAM_FILE="cloudformation/parameters/${ENV}.json"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
CFN_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/claims-cfn-execution-role"

# If the dedicated CFN execution role exists, deploy THROUGH it (least-privilege
# pattern - Jenkins itself never creates resources). If it doesn't (e.g. a
# learning setup running as an admin identity), fall back to the caller identity.
ROLE_FLAGS=""
if aws iam get-role --role-name claims-cfn-execution-role --query Role.Arn --output text >/dev/null 2>&1; then
    ROLE_FLAGS="--role-arn ${CFN_ROLE_ARN}"
    ROLE_DESC="${CFN_ROLE_ARN} (CFN execution role)"
else
    ROLE_DESC="caller identity (admin)"
fi

echo "==> Deploying stack: ${STACK_NAME}"
echo "    Region:  ${AWS_REGION:-(unset - ensure AWS_DEFAULT_REGION is exported)}"
echo "    Deploy as: ${ROLE_DESC}"
echo "    Artifact bucket: ${LAMBDA_ARTIFACT_BUCKET}"

aws cloudformation deploy \
    --stack-name "${STACK_NAME}" \
    --template-file cloudformation/main.yaml \
    --parameter-overrides \
        file://"${PARAM_FILE}" \
        LambdaArtifactBucket="${LAMBDA_ARTIFACT_BUCKET}" \
    --capabilities CAPABILITY_NAMED_IAM \
    ${ROLE_FLAGS} \
    --no-fail-on-empty-changeset

echo "==> Deployment of ${STACK_NAME} completed successfully."
