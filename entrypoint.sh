#!/bin/bash
set -euo pipefail

WG_CONF=/tmp/wireproxy.conf
SOCKS_BIND="127.0.0.1:25344"
SOCKS_HOST="${SOCKS_BIND%:*}"
SOCKS_PORT="${SOCKS_BIND##*:}"
WIREPROXY_PID=""

wait_for_bind() {
  # Returns 0 if something accepts TCP on $SOCKS_BIND within ~10s.
  # Uses bash's /dev/tcp pseudo-device so we don't depend on iproute2.
  local _
  for _ in {1..20}; do
    if (echo > "/dev/tcp/${SOCKS_HOST}/${SOCKS_PORT}") 2>/dev/null; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

start_wireproxy() {
  wireproxy -c "$WG_CONF" &
  WIREPROXY_PID=$!
}

if [ -z "${WIREGUARD_CONFIG:-}" ]; then
  if [ "${ALLOW_NO_PROXY:-}" = "1" ]; then
    echo "[entrypoint] skipping wireproxy (ALLOW_NO_PROXY=1). Browser will egress directly."
  else
    echo "[entrypoint] ERROR: WIREGUARD_CONFIG is not set." >&2
    echo "[entrypoint] In production, the agent's browser must egress through the proxy." >&2
    echo "[entrypoint] Set ALLOW_NO_PROXY=1 to run without a proxy (local dev only)." >&2
    exit 1
  fi
else
  echo "[entrypoint] WIREGUARD_CONFIG present — starting wireproxy"

  {
    printf '%s\n' "$WIREGUARD_CONFIG" | awk '
      /^\[Interface\]/ { print; print "MTU = 1152"; next }
      { print }
    '
    printf '\n[Socks5]\nBindAddress = %s\n' "$SOCKS_BIND"
  } > "$WG_CONF"
  chmod 600 "$WG_CONF"

  start_wireproxy

  if ! wait_for_bind; then
    echo "[entrypoint] ERROR: wireproxy did not bind ${SOCKS_BIND} within 10s" >&2
    exit 1
  fi

  WG_ENDPOINT=$(grep -iE '^[[:space:]]*Endpoint[[:space:]]*=' "$WG_CONF" | head -1 | tr -d '[:space:]')
  WG_MTU=$(grep -iE '^[[:space:]]*MTU[[:space:]]*=' "$WG_CONF" | head -1 | tr -d '[:space:]')
  echo "[entrypoint] wireproxy started: pid=${WIREPROXY_PID} ${WG_ENDPOINT} ${WG_MTU} bind=${SOCKS_BIND}"

  # Watchdog: every 60s probe the SOCKS listener. After 2 consecutive misses
  # (≥2 min outage), attempt one respawn. If the respawn fails to bind, log
  # and exit the watchdog — alphaclaw keeps running so the agent's own
  # WhatsApp probe surfaces the failure to the operator.
  (
    misses=0
    while true; do
      sleep 60
      if (echo > "/dev/tcp/${SOCKS_HOST}/${SOCKS_PORT}") 2>/dev/null; then
        misses=0
        continue
      fi
      misses=$((misses + 1))
      if [ "$misses" -lt 2 ]; then
        continue
      fi
      if kill -0 "$WIREPROXY_PID" 2>/dev/null; then
        alive=yes
      else
        alive=no
      fi
      echo "[entrypoint][watchdog] SOCKS listener gone on ${SOCKS_BIND} (wireproxy pid=${WIREPROXY_PID} still alive=${alive}) — attempting respawn" >&2

      kill -TERM "$WIREPROXY_PID" 2>/dev/null || true
      for _ in {1..10}; do
        if ! kill -0 "$WIREPROXY_PID" 2>/dev/null; then
          break
        fi
        sleep 0.5
      done
      kill -KILL "$WIREPROXY_PID" 2>/dev/null || true

      start_wireproxy
      if wait_for_bind; then
        echo "[entrypoint][watchdog] respawn succeeded: pid=${WIREPROXY_PID} bind=${SOCKS_BIND}"
        misses=0
        continue
      fi
      echo "[entrypoint][watchdog] respawn failed to bind — upstream tunnel likely dead, alphaclaw will continue running without proxy until next deploy" >&2
      exit 0
    done
  ) &
fi

# Ensure Playwright's Chromium is installed on the persistent /data volume.
# The browser path is set by alphaclaw at runtime to /data/.cache/ms-playwright,
# which doesn't exist during `docker build`, so we install on first container
# start. Subsequent starts are a no-op once the binary is cached on the volume.
PW_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-/data/.cache/ms-playwright}"
if ! find "$PW_BROWSERS_PATH" -maxdepth 3 -name "chrome-headless-shell" -executable 2>/dev/null | grep -q .; then
  echo "[entrypoint] Playwright Chromium not found at $PW_BROWSERS_PATH — installing"
  PLAYWRIGHT_BROWSERS_PATH="$PW_BROWSERS_PATH" npx --prefix /app playwright install chromium
else
  echo "[entrypoint] Playwright Chromium already installed at $PW_BROWSERS_PATH"
fi

exec alphaclaw start
