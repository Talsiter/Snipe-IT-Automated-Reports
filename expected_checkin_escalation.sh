#!/usr/bin/env bash

# Version: 1.5.0
# NOTE: Increment this version for every code change to this script.
#
# Expected Check-In Escalation Script
# Location: /var/www/snipeit/expected_checkin_escalation.sh
#
# How to test:
#   bash -n /var/www/snipeit/expected_checkin_escalation.sh
#   /var/www/snipeit/expected_checkin_escalation.sh
#
# Final validation run settings:
#   RUN_MODE=dry-run
#   OVERRIDE_RECIPIENT="jwright@hvillepd.org"
#
# How to edit:
#   sudo nano /var/www/snipeit/expected_checkin_escalation.sh
#
# Scheduler integration (Laravel Kernel.php):
#   $schedule->exec('/var/www/snipeit/expected_checkin_escalation.sh')
#            ->daily()
#            ->withoutOverlapping()
#            ->appendOutputTo(storage_path('logs/expected_checkin_escalation_run.log'));
set -euo pipefail

SCRIPT_VERSION="1.5.0"
BASE_URL="http://hpd-assetmanagement/api/v1"
TOKEN="${SNIPEIT_API_TOKEN:-}"

# ==============================
# Configuration (edit this block)
# ==============================
ESCALATE_AFTER_DAYS=3
RUN_MODE=live
DISABLE_WEEKEND=true
# OVERRIDE_RECIPIENT="jwright@hvillepd.org"
OVERRIDE_RECIPIENT=""
SEND_DRY_RUN_PREVIEW_IF_NONE=true
DEBUG_LOG=false
LOG_PII=false
SEND_FAILURE_NOTICES=true
FAILURE_NOTICE_RECIPIENT_OVERRIDE=""
FAILURE_NOTICE_MAX_EVENTS=50
EMAIL_SUBJECT_DEFAULT="⏰Expected asset checkin report"
HTML_TEMPLATE_FILE="/var/www/snipeit/email_templates/expected_checkin_escalation.html"
TOKEN_FILE="/var/www/snipeit/.expected_checkin_api_token"
SNIPEIT_PATH="/var/www/snipeit"
ENV_FILE="/var/www/snipeit/.env"
LOG_FILE="/var/www/snipeit/storage/logs/expected_checkin_escalation.log"
API_LIMIT=100
API_OFFSET=0
API_MAX_RETRIES=3
API_RETRY_DELAY_SECONDS=2
API_REQUEST_DELAY_SECONDS=0.10
# ==============================
# Configuration (end)
# ==============================

TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
TODAY="$(date +%F)"
FAILURE_NOTICE_RECIPIENT=""
FAILURE_NOTICE_QUEUED_COUNT=0
FAILURE_NOTICE_DROPPED_COUNT=0
FAILURE_NOTICE_LINES=()
HTML_TEMPLATE_MISSING_NOTICE_SENT=false

apply_cli_overrides() {
  local arg key value chunk
  local -a chunks

  for arg in "$@"; do
    if [[ "$arg" == --set=* ]]; then
      chunk="${arg#--set=}"
      IFS=',' read -r -a chunks <<< "$chunk"
      for chunk in "${chunks[@]}"; do
        key="${chunk%%=*}"
        value="${chunk#*=}"
        key="${key#-}"
        if [[ -n "$key" && "$key" != "$value" ]]; then
          printf -v "$key" '%s' "$value"
        fi
      done
      continue
    fi

    key="${arg%%=*}"
    value="${arg#*=}"
    key="${key#-}"

    if [[ -n "$key" && "$key" != "$value" ]]; then
      printf -v "$key" '%s' "$value"
    fi
  done
}

resolve_token() {
  if [[ -n "$TOKEN" ]]; then
    return 0
  fi

  if [[ -r "$TOKEN_FILE" ]]; then
    TOKEN="$(head -n 1 "$TOKEN_FILE" | tr -d '\r' | xargs)"
  elif [[ -e "$TOKEN_FILE" ]]; then
    echo "Token file exists but is not readable: $TOKEN_FILE"
    log_message "ERROR" "CONFIG_INVALID token_file_unreadable path=\"$TOKEN_FILE\""
    return 1
  fi

  if [[ -z "$TOKEN" || "$TOKEN" == "PASTE_YOUR_TOKEN_HERE" ]]; then
    echo "Missing API token. Set SNIPEIT_API_TOKEN or TOKEN_FILE."
    log_message "ERROR" "CONFIG_MISSING token source=\"SNIPEIT_API_TOKEN or TOKEN_FILE\""
    return 1
  fi

  return 0
}

