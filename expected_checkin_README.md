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

CLI override example (without editing the file):

```bash
/var/www/snipeit/expected_checkin.sh RUN_MODE=dry-run SEND_DRY_RUN_PREVIEW_IF_NONE=false LOG_FILE=/var/www/snipeit/storage/logs/expected_checkin_TEMP.log
```

Also supported:

```bash
/var/www/snipeit/expected_checkin.sh --set=RUN_MODE=dry-run,SEND_DRY_RUN_PREVIEW_IF_NONE=false,LOG_FILE=/var/www/snipeit/storage/logs/expected_checkin_TEMP.log
```

## How to edit

Use:

```bash
sudo nano /var/www/snipeit/expected_checkin.sh
```

## Scheduler integration (Laravel Kernel.php)

Open the scheduler file with:

```bash
sudo nano /var/www/snipeit/app/Console/Kernel.php
```

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
5. Sends a notification to assigned user email in `live`, or to override recipient in `dry-run` when configured.
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
DISABLE_WEEKEND=false
OVERRIDE_RECIPIENT=""
SEND_DRY_RUN_PREVIEW_IF_NONE=true
DEBUG_LOG=false
LOG_PII=false
SEND_FAILURE_NOTICES=true
FAILURE_NOTICE_RECIPIENT_OVERRIDE=""
FAILURE_NOTICE_MAX_EVENTS=50
TOKEN_FILE="/var/www/snipeit/.expected_checkin_api_token"
ENV_FILE="/var/www/snipeit/.env"
EMAIL_SIGNATURE_NAME="HPD Asset Management"
EMAIL_SIGNATURE_ADDRESS="support@hvillepd.org"
SNIPEIT_PATH="/var/www/snipeit"
LOG_FILE="/var/www/snipeit/storage/logs/expected_checkin.log"
EMAIL_SUBJECT_DEFAULT="⏰Expected asset checkin report"
HTML_TEMPLATE_FILE="/var/www/snipeit/email_templates/expected_checkin.html"
API_LIMIT=100
API_OFFSET=0
API_MAX_RETRIES=3
API_RETRY_DELAY_SECONDS=2
API_REQUEST_DELAY_SECONDS=0.10
# ==============================
# Configuration (end)
# ==============================
```

## Execution modes

- `RUN_MODE=test` → dependency + API health check only.
- `RUN_MODE=dry-run` → full processing; emails send **only if** `OVERRIDE_RECIPIENT` is configured.
- `RUN_MODE=live` → full processing with email sends.

## Logging behavior

- `DEBUG_LOG=false` (default): outcome-focused logs.
- `DEBUG_LOG=true`: verbose logs including decision-level traces.
- `LOG_PII=false` (default): redact email/user identifiers in logs.
- `LOG_PII=true`: include email/user identifiers.

### Delete the script log file (CLI)

```bash
rm -f /var/www/snipeit/storage/logs/expected_checkin.log
```

## HTML email template support

- `HTML_TEMPLATE_FILE` points to an HTML file used for notification emails.
- If the file cannot be read, the script falls back to plain-text email and sends a single failure notification for that run.
- Token replacement is case-insensitive (for example `$ASSET_TAG`, `$asset_tag`, and `$Asset_Tag` are all supported).
- Default subject is controlled by `EMAIL_SUBJECT_DEFAULT` and defaults to `⏰Expected asset checkin report`.

Supported tokens:

- `$asset_tag`
- `$asset_name`
- `$asset_model`
- `$asset_serial`
- `$checkout_date`
- `$expected_checkin_date`
- `$days_overdue`
- `$assigned_name`
- `$assigned_email`
- `$support_name`
- `$support_email`
- `$email_subject`

## Expected check-in recipient behavior

- In `live` mode with no override, one email is sent to the assigned user and a separate email is sent to the configured alert email recipient.
- Alert email is resolved from the existing failure-notice recipient resolution path (`FAILURE_NOTICE_RECIPIENT_OVERRIDE` → `settings.alert_email` → Laravel fallback).
- In `dry-run` with `OVERRIDE_RECIPIENT`, only the override recipient is used.

## Override recipient behavior

If `OVERRIDE_RECIPIENT` is set, all notification emails go to that address.
If blank, notifications go to the assigned user email from Snipe-IT.

## Dry-run preview email option

To force a test email when there are no overdue assets in `dry-run`, set:

```bash
SEND_DRY_RUN_PREVIEW_IF_NONE=true
```

This sends a single preview message to `OVERRIDE_RECIPIENT` **only when all of the following are true**:
1. `RUN_MODE=dry-run`
2. `OVERRIDE_RECIPIENT` is configured
3. No assets are eligible for notification in that run

## Failure notice behavior

If `SEND_FAILURE_NOTICES=true`, script sends failure notices for critical failures.
Recipient resolution order:
1. `FAILURE_NOTICE_RECIPIENT_OVERRIDE`
2. Snipe-IT database `settings.alert_email` (via credentials in `.env`)
3. Snipe-IT/Laravel fallback lookup (`alert_email`/`alerts_email`)
4. Laravel `mail.from.address`

Failure notices are batched and sent as a **single summary email per run** (up to `FAILURE_NOTICE_MAX_EVENTS` entries in the message body).
Per-asset API lookup throttling/not-found errors (for example HTTP `429`/`404` during individual asset lookups) are suppressed from failure emails to reduce noise.

## Token storage (recommended)

Do not hardcode the API token in the script.

Preferred order used by the script:
1. Environment variable: `SNIPEIT_API_TOKEN`
2. Token file path from `TOKEN_FILE` (default: `/var/www/snipeit/.expected_checkin_api_token`)

Example:

```bash
sudo install -o www-data -g www-data -m 600 /dev/null /var/www/snipeit/.expected_checkin_api_token
sudo sh -c 'echo "YOUR_REAL_TOKEN" > /var/www/snipeit/.expected_checkin_api_token'
sudo chown www-data:www-data /var/www/snipeit/.expected_checkin_api_token
```

## Operational notes

- Script log file: `/var/www/snipeit/storage/logs/expected_checkin.log`
- Scheduler output log file: `/var/www/snipeit/storage/logs/expected_checkin_run.log`
- Recommended schedule: `daily()`
- Runtime user: Laravel scheduler process user (commonly `www-data`)
