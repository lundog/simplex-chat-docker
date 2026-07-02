# SimpleX Chat for Docker

A Docker container that runs the [SimpleX Chat](https://simplex.chat/) terminal client in headless bot mode, exposed over a WebSocket so other services (or your own scripts) can send and receive SimpleX messages programmatically.

SimpleX Chat is the first messenger with no user identifiers — not even random numbers. It's fully open source, end-to-end encrypted, and metadata-resistant by design.

## What it does

- Boots `simplex-chat` in bot mode (`-p 5226 --create-bot-display-name "SimpleX Bot" --create-bot-allow-files`) so the binary auto-creates a fresh profile on first start.
- Bridges the bot's internal TCP control port to a WebSocket via [`websocat`](https://github.com/vi/websocat), so any WebSocket client can drive the bot using the [SimpleX bot protocol](https://github.com/simplex-chat/simplex-chat/blob/stable/bots/README.md).
- Persists the bot's profile and chat history to the `/data` volume.

## Warning: Anonymous Access Allowed
The WebSocket has no built-in auth — anything that can reach the container can drive the bot.

## Architecture

```
External WebSocket client
        │
        │
        │
        │
        │
        │
        └───────────────▶ websocat (container :5225) ──▶ ws://127.0.0.1:5226
                                                                │
                                                        simplex-chat (-p 5226)
                                                                │
                                                                └─ /data (volume, HOME)
                                                                   └─ .simplex/   (profile DB + keys)
                                                                       ├─ files/    (inbound, --files-folder)
                                                                       ├─ tmp/      (--temp-folder)
                                                                       └─ outbound/ (consumer-written, to send)
```
## Connecting programmatically

This container exposes a single **WebSocket** interface on port 5225.
Connect any WebSocket client to that URL.

### Command format

The bot doesn't accept raw command strings over the WebSocket; every command
must be wrapped in a small JSON envelope:

```json
{ "corrId": "any-id-you-pick", "cmd": "/help" }
```

- `corrId` is a correlation id you choose. The bot echoes it back in the
  matching response so you can pair requests and replies when multiple are in
  flight. Any unique string works.
- `cmd` is the SimpleX terminal command, exactly as you'd type it into the
  `simplex-chat` CLI (leading slash included).

Each reply is a JSON object containing the same `corrId` plus a `resp` field
with the command's result. The bot may also push unsolicited event messages
(without your `corrId`) — incoming chats, contact updates, etc.

See the upstream
[SimpleX bots — sending commands](https://github.com/simplex-chat/simplex-chat/blob/stable/bots/README.md#sending-commands)
guide for the full protocol, and the
[CLI command reference](https://github.com/simplex-chat/simplex-chat/blob/stable/docs/CLI.md)
for the list of `cmd` values you can send.

### A few useful commands

- `/user` — get the active user.
- `/_connect 1` — create a one-time invitation link for user ID 1.
- `/contacts` — list peers who have connected.
- `/profile <name>` — change the bot's display name.

Wrapped, those look like:

```json
{ "corrId": "1", "cmd": "/user" }
{ "corrId": "2", "cmd": "/_connect 1" }
{ "corrId": "3", "cmd": "/contacts" }
{ "corrId": "4", "cmd": "/profile <name>" }
```

A response for the first command will look like this:

```json
{
    "corrId": "1",
    "resp": {
        "type": "activeUser",
        "user": {
            "userId": 1,
            "profile": {
                "displayName": "SimpleX Bot"
            }
        }
    }
}
```

## Backups

The bot's profile, configuration, and chat history all live in the `/data` volume.

## File exchange

Received files live under the bot's profile dir on the `/data` volume, as
siblings of the profile DB:

| Volume subpath | Purpose | simplex-chat flag |
|---|---|---|
| `.simplex/files` | Files received by the bot (inbound) | `--files-folder` |
| `.simplex/tmp` | In-progress transfers | `--temp-folder` |

`files` and `tmp` stay co-located under `.simplex/` on one filesystem — required
because simplex-chat finishes a download with an atomic `tmp` → `files` rename
that fails across mounts.

A consumer (another service, or the openclaw-simplex plugin) exchanges files
with the bot. The two directions work differently:

- **Receiving files (inbound)** — the WebSocket reports a received file by
  *name only*, which the consumer resolves against its own view of the
  `.simplex/files` dir. So the two sides only need to share that one host
  directory; the mountpoint can differ on each side (no matching path required).
- **Sending files (outbound)** — there is **no outbound dir setting and no
  `--outbound-folder` flag**; sending is not a simplex-chat option at all. On
  send you pass a file path that the runtime resolves **inside this container**,
  so the file must already be readable here. The simplest arrangement: a consumer
  that shares this container's `/data` volume writes the file under
  `.simplex/outbound` and passes the container path `/data/.simplex/outbound/…`.
  The bot won't fetch bytes over the WebSocket.

If the consumer mounts the shared directory at a *different* path than the
container's, it writes to its own path and rewrites the prefix to the container
path before sending — no matching/verbatim mount required. The openclaw-simplex
plugin does this automatically: `connection.outboundFolder` is its view of the
directory and `connection.outboundFolderOnClient` is the container's
`/data/.simplex/outbound`; it also creates the directory if missing and removes
staged files after the send.

**Security:** a consumer should share only what it needs — the `.simplex/files`
subpath for inbound and `.simplex/outbound` for sending — never `.simplex/`
itself or the whole `/data` volume, which hold the profile database and keys. On
StartOS the consumer (e.g. OpenClaw) mounts just those subpaths via
`mountDependency`.

## Configuration

The container is configured through environment variables (all optional):

| Variable | Default | Purpose |
|---|---|---|
| `PROFILE_DISPLAY_NAME` | `SimpleX Bot` | Profile display name. Applied **only on first boot**, when the profile is created; afterwards it lives on the persisted profile and is changed via the API. |
| `PROFILE_PEER_TYPE` | `bot` | `bot` creates the profile as a SimpleX *bot* (`peerType: "bot"`) so peers' apps highlight commands and show command menus. `human` creates a plain SimpleX user (pure transport / scripted node). The marker is cosmetic; file sharing works either way. Applies **only on first boot**. |
| `SMP_SERVERS` | *(presets)* | Space-separated list of SMP relay addresses (`smp://<fingerprint>@host`) to use instead of simplex-chat's public presets. Unset = presets. |
| `XFTP_SERVERS` | *(presets)* | Space-separated list of XFTP relay addresses for file transfer. Unset = presets. |
| `SIMPLEX_INBOUND_DIR` | `$HOME/.simplex/files` | Received-files dir (`--files-folder`). |
| `SIMPLEX_TMP_DIR` | `$HOME/.simplex/tmp` | In-progress-transfers dir (`--temp-folder`). |
| `WS_MAX_MESSAGE_BYTES` | `16777216` (16 MiB) | Max WebSocket message size for the `websocat` bridge (`-B`). Above `websocat`'s 64 KiB default so large SimpleX events/previews aren't split into partial frames (which corrupts the JSON the client parses). |
| `INBOUND_RETENTION_HOURS` | *(unset — never delete)* | If set to a positive integer, a background janitor hourly deletes received files under `SIMPLEX_INBOUND_DIR` older than this many hours. `simplex-chat` keeps received files forever and a consumer's inbound mount is usually read-only, so this lets the runtime (which owns the dir) reclaim space. `tmp` is left alone. |

(There is no outbound dir variable — sending a file is not a simplex-chat setting; see [File exchange](#file-exchange).)

`PROFILE_DISPLAY_NAME` and `PROFILE_PEER_TYPE` are wired into
`docker-compose.yml` and the Makefile `run` target. The former names
`BOT_DISPLAY_NAME` and `BOT_MODE` (`true`/`false`) are still honored as
deprecated fallbacks.

`SMP_SERVERS` / `XFTP_SERVERS` accept multiple space-separated addresses, e.g.
`SMP_SERVERS="smp://abc=@relay1.example smp://def=@relay2.example"`; they're
passed to simplex-chat as a single `--server` / `--xftp-server` argument.

The `SIMPLEX_*` paths are advanced knobs and default under `$HOME/.simplex`
(which is `/data/.simplex` in this image, next to the profile DB). If you change
them, keep `inbound` and `tmp` on the **same filesystem** (simplex-chat finishes
a download with an atomic `tmp` → `inbound` rename that fails across mounts).

> **`human` mode note:** there's no CLI flag to create a non-bot profile
> headlessly, so on first boot `human` mode answers simplex-chat's interactive
> display-name prompt over stdin. This is verified to work on `simplex-chat
> v6.5.5`; if a future version changes the first-run prompt, `human`-mode profile
> creation may need revisiting.

## Build and run

Prerequisites: Docker (with the `buildx` plugin for multi-arch builds).

### Build the image

```sh
docker build -t simplex-websocket-bridge .
```

To bump the pinned `simplex-chat` or `websocat` version, edit the `Dockerfile`:
each version and its per-architecture SHA-256 are a matched set, so change them
together (refresh the hashes from the upstream release pages linked in the
`Dockerfile` comments) and commit. They're deliberately not build-arg overrides,
so a version can never drift from its checksum.

For a container-only re-release where the upstream versions are unchanged (e.g.
a fix to `entrypoint.sh`), set the optional hotfix suffix instead — it only
affects the image version label:

```sh
docker build --build-arg IMAGE_REVISION=-1 -t simplex-websocket-bridge .
# image version label becomes <simplex-version>-1
```

### Run the container

```sh
docker run -d --name simplex-websocket-bridge \
  -p 5225:5225/tcp \
  -v /path/to/simplex-volume:/data \
  --restart unless-stopped \
  simplex-websocket-bridge
```

`/data` (the container HOME) holds the bot's profile and chat history in
`.simplex/`, plus the inbound/tmp/outbound file dirs under `.simplex/` — one
mount, one filesystem, so simplex-chat's atomic `tmp` → `files` rename works.
Sending files needs a consumer that shares this volume (or its `.simplex/outbound`
subpath); see [File exchange](#file-exchange). The WebSocket control interface is
reachable at `ws://localhost:5225`.

### Using docker-compose

Copy `.env.example` to `.env`, adjust `DATA_DIR` / `WS_PORT` / `PROFILE_DISPLAY_NAME`
if needed, then:

```sh
docker compose up -d --build    # build locally and run
docker compose up -d            # or pull the published image and run
docker compose logs -f          # follow logs
docker compose down             # stop and remove
```

### Using the Makefile

```sh
make build          # build for the local architecture
make run            # run detached (override DATA_DIR/WS_PORT/TAG as needed)
make logs           # follow logs
make stop           # stop and remove the container
make help           # list all targets
```

## Published image

Prebuilt multi-arch (amd64 + arm64) images are published to Docker Hub as
[`lundog/simplex-websocket-bridge`](https://hub.docker.com/r/lundog/simplex-websocket-bridge):

```sh
docker pull lundog/simplex-websocket-bridge:latest
```

### Publishing a new image

CI publishes automatically: pushing a git tag like `v6.5.4` runs the
[`Publish image`](.github/workflows/publish.yml) GitHub Actions workflow, which
builds for both architectures and pushes `6.5.4`, `6.5`, and `latest`. It needs
two repository secrets: `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` (a Docker Hub
access token with read/write scope).

```sh
git tag v6.5.4
git push origin v6.5.4
```

A pre-release tag like `v6.5.4-1` (e.g. a container-only hotfix) publishes only
the `6.5.4-1` image tag — `latest` and `6.5` stay pointed at the last real
release.

To publish by hand instead:

```sh
make login                       # docker login
make buildx TAG=v6.5.4           # multi-arch build + push
make buildx TAG=latest
```

## Repository

- Container: <https://github.com/lundog/simplex-websocket-bridge-docker>
- Upstream: <https://github.com/simplex-chat/simplex-chat>

## License

MIT — see `LICENSE`.