apply_cli_overrides "$@"

# RUN_MODE options:
#   test    = dependency/config/API checks only, no asset processing, no email sends
#   dry-run = full processing; emails send only when OVERRIDE_RECIPIENT is configured
#   live    = full processing, escalation emails are sent
case "$RUN_MODE" in
  test|dry-run|live)
    ;;
  *)
    echo "Invalid RUN_MODE: $RUN_MODE (use: test, dry-run, live)"
    exit 1
    ;;
esac

log_message() {
  local level="$1"
  local message="$2"
  local log_dir

  if [[ "$level" == "DEBUG" && "$DEBUG_LOG" != "true" ]]; then
    return 0
  fi

  log_dir="$(dirname "$LOG_FILE")"
  mkdir -p "$log_dir"

  if [[ "$LOG_PII" != "true" ]]; then
    message="$(printf '%s' "$message" | sed -E \
      -e 's/[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}/[redacted-email]/g' \
      -e 's/(assigned_username|manager_username)=[^ ]+/\1=[redacted]/g')"
  fi

  echo "[$TIMESTAMP] [$level] $message" >> "$LOG_FILE"
}

json_get() {
  local json_input="$1"
  local python_expr="$2"
  printf '%s' "$json_input" | python3 -c '
import json
import sys

expr = sys.argv[1]
data = json.load(sys.stdin)

def get_path(obj, path):
    cur = obj
    for part in path.split("."):
        if cur is None:
            print("")
            return
        if isinstance(cur, dict):
            cur = cur.get(part)
        else:
            print("")
            return

    if cur is None:
        print("")
    elif isinstance(cur, bool):
        print("true" if cur else "false")
    else:
        print(cur)

get_path(data, expr)
' "$python_expr"
}

extract_asset_tags() {
  local json_input="$1"
  printf '%s' "$json_input" | python3 -c '
import json
import sys

data = json.load(sys.stdin)
for row in data.get("rows", []):
    tag = row.get("asset_tag")
    if tag:
        print(tag)
'
}

send_email_laravel() {
  local recipient="$1"
  local subject="$2"
  local body="$3"
  local is_html="${4:-false}"

  mkdir -p "$SNIPEIT_PATH/storage/.config/psysh"
  cd "$SNIPEIT_PATH"

  MAIL_TO="$recipient" \
  MAIL_SUBJECT="$subject" \
  MAIL_BODY="$body" \
  MAIL_IS_HTML="$is_html" \
  HOME="$SNIPEIT_PATH" \
  XDG_CONFIG_HOME="$SNIPEIT_PATH/storage/.config" \
  php artisan tinker --execute="
if (getenv('MAIL_IS_HTML') === 'true') {
    Mail::send([], [], function (\$message) {
        \$message->to(getenv('MAIL_TO'))->subject(getenv('MAIL_SUBJECT'));
        \$message->setBody(getenv('MAIL_BODY'), 'text/html');
    });
} else {
    Mail::raw(getenv('MAIL_BODY'), function (\$message) {
        \$message->to(getenv('MAIL_TO'))->subject(getenv('MAIL_SUBJECT'));
    });
}
" 2>&1
}

render_html_template() {
  local template_file="$1"
  shift

  if [[ ! -r "$template_file" ]]; then
    if [[ "$HTML_TEMPLATE_MISSING_NOTICE_SENT" != "true" ]]; then
      log_message "ERROR" "HTML_TEMPLATE_MISSING path=\"$template_file\""
      send_failure_notice \
        "Snipe-IT Escalation Script Failure: HTML Template Missing" \
        "The escalation script could not read the configured HTML template at $template_file."
      HTML_TEMPLATE_MISSING_NOTICE_SENT=true
    fi
    return 1
  fi

  printf '%s\n' "$@" | TEMPLATE_FILE="$template_file" python3 -c '
import os
import re
import sys

template_path = os.environ["TEMPLATE_FILE"]
with open(template_path, "r", encoding="utf-8") as f:
    content = f.read()

tokens = {}
for raw in sys.stdin.read().splitlines():
    if "=" not in raw:
        continue
    key, value = raw.split("=", 1)
    tokens[key.strip().lower()] = value

def repl(match):
    token = match.group(1).lower()
    return tokens.get(token, match.group(0))

print(re.sub(r"\$([A-Za-z_][A-Za-z0-9_]*)", repl, content), end="")
'
}

