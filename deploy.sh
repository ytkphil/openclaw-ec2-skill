#!/usr/bin/env bash
#
# deploy.sh — layer the ec2-ssm-exec skill onto the OpenClaw base and deploy.
#
# Run this from your DESKTOP (the machine with the `seoul-golf` AWS profile and
# Docker). It clones the public base into a temp dir, overlays the skill +
# patches, builds the ARM64 image, pushes to ECR, updates the AgentCore runtime
# with the FULL env var set (existing + new EC2 vars), and stops the running
# session so the next message picks up the new image.
#
# The public base repo is only ever CLONED here — never committed to.
#
# Prereqs on the desktop:
#   - aws CLI + `seoul-golf` profile (account 529296392952, Admin)
#   - docker (with buildx / ARM64 support)
#   - git
#
# Usage:
#   bash deploy.sh
#
set -euo pipefail

# ─── Config (your OpenClaw values) ──────────────────────────────────────────
PROFILE="seoul-golf"
OC_REGION="ap-northeast-1"                       # OpenClaw runtime region
ACCOUNT="529296392952"
RUNTIME_ID="openclaw_agent-OVOYWtHFSU"
RUNTIME_ARN="arn:aws:bedrock-agentcore:${OC_REGION}:${ACCOUNT}:runtime/${RUNTIME_ID}"
ECR_REPO="${ACCOUNT}.dkr.ecr.${OC_REGION}.amazonaws.com/bedrock-agentcore-openclaw-bridge"
EXEC_ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/openclaw-agentcore-execution-role-${OC_REGION}"

# Network (from get-agent-runtime)
SG="sg-068f3fa92952d8f13"
SUBNET1="subnet-000901931ef2de1d3"
SUBNET2="subnet-0d42ea9edbfc7e114"

# Target EC2 (the Seoul golf box) — passed to the skill via container env vars
EC2_TARGET_INSTANCE_ID="i-086f2fe006d505ca2"
EC2_TARGET_REGION="ap-northeast-2"
EC2_RUN_AS_USER="ec2-user"

# Public base repo
BASE_REPO="https://github.com/aws-samples/sample-host-openclaw-on-amazon-bedrock-agentcore.git"

# This skill repo (where this script lives)
SKILL_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# New image tag — bump from current v4
NEW_TAG="${1:-v5}"

# ─── 0. Sanity checks ────────────────────────────────────────────────────────
echo "==> Checking prerequisites..."
command -v docker >/dev/null || { echo "ERROR: docker not found"; exit 1; }
command -v git >/dev/null || { echo "ERROR: git not found"; exit 1; }
aws sts get-caller-identity --profile "$PROFILE" >/dev/null || {
  echo "ERROR: AWS profile '$PROFILE' not working. Run: ada credentials update --profile $PROFILE --account $ACCOUNT --role Admin --provider isengard --once";
  exit 1;
}
echo "    OK. Deploying image tag: $NEW_TAG"

# ─── 1. Clone the public base into a temp dir (never modified in git) ────────
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT
echo "==> Cloning base into $BUILD_DIR ..."
git clone --depth 1 "$BASE_REPO" "$BUILD_DIR/base" -q
BRIDGE="$BUILD_DIR/base/bridge"

# ─── 2. Overlay the skill ────────────────────────────────────────────────────
echo "==> Overlaying ec2-ssm-exec skill..."
cp -r "$SKILL_REPO_DIR/skills/ec2-ssm-exec" "$BRIDGE/skills/ec2-ssm-exec"

# ─── 3+4. Patch Dockerfile + scoped-credentials.js via the Node patcher ─────
# (exact-string, idempotent, fails loudly if base layout changed)
echo "==> Applying patches (Dockerfile + scoped-credentials.js)..."
node "$SKILL_REPO_DIR/apply-patches.js" "$BRIDGE"

# ─── 5. Build ARM64 image ────────────────────────────────────────────────────
echo "==> Building ARM64 image (this can take several minutes)..."
docker build --platform linux/arm64 -t "openclaw-bridge:${NEW_TAG}" "$BRIDGE"

# ─── 6. Push to ECR ──────────────────────────────────────────────────────────
echo "==> Pushing to ECR..."
aws ecr get-login-password --region "$OC_REGION" --profile "$PROFILE" \
  | docker login --username AWS --password-stdin "${ACCOUNT}.dkr.ecr.${OC_REGION}.amazonaws.com"
docker tag "openclaw-bridge:${NEW_TAG}" "${ECR_REPO}:${NEW_TAG}"
docker push "${ECR_REPO}:${NEW_TAG}"

# ─── 7. Update the AgentCore runtime (FULL REPLACE of env vars) ──────────────
echo "==> Updating AgentCore runtime to ${NEW_TAG}..."
aws bedrock-agentcore-control update-agent-runtime \
  --region "$OC_REGION" --profile "$PROFILE" \
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
  }"

# ─── 8. Wait for runtime update, then stop sessions ──────────────────────────
echo "==> Waiting for runtime to become READY..."
for i in $(seq 1 30); do
  STATUS=$(aws bedrock-agentcore-control get-agent-runtime --region "$OC_REGION" --profile "$PROFILE" \
    --agent-runtime-id "$RUNTIME_ID" --query status --output text)
  echo "    status: $STATUS"
  [ "$STATUS" = "READY" ] && break
  sleep 10
done

echo ""
echo "==> Done. New image ${NEW_TAG} deployed."
echo ""
echo "Next message from the bot will spin up a NEW session on the new image"
echo "(per-user idle termination). If you want to force it immediately, stop"
echo "the active session:"
echo ""
echo "  # find session id from DynamoDB, then:"
echo "  aws bedrock-agentcore stop-runtime-session \\"
echo "    --agent-runtime-arn \"$RUNTIME_ARN\" \\"
echo "    --runtime-session-id \"<sessionId>\" --region $OC_REGION --profile $PROFILE"
echo ""
echo "Then in Telegram, ask the bot:  \"내 골프 크론잡 보여줘\""
