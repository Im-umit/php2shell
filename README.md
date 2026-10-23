# php2shell — CVE-2026-109618 / CVE-2026-109619 reproducer package

Two PHP 0-days in `php_session_rfc1867_callback` (session upload progress,
pre-RINIT, unauthenticated). This package proves both bugs' full mechanics,
demonstrates the weaponization stages, and shows the controls that defeat
them. One command, self-contained lab, PASS/FAIL receipts.

## Requirements

- Ubuntu (bare or WSL2). Tested on Ubuntu 22.04 / PHP 8.1.2.
- Packages: `apache2`, `libapache2-mod-php8.1` (any 8.x works), `python3`,
  `curl`. Optional but recommended: `gdb` (enables the context-level
  receipts R2/RCE#1/RCE#2 — without it those stages are skipped, not faked).
- Root/sudo for apt installs (the lab itself runs as your user; ports are
  high). ~50MB free in /tmp.
- Nothing else. No external files, no network, no hardcoded addresses.

    sudo apt-get install -y apache2 libapache2-mod-php8.1 python3 curl gdb

## Run (out of any folder — the script builds its own lab in /tmp)

    bash php2shell_repro.sh            # or: bash php2shell_repro.sh 18190

Takes 1-3 minutes. Lab lands in /tmp/php2shell_repro (gdb.log = context
trace, error.log = fatals, poc.py = the embedded client).

## What you should see (stage map)

| Stage | Receipt | Nature |
|---|---|---|
| R1 ARM | unauth multipart w/ big filename -> HTTP 500, pre-RINIT OOM ("in Unknown on line 0"), worker survives | deterministic |
| RCE#1 serialize ctx | gdb: orphaned BG(serialize) + next request encodes THROUGH the freed php_serialize_data | deterministic (gdb) |
| RCE#2 unserialize ctx | kill stage: fire reclaims the freed php_unserialize_data, worker SIGSEGVs mid-request | TUNED DEMO - retry envelope attempts=8, ASLR brute required for the final system() call |
| R4 CONTROL 1 | `session.upload_progress.enabled=0` -> identical bodies -> clean 200 | deterministic |
| R6 CONTROL 2a | `memory_limit=256M` (>> post_max_size) -> arm impossible, clean 200 | deterministic |
| R6 CONTROL 2b | `post_max_size=1M` -> pressure body rejected at delivery | deterministic |
| R5 lsphp | verdict on whether LSAPI workers survive startup failure (full-chain vs DoS class) | best-effort + live runbook |

Everything is labeled in the script output itself: deterministic proofs are
R1/R2/R4/R6; the kill stage carries the "TUNED DEMO / ASLR brute required"
label and honestly reports lottery misses (the pro weapon ships the same
8-attempt envelope; its video shows 1/8 and 1/6 successes).

## Files

- `php2shell_repro.sh` — THE reproducer (standalone, embeds its client)
- `ROOT_CAUSE.md` — corrected mechanics of both CVEs (why the leaked
  bundle's cached-zval* story fails and what the real defect is)
- `WEAPON_NOTES.md` — lab receipts incl. two worker kills, video intel,
  completion path to system(), SAPI survival matrix
- `poc_unserialize.py` / `poc_serialize.py` — per-bug PoCs (network-ready,
  `--stall` for stock min_freq victims, `--arm-namelen/--spray` tuning)
- `fast_fire.py` — rapid reclaimer burst (the kill driver)
- `lab_*.sh`, `weapon_*.sh` — the development labs (php -S, strace, gdb,
  Apache single-child, sweeps) — not needed for the reproducer
- `lab_index.php` — reflection page used by the dev labs

## Notes

- R5 checks common lsphp paths; on this package's origin machine it also
  inspects the official lsphp82 8.2.34 binary. Elsewhere it prints the
  3-command live runbook instead of guessing.
- Authorized targets only. The arm/fire bodies are inert without a
  vulnerable PHP behind them.
