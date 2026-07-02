#!/bin/bash
set -e

# --- daemon supervisor ---
#
# We run two long-lived processes inside this container:
#
#   1. simplex-chat — the SimpleX terminal client in headless server mode
#      (bot or plain profile), listening for WebSocket connections on
#      127.0.0.1:5226 (container-local).
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
# PROFILE_DISPLAY_NAME is the SimpleX profile display name. It only takes effect
# on the very first start, when the profile is created; afterwards it lives on
# the persisted profile and is edited over the WebSocket API (e.g. a StartOS
# "Configure Bot Profile" action). Legacy name BOT_DISPLAY_NAME is still honored
# as a deprecated fallback.
PROFILE_DISPLAY_NAME="${PROFILE_DISPLAY_NAME:-${BOT_DISPLAY_NAME:-SimpleX Bot}}"

# PROFILE_PEER_TYPE seeds the profile type on first start:
#   bot   (default) — a SimpleX *bot* (peerType "bot") via --create-bot-*, so
#                     peers' apps highlight commands and show command menus.
#   human           — a plain SimpleX user (pure transport, a scripted node).
# The marker is cosmetic; file sharing works either way. Deprecated fallback:
# BOT_MODE (true -> bot, false -> human) when PROFILE_PEER_TYPE is unset.
#
# simplex-chat has no CLI flag to create a non-bot profile headlessly, and in
# server mode it blocks on an interactive "display name" prompt until stdin
# answers it. So "human" mode feeds the display name (then an empty line for the
# optional full name) over stdin. This only matters on first start — once a
# profile exists the prompt never appears and the piped input is ignored.
PROFILE_PEER_TYPE="${PROFILE_PEER_TYPE:-}"
if [ -z "$PROFILE_PEER_TYPE" ]; then
  case "${BOT_MODE:-true}" in
    false) PROFILE_PEER_TYPE=human ;;
    *)     PROFILE_PEER_TYPE=bot ;;
  esac
fi

# File exchange dirs.
#
# Defaults live under the profile directory ($HOME/.simplex — where simplex-chat
# also keeps its database, since no --database flag is passed), so received
# files and the DB are siblings on one filesystem by construction. inbound and
# tmp MUST stay co-located: simplex-chat finishes a download with an atomic
# rename(2) from tmp into inbound, which fails with EXDEV across mounts. Deriving
# from $HOME (rather than hardcoding /data) keeps files and DB together wherever
# $HOME points; in this image $HOME is /data (a mounted volume). The inbound
# default matches the openclaw-simplex plugin's own default (~/.simplex/files).
# There is no outbound dir here: sending a file is not a simplex-chat setting.
# On send, the caller passes a path that simplex-chat resolves inside this
# container, so outbound is purely a deployment concern — the caller writes the
# file somewhere this container can read and passes that exact path. See the
# README "File exchange" section.
SIMPLEX_INBOUND_DIR="${SIMPLEX_INBOUND_DIR:-$HOME/.simplex/files}"
SIMPLEX_TMP_DIR="${SIMPLEX_TMP_DIR:-$HOME/.simplex/tmp}"

# Custom message relays. When set, the bot routes through these servers instead
# of simplex-chat's built-in public presets. Each variable is a SPACE-separated
# list of full server addresses (the CLI splits the value on spaces), e.g.
#   SMP_SERVERS="smp://<fingerprint>@host1 smp://<fingerprint>@host2"
#   XFTP_SERVERS="xftp://<fingerprint>@host1"
# Passed as a single --server / --xftp-server argument. Unset = use presets.
SMP_SERVERS="${SMP_SERVERS:-}"
XFTP_SERVERS="${XFTP_SERVERS:-}"

# websocat's default maximum WebSocket message size is 64 KiB. A larger SimpleX
# message — a contact/connection event with embedded data, or an inline media
# preview — makes websocat SPLIT it into two frames, which corrupts the JSON
# stream the client parses ("Unterminated string ... at position 65536"). Raise
# the ceiling so whole messages pass through intact. This is a max, not a
# preallocation. Bytes; override only if you ever see splitting warnings.
WS_MAX_MESSAGE_BYTES="${WS_MAX_MESSAGE_BYTES:-16777216}"   # 16 MiB

