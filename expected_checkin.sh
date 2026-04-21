#!/usr/bin/env bash

# Version: 1.0.0
# NOTE: Increment this version for every code change to this script.
#
# Expected Check-In Script (Enhanced)
# Location: /var/www/snipeit/expected_checkin.sh
#
# Purpose:
#   Replacement-style script for Snipe-IT's built-in expected-checkin behavior,
#   using the same hardened methodology as expected_checkin_escalation.sh so we
#   can customize it over time.
set -euo pipefail

BASE_URL="http://hpd-assetmanagement/api/v1"
TOKEN="PASTE_YOUR_TOKEN_HERE"

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

TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
TODAY="$(date +%F)"
FAILURE_NOTICE_RECIPIENT=""

# RUN_MODE options:
#   test    = dependency/config/API checks only, no asset processing, no email sends
#   dry-run = full processing, no notification emails sent
#   live    = full processing and sends notification emails
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
      -e 's/(assigned_username|assigned_email)=[^ ]+/\1=[redacted]/g')"
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

  cd "$SNIPEIT_PATH"

  MAIL_TO="$recipient" \
  MAIL_SUBJECT="$subject" \
  MAIL_BODY="$body" \
  php artisan tinker --execute="
Mail::raw(getenv('MAIL_BODY'), function (\$message) {
    \$message->to(getenv('MAIL_TO'))->subject(getenv('MAIL_SUBJECT'));
});
" 2>&1
}

send_failure_notice() {
  local subject="$1"
  local body="$2"

  if [[ "$SEND_FAILURE_NOTICES" != "true" ]]; then
    return 0
  fi

  if [[ -z "$FAILURE_NOTICE_RECIPIENT" ]]; then
    log_message "ERROR" "FAILURE_NOTICE_SKIPPED reason=\"No failure notice recipient configured\""
    return 0
  fi

  local send_output
  send_output="$(send_email_laravel "$FAILURE_NOTICE_RECIPIENT" "$subject" "$body")" || {
    log_message "ERROR" "FAILURE_NOTICE_SEND_FAILED recipient=$FAILURE_NOTICE_RECIPIENT error=\"$send_output\""
    return 1
  }

  log_message "INFO" "FAILURE_NOTICE_SENT recipient=$FAILURE_NOTICE_RECIPIENT subject=\"$subject\""
}

resolve_failure_notice_recipient() {
  if [[ -n "$FAILURE_NOTICE_RECIPIENT_OVERRIDE" ]]; then
    FAILURE_NOTICE_RECIPIENT="$FAILURE_NOTICE_RECIPIENT_OVERRIDE"
    return 0
  fi

  cd "$SNIPEIT_PATH"
  local resolved
  resolved="$(php artisan tinker --execute="echo setting('alert_email') ?: config('mail.from.address');" 2>/dev/null | tail -n 1 | tr -d '\r' | xargs)"

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
  local response
  local http_code
  local body

  response="$(curl -sS --connect-timeout 15 --max-time 60 \
    -H "Accept: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -w $'\n%{http_code}' \
    "$url")" || {
      echo "API request failed for $context"
      log_message "ERROR" "API_REQUEST_FAILED context=\"$context\" url=\"$url\""
      send_failure_notice \
        "Snipe-IT Expected Check-In Script Failure: API Request Failed" \
        "The expected check-in script failed to connect to API endpoint: $url ($context)."
      return 1
    }

  http_code="${response##*$'\n'}"
  body="${response%$'\n'*}"

  if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    echo "API returned HTTP $http_code for $context"
    log_message "ERROR" "API_HTTP_ERROR context=\"$context\" url=\"$url\" status=$http_code"
    send_failure_notice \
      "Snipe-IT Expected Check-In Script Failure: API HTTP Error" \
      "The expected check-in script received HTTP status $http_code from endpoint: $url ($context)."
    return 1
  fi

  if ! is_valid_json "$body"; then
    echo "API returned malformed JSON for $context"
    log_message "ERROR" "API_JSON_ERROR context=\"$context\" url=\"$url\""
    send_failure_notice \
      "Snipe-IT Expected Check-In Script Failure: Invalid API JSON" \
      "The expected check-in script received malformed JSON from endpoint: $url ($context)."
    return 1
  fi

  log_message "DEBUG" "API_SUCCESS context=\"$context\" url=\"$url\""
  printf '%s' "$body"
}

echo "=== Expected Check-In ==="
echo "Today: $TODAY"
echo "Run Mode: $RUN_MODE"
echo "Disable Weekend: $DISABLE_WEEKEND"
echo "Override Recipient: ${OVERRIDE_RECIPIENT:-none}"
echo "Send Failure Notices: $SEND_FAILURE_NOTICES"
echo "Debug Logging: $DEBUG_LOG"
echo

log_message "INFO" "RUN_STARTED run_mode=$RUN_MODE override_recipient=${OVERRIDE_RECIPIENT:-none}"