send_failure_notice() {
  local subject="$1"
  local body="$2"

  if [[ "$SEND_FAILURE_NOTICES" != "true" ]]; then
    return 0
  fi

  if (( FAILURE_NOTICE_QUEUED_COUNT < FAILURE_NOTICE_MAX_EVENTS )); then
    FAILURE_NOTICE_LINES+=("- [$TIMESTAMP] $subject :: $body")
    FAILURE_NOTICE_QUEUED_COUNT=$((FAILURE_NOTICE_QUEUED_COUNT + 1))
  else
    FAILURE_NOTICE_DROPPED_COUNT=$((FAILURE_NOTICE_DROPPED_COUNT + 1))
  fi

  return 0
}

flush_failure_notices() {
  if [[ "$SEND_FAILURE_NOTICES" != "true" ]]; then
    return 0
  fi

  if (( FAILURE_NOTICE_QUEUED_COUNT == 0 )); then
    return 0
  fi

  if [[ -z "$FAILURE_NOTICE_RECIPIENT" ]]; then
    log_message "ERROR" "FAILURE_NOTICE_SKIPPED reason=\"No failure notice recipient configured\" queued=$FAILURE_NOTICE_QUEUED_COUNT dropped=$FAILURE_NOTICE_DROPPED_COUNT"
    return 0
  fi

  local summary_subject="Snipe-IT Escalation Script Failure Summary ($FAILURE_NOTICE_QUEUED_COUNT events)"
  local summary_body
  summary_body="Failure summary for expected_checkin_escalation.sh

Run Date: $TODAY
Run Mode: $RUN_MODE
Queued Failures: $FAILURE_NOTICE_QUEUED_COUNT
Dropped Failures (max cap reached): $FAILURE_NOTICE_DROPPED_COUNT

Events:
$(printf '%s\n' "${FAILURE_NOTICE_LINES[@]}")"

  local send_output
  send_output="$(send_email_laravel "$FAILURE_NOTICE_RECIPIENT" "$summary_subject" "$summary_body")" || {
    log_message "ERROR" "FAILURE_NOTICE_SEND_FAILED recipient=$FAILURE_NOTICE_RECIPIENT error=\"$send_output\""
    return 1
  }

  log_message "INFO" "FAILURE_NOTICE_SENT recipient=$FAILURE_NOTICE_RECIPIENT subject=\"$summary_subject\" events=$FAILURE_NOTICE_QUEUED_COUNT dropped=$FAILURE_NOTICE_DROPPED_COUNT"
}

should_send_failure_notice_for_api() {
  local context="$1"
  local status="$2"

  if [[ "$context" == asset\ lookup* && ( "$status" == "404" || "$status" == "429" || "$status" == "request_failed" ) ]]; then
    return 1
  fi

  return 0
}

