---
name: ec2-ssm-exec
description: Run shell commands on the user's EC2 instance (golf reservation automation server) via AWS SSM. Use when the user asks to book/reserve golf, check or change golf reservations, grab cancelled tee times, monitor for upgrades, enter weekend lotteries, or inspect cron jobs, logs, processes, and files on their server. Handles both Yeoju CC (여주CC) and Hansung CC (한성CC). Commands run as ec2-user.
allowed-tools: Bash(node:*)
---

# EC2 SSM Command Executor — Golf Reservation Automation

Run shell commands on the user's EC2 instance through AWS SSM (no SSH key / open
port needed). Commands run as `ec2-user` in a login shell. The target instance
and region are fixed by container env (`EC2_TARGET_INSTANCE_ID`,
`EC2_TARGET_REGION`) — you cannot point this at any other host.

The server hosts golf reservation automation under `~/golf/` for two clubs:
**여주CC** (Yeoju, yeojoocc.co.kr) and **한성CC** (Hansung, hansung-cc.co.kr).
All scripts send their results to the user's Telegram automatically.

## How to run

```bash
node {baseDir}/run.js "<shell command>"
node {baseDir}/run.js --timeout 600 "<shell command>"
```

- Runs as `ec2-user` via `bash -lc` (login env: PATH, python3.11, ~/.bashrc).
- `--timeout <seconds>` (default 300). Use higher for long scripts.
- Returns `Status`, `ExitCode`, stdout/stderr.
- All golf wrapper commands live at `~/golf/` — prefix with `cd ~/golf && ` or
  use the full path `~/golf/<cmd>`.

## ⚠️ Before running anything that BOOKS or CANCELS

Booking, cancelling a cron, stopping a monitor, or any real reservation action
is hard to undo. **Confirm the details with the user first** — club, date
(YYYYMMDD), time (HHMM), and which mode (book vs lottery vs grab) — then run it.
Read-only commands (`status`, `log`, `crontab -l`, `dry`) need no confirmation;
run those freely.

---

## 여주CC (Yeoju) commands

### book — 주중 선착순 예약 (weekday, first-come; opens the 10th of each month 09:00)
```bash
~/golf/book 20260703:0700 20260710:0700   # register cron (auto-computes open day)
~/golf/book now 20260703:0700             # run immediately
~/golf/book dry 20260703:0700             # test (no real booking)
~/golf/book status                        # check
~/golf/book cancel                        # cancel the cron
```

### upgrade — 기존 예약을 더 좋은 시간으로 모니터링/변경
```bash
~/golf/upgrade start 20260630 0800        # try to move the 6/30 booking toward 08:00
~/golf/upgrade status
~/golf/upgrade log 20260630
~/golf/upgrade stop 20260630
~/golf/upgrade stop all
```

### grab — 취소타임 잡기 (watch a sold-out date for cancellations)
```bash
~/golf/grab start 20260621 0700 --limit 0900            # target 07:00, reject after 09:00
~/golf/grab start 20260621 0700 --limit 0900 --hole 9   # 9-hole (self)
~/golf/grab status
~/golf/grab log 20260621
~/golf/grab stop 20260621
```

### lot — 주말 추첨 예약 (weekend lottery; auto-runs 3 weeks before, Mon 09:01)
```bash
~/golf/lot 20260712 0700 --time2 0800     # register cron with 1st/2nd time choices
~/golf/lot now 20260712 0700
~/golf/lot dry 20260712 0700
~/golf/lot status
~/golf/lot cancel
```

---

## 한성CC (Hansung) commands

### hansung_book — 예약 접수 (lottery-style reception)
```bash
~/golf/hansung_book 20260627 0700                          # register cron (auto reception day)
~/golf/hansung_book now 20260627 0700                      # run immediately
~/golf/hansung_book dry 20260627 0700                      # test
~/golf/hansung_book status
~/golf/hansung_book cancel
~/golf/hansung_book 20260704 0700 --reception-date 20260616  # manual reception date override
```

Hansung reception rules (lottery):
| 구분 | 접수일 | 시간 |
|------|--------|------|
| 주중(월~금) | 3주 전 같은 요일 | 09:00~11:00 |
| 토요일 | D-18 (화) | 13:00~15:00 |
| 일요일 | D-18 (수) | 13:00~15:00 |

