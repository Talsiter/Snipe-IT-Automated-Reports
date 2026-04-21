# Snipe-IT Expected Check-In Script (Enhanced)

This document covers `expected_checkin.sh`, a customizable replacement-style script for Snipe-IT expected check-in notifications using the same hardened methodology as `expected_checkin_escalation.sh`.

## Versioning requirement

- The script has a version header at the top (`# Version: x.y.z`).
- **Increment this version on every script code change**.

## Script location in production

`/var/www/snipeit/expected_checkin.sh`

## How to test

Use these exact commands:

```bash
bash -n /var/www/snipeit/expected_checkin.sh
/var/www/snipeit/expected_checkin.sh
```

For final validation run settings:

```bash
RUN_MODE=dry-run
OVERRIDE_RECIPIENT="jwright@hvillepd.org"
/var/www/snipeit/expected_checkin.sh
```

## Scheduler integration (Laravel Kernel.php)

```php
$schedule->exec('/var/www/snipeit/expected_checkin.sh')
         ->daily()
         ->withoutOverlapping()
         ->appendOutputTo(storage_path('logs/expected_checkin_run.log'));
```

## What the script does

1. Performs dependency checks (`curl`, `python3`, `php`, `date`, `sed`) and validates the Snipe-IT application path.
2. Resolves failure notice recipient from `alert_email` with fallback to `mail.from.address`.
3. Calls Snipe-IT APIs, validates HTTP status and JSON payloads before processing.
4. Iterates assets and identifies expected-checkin overdue assets that are still checked out.
5. Sends a notification to assigned user email (or configured override recipient).
6. Supports `test`, `dry-run`, and `live` execution modes for controlled operations.
7. Sends failure notices when critical API/email flow fails (if enabled).
8. Logs run events and outcomes with optional debug verbosity and PII redaction.

## Configuration location

All editable values are grouped in the configuration block near the top of `expected_checkin.sh`.

```bash
# ==============================
# Configuration (edit this block)
# ==============================
RUN_MODE=live
DISABLE_WEEKEND=true
OVERRIDE_RECIPIENT=""
DEBUG_LOG=false
LOG_PII=false
SEND_FAILURE_NOTICES=true
FAILURE_NOTICE_RECIPIENT_OVERRIDE=""
EMAIL_SIGNATURE_NAME="HPD Asset Management"
EMAIL_SIGNATURE_ADDRESS="support@hvillepd.org"
SNIPEIT_PATH="/var/www/snipeit"
LOG_FILE="/var/www/snipeit/storage/logs/expected_checkin.log"
API_LIMIT=100
API_OFFSET=0
# ==============================
# Configuration (end)
# ==============================
```

## Execution modes

- `RUN_MODE=test` → dependency + API health check only.
- `RUN_MODE=dry-run` → full processing, no emails sent.
- `RUN_MODE=live` → full processing with email sends.

## Logging behavior

- `DEBUG_LOG=false` (default): outcome-focused logs.
- `DEBUG_LOG=true`: verbose logs including decision-level traces.
- `LOG_PII=false` (default): redact email/user identifiers in logs.
- `LOG_PII=true`: include email/user identifiers.

## Override recipient behavior

If `OVERRIDE_RECIPIENT` is set, all notification emails go to that address.
If blank, notifications go to the assigned user email from Snipe-IT.

## Failure notice behavior

If `SEND_FAILURE_NOTICES=true`, script sends failure notices for critical failures.
Recipient resolution order:
1. `FAILURE_NOTICE_RECIPIENT_OVERRIDE`
2. Snipe-IT setting `alert_email`
3. Laravel `mail.from.address`

## Operational notes

- Script log file: `/var/www/snipeit/storage/logs/expected_checkin.log`
- Scheduler output log file: `/var/www/snipeit/storage/logs/expected_checkin_run.log`
- Recommended schedule: `daily()`
- Runtime user: Laravel scheduler process user (commonly `www-data`)
