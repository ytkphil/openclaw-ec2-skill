#!/usr/bin/env node
/**
 * apply-patches.js <bridgeDir>
 *
 * Layers the ec2-ssm-exec changes onto a checkout of the OpenClaw base bridge/
 * directory: adds @aws-sdk/client-ssm to the Dockerfile npm install list, adds
 * a COPY for the skill, and adds SSM actions to the scoped-credentials session
 * policy. Idempotent — running twice is a no-op. Uses exact string anchors
 * (not regex) so `@` and comment lines can't trip it up.
 *
 * Exits non-zero if any anchor is missing (base layout changed) so the build
 * fails loudly instead of silently shipping an unpatched image.
 */
const fs = require("fs");
const path = require("path");

const bridge = process.argv[2];
if (!bridge) {
  console.error("Usage: node apply-patches.js <bridgeDir>");
  process.exit(1);
}

function patch(file, label, edits) {
  const p = path.join(bridge, file);
  let src = fs.readFileSync(p, "utf8");
  for (const { find, insert, after, already } of edits) {
    if (src.includes(already)) {
      console.log(`    [skip] ${label}: already patched`);
      continue;
    }
    if (!src.includes(find)) {
      console.error(`ERROR: ${label}: anchor not found:\n${find}`);
      process.exit(1);
    }
    src = after
      ? src.replace(find, find + insert)
      : src.replace(find, insert + find);
    console.log(`    [ok]   ${label}`);
  }
  fs.writeFileSync(p, src);
}

// 1. Dockerfile — add @aws-sdk/client-ssm after @aws-sdk/client-sts in the
//    npm install list.
patch("Dockerfile", "Dockerfile: npm @aws-sdk/client-ssm", [
  {
    find: "                @aws-sdk/client-sts \\\n",
    insert: "                @aws-sdk/client-ssm \\\n",
    after: true,
    already: "@aws-sdk/client-ssm",
  },
]);

// 2. Dockerfile — COPY the skill after the agentcore-browser skill copy.
patch("Dockerfile", "Dockerfile: COPY ec2-ssm-exec", [
  {
    find:
      "COPY skills/agentcore-browser /skills/agentcore-browser\nRUN chmod +x /skills/agentcore-browser/*.js\n",
    insert:
      "\n# EC2 SSM command-exec skill\nCOPY skills/ec2-ssm-exec /skills/ec2-ssm-exec\nRUN chmod +x /skills/ec2-ssm-exec/*.js\n",
    after: true,
    already: "skills/ec2-ssm-exec",
  },
]);

// 3. scoped-credentials.js — add SSM actions to the session policy. Anchor on
//    the exact CODE line (with leading spaces + trailing comma) so the
//    docstring mention of iam:PassRole is never matched.
patch("scoped-credentials.js", "scoped-credentials: SSM actions", [
  {
    find: '          "iam:PassRole",\n',
    insert:
      '          "ssm:SendCommand", "ssm:StartSession", "ssm:GetCommandInvocation", "ssm:DescribeInstanceInformation",\n',
    after: true,
    already: "ssm:SendCommand",
  },
]);

// 4. scoped-credentials.js — forward the EC2 target env vars to the OpenClaw
//    child process. buildOpenClawEnv only copies keys in FORWARDED_ENV_KEYS,
//    so the ec2-ssm-exec skill can't see EC2_TARGET_* unless we add them here.
//    Anchor on the last entry of the array.
patch("scoped-credentials.js", "scoped-credentials: forward EC2 env vars", [
  {
    find: '  "INTERNAL_USER_ID",\n',
    insert:
      '  // ec2-ssm-exec skill — target instance for SSM command execution\n  "EC2_TARGET_INSTANCE_ID",\n  "EC2_TARGET_REGION",\n  "EC2_RUN_AS_USER",\n',
    after: true,
    already: "EC2_TARGET_INSTANCE_ID",
  },
]);

// 5. agentcore-contract.js — make the agent always report tool/command results.
//    The model tends to run a tool and then go silent; add a global rule to the
//    AGENTS.md bootstrap instructions. Anchor on the "## Response Formatting"
//    section header line (array string element).
patch("agentcore-contract.js", "AGENTS.md: always report results", [
  {
    find: '        "## Response Formatting",\n',
    insert:
      '        "## Always Report Results",\n' +
      '        "",\n' +
      '        "After you run ANY tool or command, always tell the user what happened in your reply — even if it seems minor. Summarize the outcome (what ran, success or failure, and the key part of the output). Never run a command and then stay silent or end your turn without reporting back. If a command failed, say so and include the error.",\n' +
      '        "",\n',
    after: false,
    already: "## Always Report Results",
  },
]);

console.log("    All patches applied.");
