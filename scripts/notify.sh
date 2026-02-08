#!/usr/bin/env bash
# Telegram bot: notifications + inline keyboard callbacks
set -euo pipefail

ACTION="${1:-}"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${TELEGRAM_CHAT_ID:-}"
API="https://api.telegram.org/bot${BOT_TOKEN}"
OFFSET_FILE="/tmp/telegram-offset"
DESTRUCT_AT_FILE="/tmp/destruct-at"
SESSION_FILE="/opt/remote-vibe-coder/session.env"

if [[ -z "${BOT_TOKEN}" || -z "${CHAT_ID}" ]]; then
  echo "Telegram not configured, skipping."
  exit 0
fi

get_session_id() {
  if [[ -n "${SESSION_ID:-}" ]]; then
    echo "${SESSION_ID}"
  elif [[ -f "${SESSION_FILE}" ]]; then
    grep SESSION_ID "${SESSION_FILE}" | cut -d= -f2
  else
    echo "unknown"
  fi
}

get_ip() {
  curl -s http://169.254.169.254/hetzner/v1/metadata/public-ipv4 2>/dev/null || echo "unknown"
}

format_duration() {
  local mins="$1"
  local h=$((mins / 60))
  local m=$((mins % 60))
  if [[ "${h}" -eq 0 ]]; then echo "${m}m"
  elif [[ "${m}" -eq 0 ]]; then echo "${h}h"
  else echo "${h}h${m}m"; fi
}

time_remaining() {
  local destruct_at
  destruct_at=$(cat "${DESTRUCT_AT_FILE}" 2>/dev/null || echo "0")
  local now
  now=$(date +%s)
  local remaining_sec=$(( destruct_at - now ))
  [[ "${remaining_sec}" -lt 0 ]] && remaining_sec=0
  echo $(( remaining_sec / 60 ))
}

send_message() {
  local text="$1"
  local reply_markup="${2:-}"

  local args=(-s -X POST "${API}/sendMessage"
    -d chat_id="${CHAT_ID}"
    -d parse_mode="Markdown")

  if [[ -n "${reply_markup}" ]]; then
    args+=(-d reply_markup="${reply_markup}")
  fi

  args+=(--data-urlencode text="${text}")
  curl "${args[@]}" 2>/dev/null
}

answer_callback() {
  local callback_id="$1"
  local text="${2:-}"
  curl -s -X POST "${API}/answerCallbackQuery" \
    -d callback_query_id="${callback_id}" \
    -d text="${text}" 2>/dev/null
}

warning() {
  local sid
  sid=$(get_session_id)
  local ip
  ip=$(get_ip)
  local remaining
  remaining=$(time_remaining)
  local remaining_display
  remaining_display=$(format_duration "${remaining}")

  local keyboard='{"inline_keyboard":[[{"text":"+1m","callback_data":"extend_1"},{"text":"+10m","callback_data":"extend_10"},{"text":"+1h","callback_data":"extend_60"},{"text":"+1d","callback_data":"extend_1440"}]]}'

  send_message "⚠️ *Auto-delete in ${remaining_display}* [\`${sid}\`]
IP: \`${ip}\`" "${keyboard}"
}

deleted() {
  local sid
  sid=$(get_session_id)
  send_message "🔴 *Server deleted* [\`${sid}\`]"
}

extend_timer() {
  local add_minutes="$1"
  local destruct_at
  destruct_at=$(cat "${DESTRUCT_AT_FILE}" 2>/dev/null || echo "$(date +%s)")
  local new_destruct_at=$(( destruct_at + add_minutes * 60 ))
  echo "${new_destruct_at}" > "${DESTRUCT_AT_FILE}"

  # Recalculate remaining from now
  local now
  now=$(date +%s)
  local remaining_sec=$(( new_destruct_at - now ))
  local remaining_min=$(( remaining_sec / 60 ))

  # Restart self-destruct timer
  systemctl stop self-destruct.timer 2>/dev/null || true
  sed -i "s/OnActiveSec=.*/OnActiveSec=${remaining_min}min/" /etc/systemd/system/self-destruct.timer
  systemctl daemon-reload
  systemctl restart self-destruct.timer

  # Stop warning timer (we'll send warning inline)
  systemctl stop self-destruct-warning.timer 2>/dev/null || true
}

poll() {
  echo "Starting Telegram callback handler..."

  # Flush old updates from previous server
  local flush
  flush=$(curl -s "${API}/getUpdates?offset=-1" 2>/dev/null || echo '{}')
  local latest_id
  latest_id=$(echo "${flush}" | jq -r '.result[-1].update_id // 0')
  local offset=$((latest_id + 1))
  echo "${offset}" > "${OFFSET_FILE}"
  echo "Flushed old updates, starting from offset ${offset}"

  while true; do
    local response
    response=$(curl -s "${API}/getUpdates?offset=${offset}&timeout=30" 2>/dev/null || echo '{}')

    local results
    results=$(echo "${response}" | jq -r '.result // [] | length')

    if [[ "${results}" -gt 0 ]]; then
      for i in $(seq 0 $((results - 1))); do
        local update_id callback_id callback_data from_id
        update_id=$(echo "${response}" | jq -r ".result[${i}].update_id")
        callback_id=$(echo "${response}" | jq -r ".result[${i}].callback_query.id // empty")
        callback_data=$(echo "${response}" | jq -r ".result[${i}].callback_query.data // empty")
        from_id=$(echo "${response}" | jq -r ".result[${i}].callback_query.from.id // empty")

        offset=$((update_id + 1))
        echo "${offset}" > "${OFFSET_FILE}"

        # Only handle callbacks from the configured chat
        if [[ -n "${callback_id}" && "${from_id}" == "${CHAT_ID}" ]]; then
          case "${callback_data}" in
            delete)
              answer_callback "${callback_id}" "Deleting server..."
              local sid
              sid=$(get_session_id)
              send_message "🗑 *Deleting server now...* [\`${sid}\`]"
              /usr/local/bin/self-destruct.sh
              ;;
            extend_*)
              local add_min="${callback_data#extend_}"
              local add_display
              add_display=$(format_duration "${add_min}")
              answer_callback "${callback_id}" "Extended +${add_display}"
              extend_timer "${add_min}"
              # Re-send warning with updated time
              warning
              ;;
            *)
              answer_callback "${callback_id}" ""
              ;;
          esac
        fi
      done
    fi

    sleep 2
  done
}

case "${ACTION}" in
  started) ;; # sent from hetzner.sh directly
  warning) warning ;;
  deleted) deleted ;;
  poll) poll ;;
  *) echo "Usage: notify.sh [warning|deleted|poll]" ;;
esac
