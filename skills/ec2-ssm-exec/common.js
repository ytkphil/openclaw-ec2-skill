/**
 * Shared utilities for ec2-ssm-exec skill.
 *
 * Runs shell commands on a target EC2 instance via AWS SSM SendCommand.
 * The target instance and region are read from environment variables set at
 * container deploy time, NOT from agent input — so even under prompt injection
 * the agent cannot pivot to another host.
 *
 * Required env vars (set on the OpenClaw runtime):
 *   EC2_TARGET_INSTANCE_ID   e.g. i-086f2fe006d505ca2
 *   EC2_TARGET_REGION        e.g. ap-northeast-2
 * Optional:
 *   EC2_RUN_AS_USER          OS user to run commands as (default: ec2-user)
 */
const { SSMClient } = require("@aws-sdk/client-ssm");

const TARGET_INSTANCE_ID = process.env.EC2_TARGET_INSTANCE_ID;
const TARGET_REGION = process.env.EC2_TARGET_REGION;
const RUN_AS_USER = process.env.EC2_RUN_AS_USER || "ec2-user";

function validateEnv() {
  if (!TARGET_INSTANCE_ID) {
    console.error("Error: EC2_TARGET_INSTANCE_ID environment variable is not set.");
    process.exit(1);
  }
  if (!TARGET_REGION) {
    console.error("Error: EC2_TARGET_REGION environment variable is not set.");
    process.exit(1);
  }
}

function getClient() {
  return new SSMClient({ region: TARGET_REGION });
}

module.exports = {
  SSMClient,
  getClient,
  validateEnv,
  TARGET_INSTANCE_ID,
  TARGET_REGION,
  RUN_AS_USER,
};
