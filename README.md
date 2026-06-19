# openclaw-ec2-skill

An OpenClaw skill that lets the agent run shell commands on a target EC2
instance via AWS SSM (no SSH key, no open port). Built to let OpenClaw drive
the golf-reservation automation on the Seoul EC2 box.

This repo is **separate from** the public OpenClaw base
(`aws-samples/sample-host-openclaw-on-amazon-bedrock-agentcore`) on purpose —
it holds only the custom skill and the instructions for layering it onto a
build of that base, so the public checkout is never modified.

## What's here

```
skills/ec2-ssm-exec/
  SKILL.md       # how the agent uses the skill
  run.js         # SSM SendCommand + poll + return output
  common.js      # SSM client + env-var config (target instance/region)
  package.json   # @aws-sdk/client-ssm
```

## Configuration (env vars on the OpenClaw runtime)

| Var | Required | Example |
|-----|----------|---------|
| `EC2_TARGET_INSTANCE_ID` | yes | `i-086f2fe006d505ca2` |
| `EC2_TARGET_REGION` | yes | `ap-northeast-2` |
| `EC2_RUN_AS_USER` | no (default `ec2-user`) | `ec2-user` |

The target host is read from these env vars, never from agent input — so the
agent cannot pivot to another instance even under prompt injection.

## Deploying (the easy way): `bash deploy.sh`

`deploy.sh` does the whole thing with no Docker and no agentcore CLI — it uses
the existing `openclaw-bridge-build` CodeBuild project (ARM64, cloud) that your
OpenClaw already builds with. Run it from the desktop with the `seoul-golf`
profile:

```bash
bash deploy.sh          # builds & deploys image tag v5
```

It: downloads your current `bridge-src.zip` from S3 → overlays this skill +
patches Dockerfile/scoped-credentials → re-zips & uploads → starts CodeBuild →
waits → `update-agent-runtime` with the full env set plus the EC2 target vars.
The public base repo is never touched; the build source-of-truth is your S3 zip.

After it finishes, the next message to the bot starts a fresh session on the new
image (or stop the active session to force it — the script prints how).

---

## Manual steps (reference)

These steps layer the skill onto a *build* of the public base without committing
to the base repo. `deploy.sh` automates all of this.

### 1. IAM — let the agent's execution role reach the instance via SSM

Attach a least-privilege inline policy to the OpenClaw AgentCore execution role
(`openclaw-agentcore-execution-role-<region>`), scoped to the one instance:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "AllowSSMSessionToTargetEC2", "Effect": "Allow",
      "Action": "ssm:StartSession",
      "Resource": [
        "arn:aws:ec2:<region>:<account>:instance/<instance-id>",
        "arn:aws:ssm:*::document/AWS-StartInteractiveCommand",
        "arn:aws:ssm:*::document/AWS-RunShellScript",
        "arn:aws:ssm:*::document/AWS-StartNonInteractiveCommand"
      ] },
    { "Sid": "AllowSSMSendCommandToTargetEC2", "Effect": "Allow",
      "Action": "ssm:SendCommand",
      "Resource": [
        "arn:aws:ec2:<region>:<account>:instance/<instance-id>",
        "arn:aws:ssm:*::document/AWS-RunShellScript"
      ] },
    { "Sid": "AllowSSMCommandStatus", "Effect": "Allow",
      "Action": ["ssm:GetCommandInvocation", "ssm:DescribeInstanceInformation"],
      "Resource": "*" }
  ]
}
```

### 2. Scoped session policy — allow SSM through OpenClaw's STS scoping

OpenClaw runs under a reduced STS session policy (`bridge/scoped-credentials.js`
in the base). The execution-role permission above is the ceiling, but the
session policy must also allow the SSM actions or the agent's scoped credentials
won't carry them. Add to the shared (non-S3) statement's `Action` list:

```
"ssm:SendCommand", "ssm:StartSession", "ssm:GetCommandInvocation", "ssm:DescribeInstanceInformation"
```

(Keep `Resource: "*"` — the execution role restricts the actual instance. The
session policy stays well under the 2048-byte packed limit.)

### 3. Build — bake the skill into the container image

In the base build:
- Add `@aws-sdk/client-ssm` to the `npm install` list in `bridge/Dockerfile`.
- Copy the skill into `/skills/`:
  ```dockerfile
  COPY skills/ec2-ssm-exec /skills/ec2-ssm-exec
  RUN chmod +x /skills/ec2-ssm-exec/*.js
  ```
  (copy this repo's `skills/ec2-ssm-exec` into the base `bridge/skills/` at build
  time — e.g. via a build script that clones the base, drops the skill in, then
  builds; the base repo itself stays untouched in git.)

### 4. Runtime env vars

Add `EC2_TARGET_INSTANCE_ID`, `EC2_TARGET_REGION` (and optionally
`EC2_RUN_AS_USER`) to the `--environment-variables` of `update-agent-runtime`.
Note: that call is a FULL REPLACE — include the full existing env var set plus
these new ones, or the others get wiped.

### 5. New session

Stop the user's current session so the next message starts a fresh container
with the new image + env vars.

## Security notes

- Arbitrary shell execution is intentional (option B): the agent can run any
  command **as ec2-user on this one instance**. It cannot reach other hosts.
- Under prompt injection the blast radius is "anything ec2-user can do on this
  box". Keep that in mind for what else lives on the instance.
