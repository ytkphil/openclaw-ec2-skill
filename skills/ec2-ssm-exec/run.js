#!/usr/bin/env node
/**
 * Run a shell command on the target EC2 instance via SSM SendCommand,
 * then poll for the result and print stdout/stderr.
 *
 * Usage:
 *   node run.js "<shell command>"
 *   node run.js --timeout 600 "<shell command>"
 *
 * The command runs as EC2_RUN_AS_USER (default ec2-user) in a login shell on
 * the instance named by EC2_TARGET_INSTANCE_ID.
 */
const {
  SendCommandCommand,
  GetCommandInvocationCommand,
} = require("@aws-sdk/client-ssm");
const {
  getClient,
  validateEnv,
  TARGET_INSTANCE_ID,
  RUN_AS_USER,
} = require("./common");

function parseArgs(argv) {
  let timeout = 300; // seconds to wait for the command to finish
  const rest = [];
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--timeout") {
      timeout = parseInt(argv[++i], 10);
      if (Number.isNaN(timeout) || timeout <= 0) {
        console.error("Error: --timeout must be a positive integer (seconds).");
        process.exit(1);
      }
    } else {
      rest.push(argv[i]);
    }
  }
  const command = rest.join(" ").trim();
  if (!command) {
    console.error('Error: a shell command is required. Usage: node run.js "<command>"');
    process.exit(1);
  }
  return { command, timeout };
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function main() {
  validateEnv();
  const { command, timeout } = parseArgs(process.argv.slice(2));
  const client = getClient();

  // Wrap so the command runs as RUN_AS_USER in a login shell (loads ~/.bashrc,
  // PATH, python3.11, etc.). The agent's command string is passed through a
  // single-quoted bash -lc; we escape embedded single quotes safely.
  const escaped = command.replace(/'/g, "'\\''");
  const wrapped = `sudo -u ${RUN_AS_USER} bash -lc '${escaped}'`;

  let commandId;
  try {
    const send = await client.send(
      new SendCommandCommand({
        InstanceIds: [TARGET_INSTANCE_ID],
        DocumentName: "AWS-RunShellScript",
        Parameters: { commands: [wrapped] },
        TimeoutSeconds: Math.min(timeout, 2592000),
      }),
    );
    commandId = send.Command.CommandId;
  } catch (err) {
    console.error(`Error sending command: ${err.name}: ${err.message}`);
    process.exit(1);
  }

  // Poll for completion.
  const deadline = Date.now() + timeout * 1000;
  let invocation;
  // SSM needs a moment before the invocation is queryable.
  await sleep(2000);
  while (Date.now() < deadline) {
    try {
      invocation = await client.send(
        new GetCommandInvocationCommand({
          CommandId: commandId,
          InstanceId: TARGET_INSTANCE_ID,
        }),
      );
    } catch (err) {
      // InvocationDoesNotExist can occur briefly right after send; retry.
      if (err.name === "InvocationDoesNotExist") {
        await sleep(2000);
        continue;
      }
      console.error(`Error polling command: ${err.name}: ${err.message}`);
      process.exit(1);
    }

    const status = invocation.Status;
    if (["Success", "Failed", "Cancelled", "TimedOut"].includes(status)) {
      break;
    }
    await sleep(3000);
  }

  if (!invocation) {
    console.error("Error: command did not complete in time.");
    process.exit(1);
  }

  // Print a compact, agent-friendly result.
  console.log(`Status: ${invocation.Status}`);
  console.log(`ExitCode: ${invocation.ResponseCode}`);
  const out = (invocation.StandardOutputContent || "").trim();
  const err = (invocation.StandardErrorContent || "").trim();
  if (out) {
    console.log("---- STDOUT ----");
    console.log(out);
  }
  if (err) {
    console.log("---- STDERR ----");
    console.log(err);
  }
  if (!out && !err) {
    console.log("(no output)");
  }

  // SSM truncates output above 24KB; tell the agent when that happened so it
  // can re-run with output redirected to a file and fetched in pieces.
  if (invocation.StandardOutputContent && invocation.StandardOutputContent.length >= 24000) {
    console.log(
      "\n[note] stdout was truncated by SSM (24KB cap). Re-run writing output to a file and read it in chunks.",
    );
  }

  process.exit(invocation.Status === "Success" ? 0 : 1);
}

main();
