#!/usr/bin/env bash

set -euo pipefail

BASE_URL="http://hpd-assetmanagement/api/v1"
TOKEN="PASTE_YOUR_TOKEN_HERE"

ESCALATE_AFTER_DAYS=3
DRY_RUN=true
DISABLE_WEEKEND=true

# For controlled testing, keep this set to your address.
# Leave blank to use the actual manager email.
OVERRIDE_RECIPIENT="jwright@hvillepd.org"

LOG_FILE="/home/administrator/expected_checkin_escalation.log"
TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
TODAY="$(date +%F)"
SNIPEIT_PATH="/var/www/snipeit"

# Pagination settings
API_LIMIT=100
API_OFFSET=0

api_get() {
  curl -s \
    -H "Accept: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    "$1"
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

log_message() {
  echo "[$TIMESTAMP] $1" >> "$LOG_FILE"
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

echo "=== Expected Checkin Escalation Test ==="
echo "Today: $TODAY"
echo "Escalate After Days: $ESCALATE_AFTER_DAYS"
echo "Dry Run Mode: $DRY_RUN"
echo "Disable Weekend: $DISABLE_WEEKEND"
echo "Override Recipient: ${OVERRIDE_RECIPIENT:-none}"
echo

if [[ "$DISABLE_WEEKEND" == "true" ]]; then
  day_of_week="$(date +%u)"
  if [[ "$day_of_week" == "6" || "$day_of_week" == "7" ]]; then
    echo "Weekend detected. Processing disabled."
    log_message "SKIPPED reason=\"Weekend processing disabled\" dry_run=$DRY_RUN"
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
  assets_json="$(api_get "$BASE_URL/hardware?limit=$API_LIMIT&offset=$API_OFFSET")"

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

    asset_json="$(api_get "$BASE_URL/hardware/bytag/$ASSET_TAG")"

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
      log_message "SKIPPED asset_tag=$ASSET_TAG reason=\"Asset not found from bytag lookup\""
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

    if [[ -z "$assigned_user_id" \
       || "${checkout_counter:-0}" -lt 1 \
       || ( -n "${last_checkin:-}" && "$last_checkin" != "null" ) \
       || -z "$expected_checkin" ]]; then

      echo "RESULT: Asset not eligible (not checked out OR no expected check-in). No escalation."
      log_message "WOULD_NOT_ESCALATE asset_tag=$ASSET_TAG asset_id=$asset_id reason=\"Not eligible (not checked out or missing expected check-in)\" dry_run=$DRY_RUN"
      skipped_count=$((skipped_count + 1))
      echo
      continue
    fi

    expected_epoch="$(date -d "$expected_checkin" +%s)"
    today_epoch="$(date -d "$TODAY" +%s)"
    days_overdue="$(( (today_epoch - expected_epoch) / 86400 ))"

    echo "Days Overdue: $days_overdue"
    echo

    if (( days_overdue < 1 )); then
      echo "RESULT: Asset is not overdue. No escalation."
      log_message "WOULD_NOT_ESCALATE asset_tag=$ASSET_TAG asset_id=$asset_id assigned_username=$assigned_username days_overdue=$days_overdue threshold=$ESCALATE_AFTER_DAYS reason=\"Not overdue\" dry_run=$DRY_RUN"
      skipped_count=$((skipped_count + 1))
      echo
      continue
    fi

    user_json="$(api_get "$BASE_URL/users/$assigned_user_id")"

    manager_id="$(json_get "$user_json" "manager.id")"
    manager_name="$(json_get "$user_json" "manager.name")"

    echo "Manager ID: ${manager_id:-none}"
    echo "Manager Name: ${manager_name:-none}"
    echo

    if [[ -z "$manager_id" ]]; then
      echo "RESULT: Assigned user has no manager. No escalation."
      log_message "WOULD_NOT_ESCALATE asset_tag=$ASSET_TAG asset_id=$asset_id assigned_username=$assigned_username assigned_email=$assigned_email days_overdue=$days_overdue threshold=$ESCALATE_AFTER_DAYS reason=\"No manager assigned\" dry_run=$DRY_RUN"
      skipped_count=$((skipped_count + 1))
      echo
      continue
    fi

    manager_json="$(api_get "$BASE_URL/users/$manager_id")"

    manager_email="$(json_get "$manager_json" "email")"
    manager_username="$(json_get "$manager_json" "username")"
    manager_activated="$(json_get "$manager_json" "activated")"

    echo "Manager Username: ${manager_username:-none}"
    echo "Manager Email: ${manager_email:-none}"
    echo "Manager Activated: ${manager_activated:-false}"
    echo

    if [[ -z "$manager_email" ]]; then
      echo "RESULT: Manager has no email. No escalation."
      log_message "WOULD_NOT_ESCALATE asset_tag=$ASSET_TAG asset_id=$asset_id assigned_username=$assigned_username manager_username=$manager_username days_overdue=$days_overdue threshold=$ESCALATE_AFTER_DAYS reason=\"Manager has no email\" dry_run=$DRY_RUN"
      skipped_count=$((skipped_count + 1))
      echo
      continue
    fi

    if [[ "$manager_activated" != "true" ]]; then
      echo "RESULT: Manager is not activated. No escalation."
      log_message "WOULD_NOT_ESCALATE asset_tag=$ASSET_TAG asset_id=$asset_id assigned_username=$assigned_username manager_username=$manager_username manager_email=$manager_email days_overdue=$days_overdue threshold=$ESCALATE_AFTER_DAYS reason=\"Manager not activated\" dry_run=$DRY_RUN"
      skipped_count=$((skipped_count + 1))
      echo
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

    EMAIL_SUBJECT="HPD Asset Management Notice: Asset Overdue for Check-In – $ASSET_TAG"

    EMAIL_BODY="$manager_name,

HPD Asset Management is sending this notice because the following asset assigned to $assigned_name appears to be overdue for check-in.

Asset Details
- Asset Tag: $ASSET_TAG
- Asset Name: $asset_name
- Model: $asset_model
- Serial Number: $asset_serial
- Assigned To: $assigned_name
- Assigned User Email: $assigned_email
- Checkout Date: $last_checkout_formatted
- Expected Check-In Date: $expected_checkin_formatted
- Days Overdue: $days_overdue

If this notice is incorrect, please forward this message to support@hvillepd.org and explain why the asset is not overdue for check-in.

If the expected check-in date should be extended, either the assigned employee or their supervisor may request an extension by forwarding this message to support@hvillepd.org and providing:
- the new requested check-in date
- the reason for the extension

Thank you,
HPD Asset Management
support@hvillepd.org"

    echo "Email Subject: $EMAIL_SUBJECT"
    echo "Email Recipient: $final_recipient"
    echo "Email Body:"
    echo "$EMAIL_BODY"
    echo

    echo "=== RESULT ==="
    if [[ "$should_escalate" == "true" ]]; then
      echo "WOULD ESCALATE"
      echo "Reason: Asset is $days_overdue day(s) overdue, which meets or exceeds the threshold of $ESCALATE_AFTER_DAYS."
      echo "Target Manager: $manager_name <$manager_email>"
      echo "Actual Recipient For This Run: $final_recipient"
      would_escalate_count=$((would_escalate_count + 1))
    else
      echo "WOULD NOT ESCALATE"
      echo "Reason: Asset is only $days_overdue day(s) overdue, which is below the threshold of $ESCALATE_AFTER_DAYS."
      skipped_count=$((skipped_count + 1))
    fi
    echo

    if [[ "$should_escalate" == "true" ]]; then
      log_message "WOULD_ESCALATE asset_tag=$ASSET_TAG asset_id=$asset_id assigned_username=$assigned_username assigned_email=$assigned_email manager_username=$manager_username manager_email=$manager_email final_recipient=$final_recipient days_overdue=$days_overdue threshold=$ESCALATE_AFTER_DAYS dry_run=$DRY_RUN subject=\"$EMAIL_SUBJECT\""
    else
      log_message "WOULD_NOT_ESCALATE asset_tag=$ASSET_TAG asset_id=$asset_id assigned_username=$assigned_username assigned_email=$assigned_email manager_username=$manager_username manager_email=$manager_email final_recipient=$final_recipient days_overdue=$days_overdue threshold=$ESCALATE_AFTER_DAYS dry_run=$DRY_RUN reason=\"Below threshold\""
    fi

    if [[ "$should_escalate" == "true" && "$DRY_RUN" == "false" ]]; then
      echo "LIVE MODE ACTIVE: Attempting to send email via Laravel..."
      send_output="$(send_email_laravel "$final_recipient" "$EMAIL_SUBJECT" "$EMAIL_BODY")" || {
        echo "EMAIL SEND FAILED"
        echo "$send_output"
        log_message "EMAIL_SEND_FAILED asset_tag=$ASSET_TAG final_recipient=$final_recipient error=\"$send_output\""
        echo
        continue
      }

      echo "$send_output"
      echo "EMAIL SENT"
      log_message "EMAIL_SENT asset_tag=$ASSET_TAG asset_id=$asset_id final_recipient=$final_recipient subject=\"$EMAIL_SUBJECT\""
      sent_count=$((sent_count + 1))
    elif [[ "$DRY_RUN" == "true" ]]; then
      echo "DRY RUN ACTIVE: No email was sent."
    else
      echo "LIVE MODE ACTIVE: No email sent because threshold was not met."
    fi

    echo
  done <<< "$asset_tags"

  API_OFFSET=$((API_OFFSET + API_LIMIT))
done

echo "=================================================="
echo "SUMMARY"
echo "Processed Assets: $processed_count"
echo "Would Escalate: $would_escalate_count"
echo "Emails Sent: $sent_count"
echo "Skipped / No Escalation: $skipped_count"
echo "Log File: $LOG_FILE"
