#!/usr/bin/env bash
#
# deploy.sh — add the ec2-ssm-exec skill to OpenClaw and deploy via CodeBuild.
#
# No Docker / agentcore CLI needed. Uses the existing CodeBuild project
# (openclaw-bridge-build) which builds ARM64 in the cloud and pushes to ECR.
#
# Flow:
#   1. download the current build source zip from S3 (your latest bridge/)
#   2. overlay the ec2-ssm-exec skill + patch Dockerfile & scoped-credentials.js
#   3. re-zip and upload back to S3
#   4. start CodeBuild with TAG override (default v5)
#   5. wait for build to succeed
#   6. update-agent-runtime with the new image + EC2 env vars (FULL env set)
#
# The public base repo is never touched — we build on top of YOUR current
# source-of-truth zip in S3.
#
# Run from the DESKTOP (needs the `seoul-golf` AWS profile). Requires: aws, zip,
# unzip, node. No Docker.
#
# Usage:
#   bash deploy.sh            # builds tag v5
#   bash deploy.sh v6         # builds a specific tag
#
set -euo pipefail

# ─── Config ──────────────────────────────────────────────────────────────────
PROFILE="seoul-golf"
OC_REGION="ap-northeast-1"
ACCOUNT="529296392952"
RUNTIME_ID="openclaw_agent-OVOYWtHFSU"
RUNTIME_ARN="arn:aws:bedrock-agentcore:${OC_REGION}:${ACCOUNT}:runtime/${RUNTIME_ID}"
ECR_REPO="${ACCOUNT}.dkr.ecr.${OC_REGION}.amazonaws.com/bedrock-agentcore-openclaw-bridge"
EXEC_ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/openclaw-agentcore-execution-role-${OC_REGION}"
CODEBUILD_PROJECT="openclaw-bridge-build"
SRC_BUCKET="openclaw-codebuild-src-${ACCOUNT}-${OC_REGION}"
SRC_KEY="bridge-src.zip"

# Network (from get-agent-runtime)
SG="sg-068f3fa92952d8f13"
SUBNET1="subnet-000901931ef2de1d3"
SUBNET2="subnet-0d42ea9edbfc7e114"

# Target EC2 (Seoul golf box) — passed to the skill via container env vars
EC2_TARGET_INSTANCE_ID="i-086f2fe006d505ca2"
EC2_TARGET_REGION="ap-northeast-2"
EC2_RUN_AS_USER="ec2-user"

SKILL_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEW_TAG="${1:-v5}"
AWS="aws --profile $PROFILE --region $OC_REGION"

# ─── 0. Prereqs ──────────────────────────────────────────────────────────────
echo "==> Checking prerequisites..."
for c in aws zip unzip node; do command -v "$c" >/dev/null || { echo "ERROR: $c not found"; exit 1; }; done
$AWS sts get-caller-identity >/dev/null || { echo "ERROR: profile $PROFILE not working (run ada credentials update ...)"; exit 1; }
echo "    OK. Target image tag: $NEW_TAG"

# ─── 1. Download current build source from S3 ───────────────────────────────
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
echo "==> Downloading current build source (s3://$SRC_BUCKET/$SRC_KEY)..."
$AWS s3 cp "s3://$SRC_BUCKET/$SRC_KEY" "$WORK/src.zip" >/dev/null
mkdir -p "$WORK/src"
( cd "$WORK/src" && unzip -oq ../src.zip )

# sanity: this zip's root IS the bridge dir
test -f "$WORK/src/Dockerfile" || { echo "ERROR: Dockerfile not at zip root — layout changed"; exit 1; }
test -f "$WORK/src/buildspec.yml" || { echo "ERROR: buildspec.yml missing from source zip"; exit 1; }
test -f "$WORK/src/scoped-credentials.js" || { echo "ERROR: scoped-credentials.js missing from source zip"; exit 1; }

# ─── 2. Overlay skill + apply patches ────────────────────────────────────────
echo "==> Overlaying ec2-ssm-exec skill..."
rm -rf "$WORK/src/skills/ec2-ssm-exec"
cp -r "$SKILL_REPO_DIR/skills/ec2-ssm-exec" "$WORK/src/skills/ec2-ssm-exec"

echo "==> Applying patches (Dockerfile + scoped-credentials.js)..."
node "$SKILL_REPO_DIR/apply-patches.js" "$WORK/src"

# ─── 3. Re-zip and upload back to S3 ─────────────────────────────────────────
echo "==> Re-zipping and uploading to S3..."
( cd "$WORK/src" && zip -rq ../new-src.zip . )
$AWS s3 cp "$WORK/new-src.zip" "s3://$SRC_BUCKET/$SRC_KEY" >/dev/null
echo "    Uploaded updated bridge-src.zip"

# ─── 4. Start CodeBuild (ARM64, cloud) with TAG override ─────────────────────
echo "==> Starting CodeBuild ($CODEBUILD_PROJECT, TAG=$NEW_TAG)..."
BUILD_ID=$($AWS codebuild start-build \
  --project-name "$CODEBUILD_PROJECT" \
  --environment-variables-override "name=TAG,value=${NEW_TAG},type=PLAINTEXT" \
  --query "build.id" --output text)