resolve_failure_notice_recipient() {
  if [[ -n "$FAILURE_NOTICE_RECIPIENT_OVERRIDE" ]]; then
    FAILURE_NOTICE_RECIPIENT="$FAILURE_NOTICE_RECIPIENT_OVERRIDE"
    return 0
  fi

  local resolved=""
  local db_host db_port db_name db_user db_password

  if [[ -r "$ENV_FILE" ]] && command -v mysql >/dev/null 2>&1; then
    db_host="$(sed -n 's/^DB_HOST=//p' "$ENV_FILE" | head -n 1 | tr -d '\r' | sed -E 's/^["'\'']|["'\'']$//g')"
    db_port="$(sed -n 's/^DB_PORT=//p' "$ENV_FILE" | head -n 1 | tr -d '\r' | sed -E 's/^["'\'']|["'\'']$//g')"
    db_name="$(sed -n 's/^DB_DATABASE=//p' "$ENV_FILE" | head -n 1 | tr -d '\r' | sed -E 's/^["'\'']|["'\'']$//g')"
    db_user="$(sed -n 's/^DB_USERNAME=//p' "$ENV_FILE" | head -n 1 | tr -d '\r' | sed -E 's/^["'\'']|["'\'']$//g')"
    db_password="$(sed -n 's/^DB_PASSWORD=//p' "$ENV_FILE" | head -n 1 | tr -d '\r' | sed -E 's/^["'\'']|["'\'']$//g')"

    db_host="${db_host:-127.0.0.1}"
    db_port="${db_port:-3306}"

    resolved="$(MYSQL_PWD="$db_password" mysql -N -h "$db_host" -P "$db_port" -u "$db_user" -D "$db_name" -e "SELECT alert_email FROM settings LIMIT 1;" 2>/dev/null | head -n 1 | tr -d '\r' | xargs)"
  fi

  if [[ -z "$resolved" || "$resolved" == "null" ]]; then
    mkdir -p "$SNIPEIT_PATH/storage/.config/psysh"
    cd "$SNIPEIT_PATH"
    resolved="$(HOME="$SNIPEIT_PATH" XDG_CONFIG_HOME="$SNIPEIT_PATH/storage/.config" php artisan tinker --execute="
\$alertEmail = null;
if (function_exists('setting')) { \$alertEmail = setting('alert_email'); }
if (!\$alertEmail && class_exists('\\\\App\\\\Models\\\\Setting')) {
    try {
        \$settings = \\\\App\\\\Models\\\\Setting::getSettings();
        if (is_object(\$settings) && !empty(\$settings->alert_email)) { \$alertEmail = \$settings->alert_email; }
        if (is_object(\$settings) && empty(\$alertEmail) && !empty(\$settings->alerts_email)) { \$alertEmail = \$settings->alerts_email; }
    } catch (\\\\Throwable \$e) {}
}
echo \$alertEmail ?: config('mail.from.address');
" 2>/dev/null | tail -n 1 | tr -d '\r' | xargs)"
  fi

  if [[ -n "$resolved" && "$resolved" != "null" ]]; then
    FAILURE_NOTICE_RECIPIENT="$resolved"
    return 0
  fi

  FAILURE_NOTICE_RECIPIENT=""
  return 1
}

check_dependencies() {
  local missing=0
  local cmd

  for cmd in curl python3 php date sed; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Missing dependency: $cmd"
      log_message "ERROR" "DEPENDENCY_MISSING command=$cmd"
      missing=1
    fi
  done

  if [[ ! -d "$SNIPEIT_PATH" ]]; then
    echo "Missing Snipe-IT path: $SNIPEIT_PATH"
    log_message "ERROR" "DEPENDENCY_MISSING_PATH path=$SNIPEIT_PATH"
    missing=1
  fi

  if [[ $missing -ne 0 ]]; then
    echo "Dependency checks failed."
    return 1
  fi

  return 0
}

is_valid_json() {
  local payload="$1"
  printf '%s' "$payload" | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1
}

