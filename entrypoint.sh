#!/bin/bash
set -e

# --- daemon supervisor ---
#
# We run two long-lived processes inside this container:
#
#   1. simplex-chat — the SimpleX terminal client in bot mode, listening for
#      WebSocket connections on 127.0.0.1:5226 (container-local).
#   2. websocat — translates external WebSocket connections on
#      0.0.0.0:5225 into local connections to simplex-chat.
#
# If either process exits unexpectedly, the service is broken: a dead
# simplex-chat with a live websocat is an especially nasty silent failure
# (the port still listens, the external port-listening health check stays
# green, but every command times out). So this script supervises both — if
# either child dies, we kill the other and exit non-zero so external tooling
# can restart the container.
#
# Note: --create-bot-display-name and --create-bot-allow-files only take
# effect on the very first start, when no profile exists yet. After that,
# the bot's display name and file-sharing setting live on its persisted
# profile and are edited through the API.

SIMPLEX_PID=""
WEBSOCAT_PID=""

cleanup() {
  # Best-effort: kill both children. The `|| true` keeps trap-on-EXIT quiet
  # when the children are already gone (which is the common case here,
  # since we get to cleanup() via `wait -n` returning).
  [ -n "$SIMPLEX_PID" ] && kill "$SIMPLEX_PID" 2>/dev/null || true
  [ -n "$WEBSOCAT_PID" ] && kill "$WEBSOCAT_PID" 2>/dev/null || true
}
trap cleanup TERM INT EXIT

# --- configuration (env-overridable) ---
#
# BOT_DISPLAY_NAME only takes effect on the very first start, when no profile
# exists yet. After that the name lives on the persisted profile and is edited
# through the API.
BOT_DISPLAY_NAME="${BOT_DISPLAY_NAME:-SimpleX Bot}"

# File exchange contract paths.
#
# SIMPLEX_DIR is the published contract root (a mounted volume). Received files
# and in-progress transfers land in its subdirectories so that consumers
# sharing the same host directory can locate them. inbound and tmp MUST stay on
# the same filesystem: simplex-chat finishes a download with an atomic
# rename(2) from tmp into inbound, which fails with EXDEV across mounts. Keeping
# them as siblings under SIMPLEX_DIR (a single mount) guarantees this — so if
# you override them individually, keep inbound and tmp co-located.
SIMPLEX_DIR="${SIMPLEX_DIR:-/simplex}"
SIMPLEX_INBOUND_DIR="${SIMPLEX_INBOUND_DIR:-$SIMPLEX_DIR/inbound}"
SIMPLEX_TMP_DIR="${SIMPLEX_TMP_DIR:-$SIMPLEX_DIR/tmp}"
SIMPLEX_OUTBOUND_DIR="${SIMPLEX_OUTBOUND_DIR:-$SIMPLEX_DIR/outbound}"

echo "simplex-chat container starting"
echo "  inbound:  $SIMPLEX_INBOUND_DIR"
echo "  tmp:      $SIMPLEX_TMP_DIR"
echo "  outbound: $SIMPLEX_OUTBOUND_DIR"
mkdir -p "$SIMPLEX_INBOUND_DIR" "$SIMPLEX_TMP_DIR" "$SIMPLEX_OUTBOUND_DIR"

echo "starting simplex-chat on 127.0.0.1:5226 (display name: \"$BOT_DISPLAY_NAME\")..."
/usr/local/bin/simplex-chat \
  -p 5226 \
  --create-bot-display-name "$BOT_DISPLAY_NAME" \
  --create-bot-allow-files \
  --files-folder "$SIMPLEX_INBOUND_DIR" \
  --temp-folder "$SIMPLEX_TMP_DIR" \
  --yes-migrate \
  &
SIMPLEX_PID=$!

# Wait for simplex-chat to actually be listening on its TCP control port
# before we start the bridge. /dev/tcp is a bash builtin — it opens a TCP
# connection (or fails) without needing curl/nc. 60 seconds gives slow
# disks and large profile databases plenty of headroom on first start.
for _ in $(seq 1 60); do
  if (exec 3<>/dev/tcp/127.0.0.1/5226) 2>/dev/null; then
    break
  fi
  sleep 1
done
if ! (exec 3<>/dev/tcp/127.0.0.1/5226) 2>/dev/null; then
  echo "simplex-chat failed to open 127.0.0.1:5226 within 60s" >&2
  exit 1
fi

# WebSocket bridge: external clients connect here. websocat translates
# each incoming connection on :5225 into an outgoing WebSocket to the
# bot's TCP control port.
echo "simplex-chat is listening; starting websocat bridge 0.0.0.0:5225 -> ws://127.0.0.1:5226"
/usr/local/bin/websocat -t ws-listen:0.0.0.0:5225 ws://127.0.0.1:5226 &
WEBSOCAT_PID=$!
echo "simplex-chat container ready"

# Block until either child exits, then propagate. Requires bash 4.3+.
# Capture the exit code via `||` so `set -e` doesn't short-circuit our
# diagnostic before it runs.
EXIT_CODE=0
wait -n || EXIT_CODE=$?
echo "supervised child exited with $EXIT_CODE — shutting down container" >&2
exit "$EXIT_CODE"
