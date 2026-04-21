# Snipe-IT Expected Check-In Escalation Script

This repository contains a Bash automation script that checks Snipe-IT assets for overdue expected check-ins and sends escalation notices.

## Versioning requirement

- The script has a version header at the top (`# Version: x.y.z`).
- **Increment this version on every script code change**.

## Script location in production

The script should be located at:

`/var/www/snipeit/expected_checkin_escalation.sh`

## How to test

Use these exact commands:

```bash
bash -n /var/www/snipeit/expected_checkin_escalation.sh
/var/www/snipeit/expected_checkin_escalation.sh
```

For the final validation run, use:

```bash
RUN_MODE=dry-run
OVERRIDE_RECIPIENT="jwright@hvillepd.org"
/var/www/snipeit/expected_checkin_escalation.sh
```

## How to edit

Use:

```bash
sudo nano /var/www/snipeit/expected_checkin_escalation.sh
```

## Scheduler integration (Laravel Kernel.php)

This script is now scheduled from Laravel `Kernel.php` instead of system cron.

Example:

```php
$schedule->exec('/var/www/snipeit/expected_checkin_escalation.sh')
         ->daily()
         ->withoutOverlapping()
         ->appendOutputTo(storage_path('logs/expected_checkin_escalation_run.log'));
```

## What the script does

1. Performs up-front dependency checks (`curl`, `python3`, `php`, `date`, `sed`) and validates the Snipe-IT application path.
2. Resolves a failure-notice recipient from Snipe-IT Email Preferences (`alert_email`) with fallback to Laravel mail-from configuration.
3. Calls Snipe-IT API endpoints, validates HTTP status codes, and validates JSON before processing data.
4. Iterates assets and checks eligibility for escalation (checked out, expected check-in present, overdue).
5. Resolves assigned user + manager data and determines escalation eligibility threshold.
6. Uses structured execution modes (`test`, `dry-run`, `live`) to reduce accidental sends.
7. Sends escalation email only in `live` mode when threshold is met.
8. Sends failure notice emails (if enabled) when API/processing failures occur or when user manager is not configured.
9. Writes run/audit details to the log file with configurable debug verbosity and optional PII redaction.

## Configuration location

All user-editable configuration values are intentionally grouped together in one block near the top of the script under:

`# Configuration (edit this block)`

and ending at:

`# Configuration (end)`

Example:

```bash
# ==============================
# Configuration (edit this block)
# ==============================
ESCALATE_AFTER_DAYS=3
RUN_MODE=live
DISABLE_WEEKEND=true
# OVERRIDE_RECIPIENT="jwright@hvillepd.org"
OVERRIDE_RECIPIENT=""
DEBUG_LOG=false
LOG_PII=false
SEND_FAILURE_NOTICES=true
FAILURE_NOTICE_RECIPIENT_OVERRIDE=""
SNIPEIT_PATH="/var/www/snipeit"
LOG_FILE="/var/www/snipeit/storage/logs/expected_checkin_escalation.log"
API_LIMIT=100
API_OFFSET=0
# ==============================
# Configuration (end)
# ==============================
```

This block includes run mode, escalation threshold, override recipient, path/log settings, logging verbosity, failure-notice behavior, and pagination.

## Execution modes

Set `RUN_MODE` before running:

- `RUN_MODE=test` → validates dependencies and API health only; no processing emails.
- `RUN_MODE=dry-run` → full processing, no escalation emails sent.
- `RUN_MODE=live` → full processing and sends escalation emails.
- Script is configured for `live` mode in the configuration block by default.

## Logging behavior

By default, logging is focused on relevant run outcomes and errors.

- `DEBUG_LOG=false` (default): logs key run results only (for example: no assets escalated, manager email sent, API/dependency/processing errors).
- `DEBUG_LOG=true`: logs verbose details, including debug-level decision traces and per-asset non-escalation reasons.

Additional controls:

- `LOG_PII=false` (default): redact emails/usernames in log entries.
- `LOG_PII=true`: include raw emails/usernames in logs.

## Override recipient behavior (confirmed)

`OVERRIDE_RECIPIENT` follows normal Bash variable behavior: **the last assignment wins**.

Example 1 (always attempts to send to override address):

```bash
# For controlled testing, keep this set to your address.
# Leave blank to use the actual manager email.
OVERRIDE_RECIPIENT="jwright@hvillepd.org"
```

Example 2 (override intentionally disabled; uses manager email):

```bash
# For controlled testing, keep this set to your address.
# Leave blank to use the actual manager email.
OVERRIDE_RECIPIENT="jwright@hvillepd.org"
OVERRIDE_RECIPIENT=""
```

## Manager-not-configured fallback behavior

If an assigned employee has no manager configured, the script:

1. Skips manager escalation email for that asset.
2. Sends a failure notice email to the recipient configured in Snipe-IT Email Preferences.

To disable this and other failure notices:

```bash
SEND_FAILURE_NOTICES=false
```

To override the failure-notice recipient manually:

```bash
FAILURE_NOTICE_RECIPIENT_OVERRIDE="you@example.org"
```

## Operational notes

- Script log file: `/var/www/snipeit/storage/logs/expected_checkin_escalation.log`
- Scheduler output log file: `/var/www/snipeit/storage/logs/expected_checkin_escalation_run.log`
- Recommended schedule in `Kernel.php`: `daily()`.
- Runtime user: Laravel scheduler process user (commonly `www-data`).
- On-call owner: your IT asset management support rotation.
- Consider logrotate in production to manage growth of log files.