api_get() {
  local url="$1"
  local context="$2"
  local response http_code body
  local attempt=1

  while true; do
    response="$(curl -sS --connect-timeout 15 --max-time 60 \
      -H "Accept: application/json" \
      -H "Authorization: Bearer $TOKEN" \
      -w $'\n%{http_code}' \
      "$url")" || {
        echo "API request failed for $context"
        log_message "ERROR" "API_REQUEST_FAILED context=\"$context\" url=\"$url\""
        if should_send_failure_notice_for_api "$context" "request_failed"; then
          send_failure_notice \
            "Snipe-IT Escalation Script Failure: API Request Failed" \
            "The escalation script failed to connect to API endpoint: $url ($context)."
        else
          log_message "INFO" "FAILURE_NOTICE_SUPPRESSED context=\"$context\" reason=\"Non-critical API request failure\""
        fi
        return 1
      }

    http_code="${response##*$'\n'}"
    body="${response%$'\n'*}"

    if [[ "$http_code" == "429" && $attempt -lt $API_MAX_RETRIES ]]; then
      sleep_seconds=$(( API_RETRY_DELAY_SECONDS * attempt ))
      log_message "ERROR" "API_RATE_LIMIT_RETRY context=\"$context\" url=\"$url\" attempt=$attempt sleep_seconds=$sleep_seconds"
      sleep "$sleep_seconds"
      attempt=$((attempt + 1))
      continue
    fi

    break
  done

  if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    echo "API returned HTTP $http_code for $context"
    log_message "ERROR" "API_HTTP_ERROR context=\"$context\" url=\"$url\" status=$http_code"
    if should_send_failure_notice_for_api "$context" "$http_code"; then
      send_failure_notice \
        "Snipe-IT Escalation Script Failure: API HTTP Error" \
        "The escalation script received HTTP status $http_code from endpoint: $url ($context)."
    else
      log_message "INFO" "FAILURE_NOTICE_SUPPRESSED context=\"$context\" status=$http_code reason=\"Non-critical API HTTP error\""
    fi
    return 1
  fi

  if ! is_valid_json "$body"; then
    echo "API returned malformed JSON for $context"
    log_message "ERROR" "API_JSON_ERROR context=\"$context\" url=\"$url\""
    send_failure_notice \
      "Snipe-IT Escalation Script Failure: Invalid API JSON" \
      "The escalation script received malformed JSON from endpoint: $url ($context)."
    return 1
  fi

  log_message "DEBUG" "API_SUCCESS context=\"$context\" url=\"$url\""
  sleep "$API_REQUEST_DELAY_SECONDS"
  printf '%s' "$body"
}

echo "=== Expected Checkin Escalation ==="
echo "Version: $SCRIPT_VERSION"
echo "Today: $TODAY"
echo "Escalate After Days: $ESCALATE_AFTER_DAYS"
echo "Run Mode: $RUN_MODE"
echo "Disable Weekend: $DISABLE_WEEKEND"
echo "Override Recipient: ${OVERRIDE_RECIPIENT:-none}"
echo "Send Failure Notices: $SEND_FAILURE_NOTICES"
echo "Debug Logging: $DEBUG_LOG"
echo

log_message "INFO" "RUN_STARTED version=$SCRIPT_VERSION run_mode=$RUN_MODE escalate_after_days=$ESCALATE_AFTER_DAYS override_recipient=${OVERRIDE_RECIPIENT:-none}"

check_dependencies || exit 1
resolve_token || exit 1
resolve_failure_notice_recipient || log_message "ERROR" "FAILURE_NOTICE_RECIPIENT_NOT_FOUND source=\"Snipe-IT Email Preferences\""
trap 'flush_failure_notices' EXIT

if [[ "$RUN_MODE" == "test" ]]; then
  echo "TEST MODE: Running API health check only."
  if api_get "$BASE_URL/hardware?limit=1&offset=0" "test-mode hardware health check" >/dev/null; then
    echo "TEST MODE RESULT: API health check passed."
    log_message "INFO" "TEST_MODE_SUCCESS"
    exit 0
  else
    echo "TEST MODE RESULT: API health check failed."
    log_message "ERROR" "TEST_MODE_FAILED"
    exit 1
  fi
fi

if [[ "$DISABLE_WEEKEND" == "true" ]]; then
  day_of_week="$(date +%u)"
  if [[ "$day_of_week" == "6" || "$day_of_week" == "7" ]]; then
    echo "Weekend detected. Processing disabled."
    log_message "INFO" "SKIPPED reason=\"Weekend processing disabled\" run_mode=$RUN_MODE"
    exit 0
  fi
fi

processed_count=0
would_escalate_count=0
sent_count=0
skipped_count=0
page_count=0
total_assets=0

