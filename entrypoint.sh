#!/bin/bash
set -euo pipefail

if [ -n "${WIREGUARD_CONFIG:-}" ]; then
  echo "[entrypoint] WIREGUARD_CONFIG present — starting wireproxy"

  WG_CONF=/tmp/wireproxy.conf
  {
    printf '%s\n' "$WIREGUARD_CONFIG" | awk '
      /^\[Interface\]/ { print; print "MTU = 1152"; next }
      { print }
    '
    printf '\n[Socks5]\nBindAddress = 127.0.0.1:25344\n'
  } > "$WG_CONF"
  chmod 600 "$WG_CONF"

  wireproxy -c "$WG_CONF" &

  for _ in {1..20}; do
    if (echo > /dev/tcp/127.0.0.1/25344) 2>/dev/null; then
      echo "[entrypoint] wireproxy SOCKS5 listening on 127.0.0.1:25344"
      break
    fi
    sleep 0.5
  done

  if ! (echo > /dev/tcp/127.0.0.1/25344) 2>/dev/null; then
    echo "[entrypoint] ERROR: wireproxy did not bind 127.0.0.1:25344 within 10s" >&2
    exit 1
  fi
else
  echo "[entrypoint] WIREGUARD_CONFIG not set — skipping wireproxy. Browser will egress directly." >&2
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