### hansung_grab — 취소타임 잡기
```bash
~/golf/hansung_grab start 20260622 0700 --limit 0900
~/golf/hansung_grab start 20260622 0700 --limit 0900 --hole 9
~/golf/hansung_grab status
~/golf/hansung_grab log 20260622
~/golf/hansung_grab stop 20260622
~/golf/hansung_grab stop all
```

### hansung_reserve — 직접 예약 (standalone, Python)
```bash
python3.11 ~/golf/hansung_reserve.py --slots 20260622:0700
python3.11 ~/golf/hansung_reserve.py --slots 20260622:0700 --time-range 60      # ±60min
python3.11 ~/golf/hansung_reserve.py --slots 20260622:0700 --wait-until 09:00:00 # wait for open
python3.11 ~/golf/hansung_reserve.py --slots 20260622:0700 --dry-run             # test
```

---

## Natural-language → command mapping

Date format is always `YYYYMMDD`, time `HHMM`. Infer the club from context;
if ambiguous, ask. Confirm date/time/club before any real booking.

"부킹/예약 신청한 거 있어?" means **what's registered in cron** (book / lot /
hansung_book entries) — you do NOT need to log into the club sites. Filter
`crontab -l` by club to answer. Yeoju scripts: `book`, `weekend_lot.py`/`lot`,
`upgrade`, `grab`. Hansung scripts: `hansung_book`, `hansung_reserve`,
`hansung_grab`. Present each as: date, time, type (선착순/추첨/취소잡기), schedule.

| User says (Korean) | Command |
|---|---|
| "골프 크론 뭐 있어 / 크론잡 보여줘" | `crontab -l` |
| "여주 부킹 신청한 거 있어? / 여주 예약 뭐 걸어놨어?" | `crontab -l \| grep -Ei 'yeoju\|weekend_lot\|/book\|/lot\|/upgrade\|/grab'` — then summarize the Yeoju entries (ignore Hansung ones) |
| "한성 부킹 신청한 거 있어? / 한성 예약 뭐 걸어놨어?" | `crontab -l \| grep -Ei 'hansung'` — then summarize the Hansung entries |
| "여주 7월3일 주중 7시 예약해줘" | `~/golf/book now 20260703:0700` (confirm first) |
| "여주 7월3일 예약 크론 걸어줘" | `~/golf/book 20260703:0700` |
| "여주 예약 테스트해봐" | `~/golf/book dry 20260703:0700` |
| "여주 book 상태" | `~/golf/book status` |
| "6월30일 예약 더 좋은 시간으로 업그레이드 돌려줘" | `~/golf/upgrade start 20260630 0800` |
| "업그레이드 상태/로그" | `~/golf/upgrade status` / `~/golf/upgrade log 20260630` |
| "6월21일 취소표 잡아줘 (9시 전까지)" | `~/golf/grab start 20260621 0700 --limit 0900` |
| "여주 주말 추첨 7월12일 7시,8시로 넣어줘" | `~/golf/lot 20260712 0700 --time2 0800` |
| "한성 6월27일 접수 걸어줘" | `~/golf/hansung_book 20260627 0700` |
| "한성 6월22일 취소표 잡아줘" | `~/golf/hansung_grab start 20260622 0700 --limit 0900` |
| "한성 6월22일 7시 바로 예약" | `python3.11 ~/golf/hansung_reserve.py --slots 20260622:0700` (confirm) |
| "골프 모니터 뭐 돌고 있어" | `ps -eo pid,etime,cmd \| grep -E 'golf\|upgrade\|grab\|weekend_lot' \| grep -v grep` |
| "업그레이드/그랩 로그 보여줘" | `tail -50 ~/golf/upgrade_*.log` (or the relevant log) |
| "여주 예약 취소(크론)" | `~/golf/book cancel` (confirm) |

---

## Cancellation deadlines (위약 없는 취소)

| 골프장 | 주중 | 주말 |
|--------|------|------|
| 여주CC | 6일 전 | 6일 전 |
| 한성CC | 7일 전 17:00 | 11일 전 17:00 |

## Notes

- Target instance is fixed by container env vars — cannot reach any other host.
- SSM truncates stdout at ~24KB. For large output, redirect to a file and read
  it back in chunks (`... > /tmp/out.txt; head -c 20000 /tmp/out.txt`).
- For long-running monitors (`grab`, `upgrade`), the wrapper backgrounds itself;
  these commands return quickly. Use `status`/`log` to follow progress.
- Monitors are active 07:00–23:00 KST, checking every 10–25 min (bot-evasion).
- Results are emailed/Telegrammed by the scripts themselves; you also return the
  command output to the user.