while true; do
  page_count=$((page_count + 1))

  echo "Retrieving asset page $page_count (offset=$API_OFFSET, limit=$API_LIMIT)..."
  if ! assets_json="$(api_get "$BASE_URL/hardware?limit=$API_LIMIT&offset=$API_OFFSET" "hardware list page=$page_count")"; then
    echo "Stopping run due to API list failure."
    log_message "ERROR" "RUN_ABORTED reason=\"Hardware list API failure\" page=$page_count"
    break
  fi

  if [[ $page_count -eq 1 ]]; then
    total_assets="$(json_get "$assets_json" "total")"
    echo "Total Assets Reported By API: ${total_assets:-unknown}"
    echo
  fi

  asset_tags="$(extract_asset_tags "$assets_json")"

  if [[ -z "$asset_tags" ]]; then
    echo "No more assets returned by API."
    echo
    break
  fi

  while IFS= read -r ASSET_TAG; do
    [[ -z "$ASSET_TAG" ]] && continue

    processed_count=$((processed_count + 1))

    echo "=================================================="
    echo "Processing Asset: $ASSET_TAG"
    echo

    if ! asset_json="$(api_get "$BASE_URL/hardware/bytag/$ASSET_TAG" "asset lookup asset_tag=$ASSET_TAG")"; then
      log_message "ERROR" "SKIPPED asset_tag=$ASSET_TAG reason=\"Asset lookup API failure\""
      skipped_count=$((skipped_count + 1))
      continue
    fi

    asset_id="$(json_get "$asset_json" "id")"
    asset_name="$(json_get "$asset_json" "name")"
    asset_model="$(json_get "$asset_json" "model.name")"
    asset_model_number="$(json_get "$asset_json" "model_number")"
    asset_serial="$(json_get "$asset_json" "serial")"
    assigned_user_id="$(json_get "$asset_json" "assigned_to.id")"
    assigned_username="$(json_get "$asset_json" "assigned_to.username")"
    assigned_name="$(json_get "$asset_json" "assigned_to.name")"
    assigned_email="$(json_get "$asset_json" "assigned_to.email")"
    expected_checkin="$(json_get "$asset_json" "expected_checkin.date")"
    expected_checkin_formatted="$(json_get "$asset_json" "expected_checkin.formatted")"
    last_checkin="$(json_get "$asset_json" "last_checkin")"
    last_checkout_formatted="$(json_get "$asset_json" "last_checkout.formatted")"
    checkin_counter="$(json_get "$asset_json" "checkin_counter")"
    checkout_counter="$(json_get "$asset_json" "checkout_counter")"

    if [[ -z "$asset_id" ]]; then
      echo "RESULT: Asset not found. Skipping."
      log_message "ERROR" "SKIPPED asset_tag=$ASSET_TAG reason=\"Asset not found from bytag lookup\""
      skipped_count=$((skipped_count + 1))
      echo
      continue
    fi

    if [[ -z "$asset_model" ]]; then
      asset_model="[Not Available]"
    elif [[ -n "$asset_model_number" && "$asset_model" != *"$asset_model_number"* ]]; then
      asset_model="$asset_model ($asset_model_number)"
    fi

    if [[ -z "$asset_serial" ]]; then
      asset_serial="[Not Available]"
    fi

    if [[ -z "$last_checkout_formatted" ]]; then
      last_checkout_formatted="[Not Available]"
    fi

    if [[ -z "$expected_checkin_formatted" ]]; then
      expected_checkin_formatted="$expected_checkin"
    fi

    if [[ "$DEBUG_LOG" == "true" ]]; then
      echo "Asset ID: $asset_id"
      echo "Asset Name: $asset_name"
      echo "Asset Model: $asset_model"
      echo "Asset Serial: $asset_serial"
      echo "Assigned User ID: ${assigned_user_id:-none}"
      echo "Assigned Username: ${assigned_username:-none}"
      echo "Assigned Name: ${assigned_name:-none}"
      echo "Assigned Email: ${assigned_email:-none}"
      echo "Checkout Date: ${last_checkout_formatted:-none}"
      echo "Expected Checkin: ${expected_checkin_formatted:-none}"
      echo "Last Checkin: ${last_checkin:-null}"
      echo "Checkout Counter: ${checkout_counter:-0}"
      echo "Checkin Counter: ${checkin_counter:-0}"
      echo
    fi

    if [[ -z "$assigned_user_id" \
       || "${checkout_counter:-0}" -lt 1 \
       || ( -n "${last_checkin:-}" && "$last_checkin" != "null" ) \
       || -z "$expected_checkin" ]]; then
      log_message "DEBUG" "WOULD_NOT_ESCALATE asset_tag=$ASSET_TAG asset_id=$asset_id reason=\"Not eligible (not checked out or missing expected check-in)\""
      skipped_count=$((skipped_count + 1))
      continue
    fi

    expected_epoch="$(date -d "$expected_checkin" +%s)"
    today_epoch="$(date -d "$TODAY" +%s)"
    days_overdue="$(( (today_epoch - expected_epoch) / 86400 ))"

    if (( days_overdue < 1 )); then
      log_message "DEBUG" "WOULD_NOT_ESCALATE asset_tag=$ASSET_TAG asset_id=$asset_id reason=\"Not overdue\""
      skipped_count=$((skipped_count + 1))
      continue
    fi

    if ! user_json="$(api_get "$BASE_URL/users/$assigned_user_id" "assigned user lookup id=$assigned_user_id")"; then
      log_message "ERROR" "SKIPPED asset_tag=$ASSET_TAG asset_id=$asset_id reason=\"Assigned user lookup API failure\""
      skipped_count=$((skipped_count + 1))
      continue
    fi

    manager_id="$(json_get "$user_json" "manager.id")"
    manager_name="$(json_get "$user_json" "manager.name")"

    if [[ -z "$manager_id" ]]; then
      log_message "ERROR" "WOULD_NOT_ESCALATE asset_tag=$ASSET_TAG asset_id=$asset_id reason=\"No manager assigned in AD\""
      send_failure_notice \
        "Snipe-IT Escalation Notice: Manager Missing in AD" \
        "The escalation script could not send a manager notification for asset tag $ASSET_TAG because no manager is configured for assigned user '$assigned_name' (user ID: $assigned_user_id)."
      skipped_count=$((skipped_count + 1))
      continue
    fi

    if ! manager_json="$(api_get "$BASE_URL/users/$manager_id" "manager lookup id=$manager_id")"; then
      log_message "ERROR" "SKIPPED asset_tag=$ASSET_TAG asset_id=$asset_id reason=\"Manager lookup API failure\""
      skipped_count=$((skipped_count + 1))
      continue
    fi

    manager_email="$(json_get "$manager_json" "email")"
    manager_username="$(json_get "$manager_json" "username")"
    manager_activated="$(json_get "$manager_json" "activated")"

    if [[ -z "$manager_email" ]]; then
      log_message "ERROR" "WOULD_NOT_ESCALATE asset_tag=$ASSET_TAG asset_id=$asset_id reason=\"Manager has no email\""
      skipped_count=$((skipped_count + 1))
      continue
    fi

    if [[ "$manager_activated" != "true" ]]; then
      log_message "ERROR" "WOULD_NOT_ESCALATE asset_tag=$ASSET_TAG asset_id=$asset_id reason=\"Manager not activated\""
      skipped_count=$((skipped_count + 1))
      continue
    fi

    if (( days_overdue >= ESCALATE_AFTER_DAYS )); then
      should_escalate="true"
    else
      should_escalate="false"
    fi

    if [[ -n "$OVERRIDE_RECIPIENT" ]]; then
      final_recipient="$OVERRIDE_RECIPIENT"
    else
      final_recipient="$manager_email"
    fi

    if [[ "$should_escalate" != "true" ]]; then
      log_message "DEBUG" "WOULD_NOT_ESCALATE asset_tag=$ASSET_TAG asset_id=$asset_id reason=\"Below threshold\""
      skipped_count=$((skipped_count + 1))
      continue
    fi

    would_escalate_count=$((would_escalate_count + 1))

    EMAIL_SUBJECT="$EMAIL_SUBJECT_DEFAULT"
    EMAIL_BODY="$manager_name,

