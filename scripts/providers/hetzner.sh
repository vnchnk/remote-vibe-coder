#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:?Usage: hetzner.sh [create|destroy|status]}"
SERVER_NAME="${SERVER_NAME:-remote-vibe-coder}"
CLOUD_SERVER_TYPE="${CLOUD_SERVER_TYPE:-cx23}"
CLOUD_LOCATION="${CLOUD_LOCATION:-nbg1}"

# hcloud CLI reads HCLOUD_TOKEN automatically
export HCLOUD_TOKEN="${HETZNER_API_TOKEN}"

format_duration() {
  local mins="$1"
  local h=$((mins / 60))
  local m=$((mins % 60))
  if [[ "${h}" -eq 0 ]]; then echo "${m}m"
  elif [[ "${m}" -eq 0 ]]; then echo "${h}h"
  else echo "${h}h${m}m"; fi
}

create() {
  SESSION_ID=$(head -c 4 /dev/urandom | xxd -p)
  echo "Creating server ${SERVER_NAME} [${SESSION_ID}] (${CLOUD_SERVER_TYPE}) in ${CLOUD_LOCATION}..."

  # Ensure SSH key exists in Hetzner
  if ! hcloud ssh-key describe "${SERVER_NAME}" &>/dev/null; then
    echo "Uploading SSH key to Hetzner..."
    hcloud ssh-key create --name "${SERVER_NAME}" --public-key "${SSH_PUBLIC_KEY}"
  fi

  # Build params file (add new params here — they auto-appear in notifications)
  PARAMS_FILE=$(mktemp)
  cat > "${PARAMS_FILE}" <<EOF
Provider: hetzner
Type: ${CLOUD_SERVER_TYPE}
Location: ${CLOUD_LOCATION}
Repository: ${REPOSITORY:-none}
Auto-delete: ${CLOUD_AUTO_DELETE:-true}
TTL: $(format_duration "${CLOUD_TTL_MINUTES:-720}")
Warning: $(format_duration "${CLOUD_WARNING_MINUTES:-240}")
EOF

  # Prepare cloud-init user-data
  USERDATA_FILE=$(mktemp)
  cp scripts/setup.sh "${USERDATA_FILE}"
  sed -i "s|__GH_PAT__|${GH_PAT:-}|g" "${USERDATA_FILE}"
  sed -i "s|__REPOSITORY__|${REPOSITORY:-}|g" "${USERDATA_FILE}"
  sed -i "s|__HETZNER_API_TOKEN__|${HETZNER_API_TOKEN}|g" "${USERDATA_FILE}"
  sed -i "s|__CLOUD_AUTO_DELETE__|${CLOUD_AUTO_DELETE:-true}|g" "${USERDATA_FILE}"
  sed -i "s|__CLOUD_TTL_MINUTES__|${CLOUD_TTL_MINUTES:-720}|g" "${USERDATA_FILE}"
  sed -i "s|__CLOUD_WARNING_MINUTES__|${CLOUD_WARNING_MINUTES:-240}|g" "${USERDATA_FILE}"
  sed -i "s|__TELEGRAM_BOT_TOKEN__|${TELEGRAM_BOT_TOKEN:-}|g" "${USERDATA_FILE}"
  sed -i "s|__TELEGRAM_CHAT_ID__|${TELEGRAM_CHAT_ID:-}|g" "${USERDATA_FILE}"
  sed -i "s|__SESSION_ID__|${SESSION_ID}|g" "${USERDATA_FILE}"

  # Embed notify.sh into setup.sh
  sed -i '/__NOTIFY_SCRIPT__/{
    r scripts/notify.sh
    d
  }' "${USERDATA_FILE}"

  # Embed params into setup.sh
  sed -i '/__PARAMS__/{
    r '"${PARAMS_FILE}"'
    d
  }' "${USERDATA_FILE}"

  RESULT=$(hcloud server create \
    --name "${SERVER_NAME}" \
    --type "${CLOUD_SERVER_TYPE}" \
    --location "${CLOUD_LOCATION}" \
    --image ubuntu-24.04 \
    --ssh-key "${SERVER_NAME}" \
    --user-data-from-file "${USERDATA_FILE}" \
    --output json)

  rm -f "${USERDATA_FILE}"

  SERVER_IP=$(echo "${RESULT}" | jq -r '.server.public_net.ipv4.ip')

  # Send started notification immediately (don't wait for cloud-init)
  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
    local ttl_display
    ttl_display=$(format_duration "${CLOUD_TTL_MINUTES:-720}")
    local params_text
    params_text=$(sed 's/^/  /' "${PARAMS_FILE}")
    local keyboard='{"inline_keyboard":[[{"text":"🗑 Delete now","callback_data":"delete"}]]}'

    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d chat_id="${TELEGRAM_CHAT_ID}" \
      -d parse_mode="Markdown" \
      -d reply_markup="${keyboard}" \
      --data-urlencode text="$(cat <<MSG
🟢 *Server started* [\`${SESSION_ID}\`]

IP: \`${SERVER_IP}\`
SSH: \`ssh -i ~/.ssh/sandbox_personal root@${SERVER_IP}\`
Auto-delete in: ${ttl_display}

${params_text}
MSG
)" > /dev/null
  fi

  rm -f "${PARAMS_FILE}"
  echo "::notice::Server ready at ${SERVER_IP} — ssh -i ~/.ssh/sandbox_personal root@${SERVER_IP}"
}

destroy() {
  if ! hcloud server describe "${SERVER_NAME}" &>/dev/null; then
    echo "No server to destroy."
    return 0
  fi

  echo "Destroying server ${SERVER_NAME}..."
  hcloud server delete "${SERVER_NAME}"
  echo "::notice::Server destroyed."
}

status() {
  if ! hcloud server describe "${SERVER_NAME}" &>/dev/null; then
    echo "No server running."
    echo "::notice::No server running."
    return 0
  fi

  hcloud server describe "${SERVER_NAME}" -o json | jq '{
    name: .name,
    status: .status,
    type: .server_type.name,
    location: .datacenter.name,
    ip: .public_net.ipv4.ip,
    created: .created
  }'

  SERVER_IP=$(hcloud server ip "${SERVER_NAME}")
  echo "::notice::Server at ${SERVER_IP}"
}

case "${ACTION}" in
  create|start) create ;;
  destroy|stop) destroy ;;
  status) status ;;
  *) echo "Unknown action: ${ACTION}"; exit 1 ;;
esac