echo "    Build: $BUILD_ID"

# ─── 5. Wait for build ───────────────────────────────────────────────────────
echo "==> Waiting for build to finish (this can take several minutes)..."
while true; do
  PHASE=$($AWS codebuild batch-get-builds --ids "$BUILD_ID" --query "builds[0].currentPhase" --output text)
  STATUS=$($AWS codebuild batch-get-builds --ids "$BUILD_ID" --query "builds[0].buildStatus" --output text)
  echo "    phase=$PHASE status=$STATUS"
  [ "$STATUS" = "SUCCEEDED" ] && break
  if [ "$STATUS" != "IN_PROGRESS" ]; then
    echo "ERROR: build ended with status $STATUS. Logs:"
    echo "  aws codebuild batch-get-builds --ids $BUILD_ID --profile $PROFILE --region $OC_REGION --query 'builds[0].logs.deepLink' --output text"
    exit 1
  fi
  sleep 15
done
echo "    Build SUCCEEDED."

# ─── 6. Update the AgentCore runtime (FULL REPLACE of env vars) ──────────────
echo "==> Updating AgentCore runtime to ${NEW_TAG}..."
$AWS bedrock-agentcore-control update-agent-runtime \
  --agent-runtime-id "$RUNTIME_ID" \
  --role-arn "$EXEC_ROLE_ARN" \
  --agent-runtime-artifact "{\"containerConfiguration\":{\"containerUri\":\"${ECR_REPO}:${NEW_TAG}\"}}" \
  --network-configuration "{\"networkMode\":\"VPC\",\"networkModeConfig\":{\"securityGroups\":[\"${SG}\"],\"subnets\":[\"${SUBNET1}\",\"${SUBNET2}\"]}}" \
  --environment-variables "{
    \"AWS_REGION\":\"ap-northeast-1\",
    \"BEDROCK_AGENTCORE_MEMORY_ID\":\"openclaw_agent_mem-B6FJF18Iw4\",
    \"BEDROCK_AGENTCORE_MEMORY_NAME\":\"openclaw_agent_mem\",
    \"BEDROCK_MODEL_ID\":\"jp.anthropic.claude-opus-4-8\",
    \"CMK_ARN\":\"arn:aws:kms:ap-northeast-1:${ACCOUNT}:key/fe48afe6-26a7-46ed-8fd0-d888658daf82\",
    \"COGNITO_CLIENT_ID\":\"5rnvqng5lbkf8le4jne08tgau9\",
    \"COGNITO_PASSWORD_SECRET_ID\":\"openclaw/cognito-password-secret\",
    \"COGNITO_USER_POOL_ID\":\"ap-northeast-1_i7B0eW9Kw\",
    \"CRON_LAMBDA_ARN\":\"arn:aws:lambda:ap-northeast-1:${ACCOUNT}:function:openclaw-cron-executor\",
    \"CRON_LEAD_TIME_MINUTES\":\"5\",
    \"ENABLE_FAST_MODE\":\"false\",
    \"EVENTBRIDGE_ROLE_ARN\":\"arn:aws:iam::${ACCOUNT}:role/openclaw-cron-scheduler-role-ap-northeast-1\",
    \"EVENTBRIDGE_SCHEDULE_GROUP\":\"openclaw-cron\",
    \"EXECUTION_ROLE_ARN\":\"${EXEC_ROLE_ARN}\",
    \"GATEWAY_TOKEN_SECRET_ID\":\"openclaw/gateway-token\",
    \"IDENTITY_TABLE_NAME\":\"openclaw-identity\",
    \"IMAGE_VERSION\":\"${NEW_TAG#v}\",
    \"S3_USER_FILES_BUCKET\":\"openclaw-user-files-${ACCOUNT}-ap-northeast-1\",
    \"SUBAGENT_BEDROCK_MODEL_ID\":\"\",
    \"TELEGRAM_CHANNEL_SECRET_ID\":\"openclaw/channels/telegram\",
    \"WORKSPACE_SYNC_INTERVAL_MS\":\"300000\",
    \"EC2_TARGET_INSTANCE_ID\":\"${EC2_TARGET_INSTANCE_ID}\",
    \"EC2_TARGET_REGION\":\"${EC2_TARGET_REGION}\",
    \"EC2_RUN_AS_USER\":\"${EC2_RUN_AS_USER}\"
  }" >/dev/null

echo "==> Waiting for runtime to become READY..."
for i in $(seq 1 30); do
  ST=$($AWS bedrock-agentcore-control get-agent-runtime --agent-runtime-id "$RUNTIME_ID" --query status --output text)
  echo "    status: $ST"
  [ "$ST" = "READY" ] && break
  sleep 10
done

echo ""
echo "==> Done. Image ${NEW_TAG} built and runtime updated."
echo ""
echo "The next message to the bot starts a NEW session on the new image."
echo "To force it now, stop the active session (find sessionId in DynamoDB):"
echo "  aws bedrock-agentcore stop-runtime-session --agent-runtime-arn \"$RUNTIME_ARN\" \\"
echo "    --runtime-session-id \"<sessionId>\" --region $OC_REGION --profile $PROFILE"
echo ""
echo "Then in Telegram:  \"내 골프 크론잡 보여줘\""