check_dependencies || exit 1
resolve_failure_notice_recipient || log_message "ERROR" "FAILURE_NOTICE_RECIPIENT_NOT_FOUND source=\"Snipe-IT Email Preferences\""

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
would_notify_count=0
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
      log_message "ERROR" "SKIPPED asset_tag=$ASSET_TAG reason=\"Asset not found from bytag lookup\""
      skipped_count=$((skipped_count + 1))
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

    if [[ -z "$assigned_user_id" \
       || "${checkout_counter:-0}" -lt 1 \
       || ( -n "${last_checkin:-}" && "$last_checkin" != "null" ) \
       || -z "$expected_checkin" ]]; then
      log_message "DEBUG" "WOULD_NOT_NOTIFY asset_tag=$ASSET_TAG asset_id=$asset_id reason=\"Not eligible (not checked out or missing expected check-in)\""
      skipped_count=$((skipped_count + 1))
      continue
    fi

    expected_epoch="$(date -d "$expected_checkin" +%s)"
    today_epoch="$(date -d "$TODAY" +%s)"
    days_overdue="$(( (today_epoch - expected_epoch) / 86400 ))"

    if (( days_overdue < 1 )); then
      log_message "DEBUG" "WOULD_NOT_NOTIFY asset_tag=$ASSET_TAG asset_id=$asset_id reason=\"Not overdue\""
      skipped_count=$((skipped_count + 1))
      continue
    fi

    if [[ -z "$assigned_email" ]]; then
      log_message "ERROR" "WOULD_NOT_NOTIFY asset_tag=$ASSET_TAG asset_id=$asset_id reason=\"Assigned user has no email\""
      send_failure_notice \
        "Snipe-IT Expected Check-In Notice: Assigned User Missing Email" \
        "The expected check-in script could not notify assigned user '$assigned_name' (user ID: $assigned_user_id) for asset tag $ASSET_TAG because no email address is configured."
      skipped_count=$((skipped_count + 1))
      continue
    fi

    if [[ -n "$OVERRIDE_RECIPIENT" ]]; then
      final_recipient="$OVERRIDE_RECIPIENT"
    else
      final_recipient="$assigned_email"
    fi

    would_notify_count=$((would_notify_count + 1))

    EMAIL_SUBJECT="HPD Asset Management Notice: Asset Overdue for Check-In – $ASSET_TAG"
    EMAIL_BODY="$assigned_name,

This is an automated reminder that the following asset assigned to you appears overdue for check-in.

Asset Details
- Asset Tag: $ASSET_TAG
- Asset Name: $asset_name
- Model: $asset_model
- Serial Number: $asset_serial
- Checkout Date: $last_checkout_formatted
- Expected Check-In Date: $expected_checkin_formatted
- Days Overdue: $days_overdue

If this notice is incorrect, please reply to $EMAIL_SIGNATURE_ADDRESS with details.

If you need to request an extension, reply with:
- the new requested check-in date
- the reason for the extension

Thank you,
$EMAIL_SIGNATURE_NAME
$EMAIL_SIGNATURE_ADDRESS"

    if [[ "$RUN_MODE" == "live" ]]; then
      send_output="$(send_email_laravel "$final_recipient" "$EMAIL_SUBJECT" "$EMAIL_BODY")" || {
        log_message "ERROR" "EMAIL_SEND_FAILED asset_tag=$ASSET_TAG final_recipient=$final_recipient assigned_username=$assigned_username assigned_email=$assigned_email error=\"$send_output\""
        send_failure_notice \
          "Snipe-IT Expected Check-In Script Failure: Notification Email Send Failed" \
          "The script failed to send expected check-in email for asset tag $ASSET_TAG to $final_recipient. Error: $send_output"
        continue
      }

      log_message "INFO" "EMAIL_SENT asset_tag=$ASSET_TAG asset_id=$asset_id final_recipient=$final_recipient assigned_username=$assigned_username assigned_email=$assigned_email days_overdue=$days_overdue"
      sent_count=$((sent_count + 1))
    else
      log_message "INFO" "WOULD_NOTIFY asset_tag=$ASSET_TAG asset_id=$asset_id final_recipient=$final_recipient assigned_username=$assigned_username assigned_email=$assigned_email days_overdue=$days_overdue run_mode=$RUN_MODE"
    fi
  done <<< "$asset_tags"

  API_OFFSET=$((API_OFFSET + API_LIMIT))
done

echo "=================================================="
echo "SUMMARY"
echo "Processed Assets: $processed_count"
echo "Would Notify: $would_notify_count"
echo "Emails Sent: $sent_count"
echo "Skipped / No Notification: $skipped_count"
echo "Log File: $LOG_FILE"

if (( would_notify_count == 0 )); then
  log_message "INFO" "RUN_RESULT no_assets_notified processed=$processed_count skipped=$skipped_count"
fi

log_message "INFO" "RUN_SUMMARY processed=$processed_count would_notify=$would_notify_count sent=$sent_count skipped=$skipped_count run_mode=$RUN_MODE"
