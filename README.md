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
                                                                └─ /data (volume)
                                                                   └─ .simplex/        (profile DB + keys)
                                                                       └─ media/       (file exchange, mounted at /simplex)
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

## File exchange contract

Other services can exchange files with the bot by mounting subpaths of
this container's `/data` volume. The container publishes a well-known layout:
the volume's `.simplex/media` subpath is mounted at `/simplex` in the bot's
container (a single mount — simplex-chat renames completed downloads from `tmp`
to `inbound`, which requires both to be on one filesystem), containing:

| Volume subpath | Container path | Access for consumers | Purpose |
|---|---|---|---|
| `.simplex/media/inbound` | `/simplex/inbound` | read-only | Files received by the bot (`--files-folder`) |
| `.simplex/media/tmp` | `/simplex/tmp` | read-only (optional) | In-progress transfers (`--temp-folder`) |
| `.simplex/media/outbound` | `/simplex/outbound` | read-write | Consumer-written files for the bot to send |

The file-exchange tree lives under `.simplex/media`, alongside the bot's
profile DB in `.simplex/` (rather than as a separate top-level dir). Consumers
still mount only the `media/*` subpaths below — never `.simplex/` itself.

A consumer that mounts these subpaths at the *same mountpoints* can use file
paths from WebSocket messages verbatim, and pass `/simplex/outbound/...` paths
in send commands verbatim — no path translation. Do **not** mount the whole
`/data` volume (or `.simplex/`); it contains the bot's profile database and keys.

> On StartOS the consumer (e.g. OpenClaw) mounts these subpaths via
> `mountDependency`; with plain Docker, mount the same host subdirectories into
> the consumer container. The full design is in
> [`simplex-chat-startos/docs/file-exchange-architecture.md`](https://github.com/lundog/simplex-chat-startos/blob/master/docs/file-exchange-architecture.md).

## Configuration

The container is configured through environment variables (all optional):

| Variable | Default | Purpose |
|---|---|---|
| `BOT_DISPLAY_NAME` | `SimpleX Bot` | Bot profile name. Applied **only on first boot**, when the profile is created; afterwards it lives on the persisted profile and is changed via the API. |
| `SIMPLEX_DIR` | `/simplex` | Root of the file-exchange tree (the contract mountpoint). `inbound`/`tmp`/`outbound` are derived as subdirectories. |
| `SIMPLEX_INBOUND_DIR` | `$SIMPLEX_DIR/inbound` | Override the received-files dir individually. |
| `SIMPLEX_TMP_DIR` | `$SIMPLEX_DIR/tmp` | Override the in-progress-transfers dir individually. |
| `SIMPLEX_OUTBOUND_DIR` | `$SIMPLEX_DIR/outbound` | Override the outbound dir individually. |

`BOT_DISPLAY_NAME` is the common one and is wired into `docker-compose.yml` and
the Makefile `run` target. The `SIMPLEX_*` paths are advanced knobs — if you
change them, keep `inbound` and `tmp` on the **same filesystem** (simplex-chat
finishes a download with an atomic `tmp` → `inbound` rename that fails across
mounts), and update the `/simplex` volume mountpoint to match.

## Build and run

Prerequisites: Docker (with the `buildx` plugin for multi-arch builds).

### Build the image

```sh
docker build -t simplex-chat .
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
docker build --build-arg IMAGE_REVISION=-1 -t simplex-chat .
# image version label becomes <simplex-version>-1
```

### Run the container

```sh
docker run -d --name simplex-chat \
  -p 5225:5225/tcp \
  -v /Users/lundog/simplex-volume:/data \
  -v /Users/lundog/simplex-volume/.simplex/media:/simplex \
  --restart unless-stopped \
  simplex-chat
```

`/data` holds the bot's profile and chat history (in `.simplex/`); `/simplex`
is the file-exchange tree (see below), which lives at `.simplex/media` inside
the same `/data` volume. Both mounts therefore point into one host directory
and share one filesystem — required for simplex-chat's atomic `tmp` → `inbound`
rename. The WebSocket control interface is then reachable at `ws://localhost:5225`.

### Using docker-compose

Copy `.env.example` to `.env`, adjust `DATA_DIR` / `WS_PORT` / `BOT_DISPLAY_NAME`
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
[`lundog/simplex-chat`](https://hub.docker.com/r/lundog/simplex-chat):

```sh
docker pull lundog/simplex-chat:latest
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

- Container: <https://github.com/lundog/simplex-chat-docker>
- Upstream: <https://github.com/simplex-chat/simplex-chat>

## License

MIT — see `LICENSE`.
