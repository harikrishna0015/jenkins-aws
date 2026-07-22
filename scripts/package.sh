#!/bin/bash
# Package the Lambda function into a zip and upload it to the artifact bucket.
#
# The Lambda uses aws_xray_sdk, which is NOT in the Python 3.12 managed
# runtime, so we pip-install dependencies into a staging dir alongside the
# handler before zipping. This produces a self-contained artifact.
#
# Usage: ./scripts/package.sh
# Env:   ARTIFACT_BUCKET (required) - S3 bucket for the packaged zip
#        ARTIFACT_KEY    (optional) - defaults to processClaims.zip
set -euo pipefail

ARTIFACT_BUCKET="${ARTIFACT_BUCKET:?ARTIFACT_BUCKET is required (set via Jenkins env or export).}"
ARTIFACT_KEY="${ARTIFACT_KEY:-processClaims.zip}"
STAGE_DIR="lambda/package"
ZIP_FILE="processClaims.zip"

echo "==> Staging Lambda code into ${STAGE_DIR}"
rm -rf "${STAGE_DIR}"
mkdir -p "${STAGE_DIR}"
cp lambda/processClaims.py "${STAGE_DIR}/"

# Install runtime dependencies into the staging dir. Lambda Python 3.12 needs
# aws_xray_sdk to be bundled (or a layer). Bundling keeps deploys self-contained.
# Use pip3 (some images only alias pip3, not pip).
# - no -q: we WANT to see pip's output if it fails (set -e otherwise swallows it)
# - PIP_BREAK_SYSTEM_PACKAGES=1: bypasses PEP 668 "externally-managed-environment"
#   on modern Debian/Ubuntu base images; harmless on older pip/other distros.
echo "==> Installing dependencies (boto3, aws-xray-sdk) into staging dir"
PIP="$(command -v pip3 || command -v pip)"
PIP_BREAK_SYSTEM_PACKAGES=1 ${PIP} install --upgrade --target "${STAGE_DIR}" boto3 aws-xray-sdk

echo "==> Creating ${ZIP_FILE}"
# Zip from inside the staging dir so paths are flat (handler at zip root).
( cd "${STAGE_DIR}" && zip -r "../../${ZIP_FILE}" . )

echo "==> Uploading s3://${ARTIFACT_BUCKET}/${ARTIFACT_KEY}"
aws s3 cp "${ZIP_FILE}" "s3://${ARTIFACT_BUCKET}/${ARTIFACT_KEY}"

echo "==> Package complete."
