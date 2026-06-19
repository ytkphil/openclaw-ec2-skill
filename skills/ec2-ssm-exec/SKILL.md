---
name: ec2-ssm-exec
description: Run shell commands on the user's EC2 instance (golf reservation automation server) via AWS SSM. Use when the user asks to run, check, start, stop, or inspect anything on their EC2 server — golf reservation scripts, cron jobs, logs, processes, or files. Commands run as ec2-user.
allowed-tools: Bash(node:*)
---

# EC2 SSM Command Executor

Run arbitrary shell commands on the user's EC2 instance through AWS SSM. No SSH
key or open port is needed — SSM handles the connection. Commands run as the
`ec2-user` OS account in a login shell.

The target instance and region are fixed by the container's environment
(`EC2_TARGET_INSTANCE_ID`, `EC2_TARGET_REGION`) — you cannot point this at any
other host.

This is the server where the user's golf reservation automation lives under
`~/golf/` (e.g. `yeojucc_reserve.py`, `hansung_reserve.py`, `grab`,
`upgrade.py`, `weekend_lot.py`), driven by `python3.11` and crontab. The golf
scripts send their own notifications to the user's Telegram.

## Usage

### run

```bash
node {baseDir}/run.js "<shell command>"
node {baseDir}/run.js --timeout 600 "<shell command>"
```

- The command string runs as `ec2-user` inside `bash -lc`, so the login
  environment (PATH, python3.11, ~/.bashrc) is loaded.
- `--timeout <seconds>` (optional, default 300) — how long to wait for the
  command to finish before giving up. Use a larger value for long-running
  scripts.
- Output is returned as `Status`, `ExitCode`, and stdout/stderr.

## Examples (from agent chat)

- "내 골프 크론잡 보여줘" → `node {baseDir}/run.js "crontab -l"`
- "여주CC 예약 dry-run 돌려봐" → `node {baseDir}/run.js --timeout 180 "cd ~/golf && python3.11 yeojucc_reserve.py --slots 20260720:0900 --dry-run"`
- "지금 돌고 있는 골프 프로세스 있어?" → `node {baseDir}/run.js "ps -eo pid,etime,cmd | grep -E 'golf|upgrade|grab|weekend_lot' | grep -v grep"`
- "업그레이드 로그 마지막 30줄 보여줘" → `node {baseDir}/run.js "tail -30 ~/golf/upgrade_*.log"`
- "한성CC 취소표 잡기 시작해줘" → `node {baseDir}/run.js "cd ~/golf && nohup ./hansung_grab start 20260815 0700 --limit 0900 > /dev/null 2>&1 & echo started"`

## Notes

- The target instance is fixed by container env vars. You cannot target any
  other server through this skill.
- SSM truncates stdout at ~24KB. For large output, redirect to a file on the
  server and read it back in chunks (e.g. `... > /tmp/out.txt; head -c 20000 /tmp/out.txt`).
- For background/long-running scripts (grab, upgrade --monitor), launch with
  `nohup ... &` so the SSM command returns immediately instead of waiting.