Asset Tag: $ASSET_TAG
Asset Name: $asset_name
Model: $asset_model
Serial Number: $asset_serial
Assigned To: $assigned_name
Assigned Email: $assigned_email
Checkout Date: $last_checkout_formatted
Expected Check-In Date: $expected_checkin_formatted
Days Overdue: $days_overdue"
    use_html="false"
    rendered_html=""
    if rendered_html="$(render_html_template "$HTML_TEMPLATE_FILE" "asset_tag=$ASSET_TAG" "asset_name=$asset_name" "asset_model=$asset_model" "asset_serial=$asset_serial" "assigned_name=$assigned_name" "assigned_email=$assigned_email" "checkout_date=$last_checkout_formatted" "expected_checkin_date=$expected_checkin_formatted" "days_overdue=$days_overdue" "manager_name=$manager_name" "manager_email=$manager_email" "email_subject=$EMAIL_SUBJECT_DEFAULT")"; then
      EMAIL_BODY="$rendered_html"
      use_html="true"
    fi

    should_send_email="false"
    if [[ "$RUN_MODE" == "live" ]]; then
      should_send_email="true"
    elif [[ "$RUN_MODE" == "dry-run" && -n "$OVERRIDE_RECIPIENT" ]]; then
      should_send_email="true"
    fi

    if [[ "$should_send_email" == "true" ]]; then
      if [[ "$RUN_MODE" == "dry-run" ]]; then
        EMAIL_SUBJECT="[DRY-RUN] $EMAIL_SUBJECT"
        EMAIL_BODY="DRY-RUN NOTICE: This email was sent from RUN_MODE=dry-run because OVERRIDE_RECIPIENT is configured.