# A relay address can carry a server basic-auth password
# (smp://<fingerprint>:<password>@host). Redact that password before logging so
# it never lands in container logs, while keeping the scheme, fingerprint, host,
# and port visible for diagnostics. Addresses without a password are unchanged.
mask_server_pw() { sed -E 's#(://[^:@/]+):[^@]*@#\1:***@#g'; }

echo "simplex-chat container starting"
echo "  inbound:  $SIMPLEX_INBOUND_DIR"
echo "  tmp:      $SIMPLEX_TMP_DIR"
echo "  note: to SEND a file, bind-mount a directory this container can read and"
echo "        pass that path in the send command (there is no --outbound-folder;"
echo "        see README 'File exchange'). Use a neutral same-path bind mount,"
echo "        e.g. -v /tmp/simplex-outbound:/tmp/simplex-outbound."
[ -n "$SMP_SERVERS" ]  && echo "  smp:      $(printf '%s' "$SMP_SERVERS"  | mask_server_pw)"
[ -n "$XFTP_SERVERS" ] && echo "  xftp:     $(printf '%s' "$XFTP_SERVERS" | mask_server_pw)"
mkdir -p "$SIMPLEX_INBOUND_DIR" "$SIMPLEX_TMP_DIR"

# Build the argument list. Relay flags are added only when configured (an unset
# value falls through to simplex-chat's presets); bot-creation flags only in
# bot mode.
simplex_args=(
  -p 5226
  --files-folder "$SIMPLEX_INBOUND_DIR"
  --temp-folder "$SIMPLEX_TMP_DIR"
  --yes-migrate
)
[ -n "$SMP_SERVERS" ]  && simplex_args+=(--server "$SMP_SERVERS")
[ -n "$XFTP_SERVERS" ] && simplex_args+=(--xftp-server "$XFTP_SERVERS")

if [ "$PROFILE_PEER_TYPE" = "human" ]; then
  # Plain (non-bot) profile: no headless create flag exists and server mode
  # blocks on the first-start "display name" prompt, so answer it (plus the
  # optional blank full name) over stdin. Process substitution keeps
  # simplex-chat the backgrounded job, so $! is its PID for the supervisor.
  # Has no effect after first start (the prompt no longer appears).
  echo "starting simplex-chat (human profile \"$PROFILE_DISPLAY_NAME\") on 127.0.0.1:5226..."
  /usr/local/bin/simplex-chat "${simplex_args[@]}" < <(printf '%s\n\n' "$PROFILE_DISPLAY_NAME") &
  SIMPLEX_PID=$!
else
  simplex_args+=(--create-bot-display-name "$PROFILE_DISPLAY_NAME" --create-bot-allow-files)
  echo "starting simplex-chat (bot profile \"$PROFILE_DISPLAY_NAME\") on 127.0.0.1:5226..."
  /usr/local/bin/simplex-chat "${simplex_args[@]}" &
  SIMPLEX_PID=$!
fi

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
echo "simplex-chat is listening; starting websocat bridge 0.0.0.0:5225 -> ws://127.0.0.1:5226 (max message ${WS_MAX_MESSAGE_BYTES} bytes)"
/usr/local/bin/websocat -t -B "$WS_MAX_MESSAGE_BYTES" ws-listen:0.0.0.0:5225 ws://127.0.0.1:5226 &
WEBSOCAT_PID=$!
echo "simplex-chat container ready"

# Block until either child exits, then propagate. Requires bash 4.3+.
# Capture the exit code via `||` so `set -e` doesn't short-circuit our
# diagnostic before it runs.
EXIT_CODE=0
wait -n || EXIT_CODE=$?
echo "supervised child exited with $EXIT_CODE — shutting down container" >&2
exit "$EXIT_CODE"