$EMAIL_BODY"
      fi

      send_output="$(send_email_laravel "$final_recipient" "$EMAIL_SUBJECT" "$EMAIL_BODY" "$use_html")" || {
        log_message "ERROR" "EMAIL_SEND_FAILED asset_tag=$ASSET_TAG final_recipient=$final_recipient error=\"$send_output\""
        send_failure_notice \
          "Snipe-IT Escalation Script Failure: Manager Email Send Failed" \
          "The script failed to send escalation email for asset tag $ASSET_TAG to $final_recipient. Error: $send_output"
        continue
      }

      log_message "INFO" "EMAIL_SENT asset_tag=$ASSET_TAG asset_id=$asset_id final_recipient=$final_recipient manager_username=$manager_username manager_email=$manager_email days_overdue=$days_overdue"
      sent_count=$((sent_count + 1))
    else
      log_message "INFO" "WOULD_ESCALATE asset_tag=$ASSET_TAG asset_id=$asset_id final_recipient=$final_recipient manager_username=$manager_username manager_email=$manager_email days_overdue=$days_overdue run_mode=$RUN_MODE"
    fi
  done <<< "$asset_tags"

  API_OFFSET=$((API_OFFSET + API_LIMIT))
done

if (( would_escalate_count == 0 )); then
  log_message "INFO" "RUN_RESULT no_assets_escalated processed=$processed_count skipped=$skipped_count"

  if [[ "$RUN_MODE" == "dry-run" && -n "$OVERRIDE_RECIPIENT" && "$SEND_DRY_RUN_PREVIEW_IF_NONE" == "true" ]]; then
    preview_subject="[DRY-RUN] HPD Asset Management Escalation Preview (No Overdue Assets)"
    preview_body="This is a dry-run preview email.

RUN_MODE is set to dry-run and OVERRIDE_RECIPIENT is configured, but there were no assets eligible for escalation in this run.

No action is required.

Thank you,
HPD Asset Management
support@hvillepd.org"

    preview_send_output="$(send_email_laravel "$OVERRIDE_RECIPIENT" "$preview_subject" "$preview_body")" || {
      log_message "ERROR" "DRY_RUN_PREVIEW_SEND_FAILED final_recipient=$OVERRIDE_RECIPIENT error=\"$preview_send_output\""
      send_failure_notice \
        "Snipe-IT Escalation Script Failure: Dry-Run Preview Email Send Failed" \
        "The script failed to send dry-run preview email to $OVERRIDE_RECIPIENT. Error: $preview_send_output"
      log_message "INFO" "RUN_SUMMARY processed=$processed_count would_escalate=$would_escalate_count sent=$sent_count skipped=$skipped_count run_mode=$RUN_MODE"
      exit 1
    }

    sent_count=$((sent_count + 1))
    log_message "INFO" "DRY_RUN_PREVIEW_SENT final_recipient=$OVERRIDE_RECIPIENT reason=\"No overdue assets\""
  fi
fi

echo "=================================================="
echo "SUMMARY"
echo "Processed Assets: $processed_count"
echo "Would Escalate: $would_escalate_count"
echo "Emails Sent: $sent_count"
echo "Skipped / No Escalation: $skipped_count"
echo "Log File: $LOG_FILE"

log_message "INFO" "RUN_SUMMARY processed=$processed_count would_escalate=$would_escalate_count sent=$sent_count skipped=$skipped_count run_mode=$RUN_MODE"
