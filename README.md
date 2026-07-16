# Voice Bridge — Discord ↔ Fluxy

Bidirectional real-time audio bridge between Discord and Fluxy (Fluxer) voice channels.

## Architecture

```
┌──────────────┐     WebSocket      ┌──────────────┐     WebSocket      ┌──────────────┐
│  Discord Bot  │ ◄──────────────► │ Bridge Server │ ◄──────────────► │  Fluxy Bot   │
│  (discord.js  │     Opus frames   │  (WS Router)  │     Opus frames   │ (LiveKit SDK) │
│   @discordjs/ │                   │               │                   │  Fluxer REST  │
│   voice)      │                   │               │                   │               │
└──────┬───────┘                   └───────────────┘                   └──────┬───────┘
       │                                                                      │
       ▼                                                                      ▼
┌──────────────┐                                                   ┌──────────────┐
│ Discord Voice │                                                   │  Fluxy Voice  │
│   (Opus)      │                                                   │ (LiveKit/Opus)│
└──────────────┘                                                   └──────────────┘
```

### Components

| Component | Role |
|-----------|------|
| **bridge-server/** | Central WebSocket server. Routes Opus audio frames between bot clients. Manages bridge lifecycle (create, list, destroy). Echo prevention via origin tagging. |
| **discord-bot/** | Discord.js client. Joins voice channels via `@discordjs/voice`. Receives Opus from speaking users, forwards to bridge. Plays Opus received from bridge in channel. Slash commands: `/calls`, `/call`, `/hangup`. |
| **fluxy-bot/** | Fluxer REST API + LiveKit client. Gets LiveKit tokens from Fluxer API. Connects to LiveKit rooms. Converts between Opus (WebSocket) and PCM16 (LiveKit). Text-based command REPL. |
| **shared/** | Shared TypeScript types, WebSocket protocol, channel mapper utility. |

## Prerequisites

- **Node.js** >= 18 (tested with 20+)
- **npm** >= 9
- **Discord Bot Token** with `GUILD_VOICE_STATES` and `GUILD_MESSAGES` intents
- **Fluxer Bot Token** from [Fluxer Dev Portal](https://fluxer.app/developers)
- **C++ build tools** (for `@discordjs/opus` and `@livekit/rtc-node` native addons)
  - Windows: `npm install --global windows-build-tools` or install Visual Studio Build Tools
  - macOS: `xcode-select --install`
  - Linux: `apt install build-essential python3`

## Quick Start

### 1. Install

```bash
cd voice-bridge
npm install
npm run build
```

### 2. Configure

```bash
cp .env.example .env
```

Edit `.env`:

```env
# Bridge Server
BRIDGE_PORT=4300
BRIDGE_AUTH_TOKEN=my-secret-token

# Discord Bot
DISCORD_TOKEN=MTUyNjk3MTUyMzUwNjc2NTkzNQ.Gd6LO8.mfIHlt-x1JKPbAZFtHR_B9_ejaQ6eXk5W4iq4A

# Fluxy Bot
FLUXY_TOKEN=1526970977475375104.KI8lOFdeydMYKRHfurHNDc5oN444e8AQ_vjWZiWOc0I
FLUXY_GUILD_ID=   # (optional) — auto-detects first guild if empty
FLUXY_API_URL=https://api.fluxer.app/v1
```

### 3. Start the bridge server

```bash
npm run start:bridge
```

### 4. Start the bots

Each in its own terminal:

```bash
npm run start:discord
npm run start:fluxy
```

## Audio Flow

### Discord → Fluxy

```
Discord user speaks
  → @discordjs/voice VoiceReceiver captures Opus packet
  → discord-bot sends binary WS frame (4-byte header len + JSON header + Opus)
  → bridge-server receives, validates origin tag (echo prevention)
  → bridge-server forwards to fluxy-bot
  → fluxy-bot decodes Opus → PCM16 s16le
  → fluxy-bot pushes PCM16 to AudioSource
  → LiveKit publishes to room → Fluxy users hear it
```

### Fluxy → Discord

```
Fluxy user speaks
  → LiveKit room receives → RemoteAudioTrack → AudioStream events
  → fluxy-bot captures PCM16 frame
  → fluxy-bot encodes PCM16 → Opus
  → fluxy-bot sends binary WS frame
  → bridge-server validates origin
  → bridge-server forwards to discord-bot
  → discord-bot feeds Opus into FeedableOpusStream
  → @discordjs/voice AudioPlayer plays in Discord channel
```

## Commands

### Discord (Slash Commands)

| Command | Description |
|---------|-------------|
| `/calls` | List voice channels with user counts |
| `/call <channel>` | Bridge your current channel to a Fluxy channel |
| `/hangup` | Disconnect the current bridge |

### Fluxy (Text REPL)

| Command | Description |
|---------|-------------|
| `/calls` | List active Fluxy voice channels with user counts |
| `/call <channel>` | Bridge to a Discord channel by name |
| `/hangup` | Disconnect the current bridge |
| `/help` | List commands |
| `/quit` | Stop the bot |

## Echo Prevention

Each audio frame carries an `origin` field set to either `discord` or `fluxy`.

- **Bridge server** checks the origin before forwarding — never sends audio back to its platform of origin.
- This double-guard prevents feedback/echo loops.
- Audio is never decoded/re-encoded at the bridge layer; Opus stays as raw bytes.

## Multiple Bridges

The bridge server supports N simultaneous bridges:

```
Discord: Geral    ↔ Fluxy: Geral
Discord: Jogos    ↔ Fluxy: Jogos
Discord: Staff    ↔ Fluxy: Staff
```

Each bridge is tracked by ID and operates independently. A channel can only be in one bridge at a time (duplicate prevention).

## Channel Sync

Channels with identical names are auto-matched. The `ChannelMapper` in `shared/` handles this:

- Case-insensitive name matching
- Manual overrides via `ChannelMapper.override(name, discordId?, fluxyId?)`
- Persisted mapping (future: JSON file or DB)

## Project Structure

```
voice-bridge/
├── bridge-server/       # Central WebSocket router
│   └── src/
│       ├── index.ts         # Entry point
│       ├── server.ts        # WS server, message routing
│       ├── bridge.ts        # Bridge data model
│       ├── bridge-manager.ts # Create/list/destroy bridges
│       └── client-session.ts # WS session tracking
├── discord-bot/         # Discord client
│   └── src/
│       ├── index.ts         # Bot entry, commands, main loop
│       ├── voice-manager.ts # Join/leave/receive/play audio
│       └── bridge-client.ts # WS client to bridge server
├── fluxy-bot/           # Fluxer client
│   └── src/
│       ├── index.ts         # Bot entry, commands, main loop
│       ├── fluxer-api.ts    # REST API client
│       ├── livekit-manager.ts # LiveKit room/track management
│       ├── audio-codec.ts   # Opus ↔ PCM16 conversion
│       └── bridge-client.ts # WS client to bridge server
├── shared/              # Shared types + protocol
│   └── src/
│       ├── index.ts
│       ├── types.ts         # All interfaces, message types
│       ├── protocol.ts      # Binary frame encode/decode
│       └── channel-mapper.ts # Channel name ↔ ID mapping
├── config/
│   └── default.json     # Default configuration
├── docs/
├── .env.example
├── package.json         # Workspace root
└── tsconfig.base.json
```

## WebSocket Protocol

### Frame types

**Text frames** carry JSON messages for control/commands:

```json
{ "type": "identify", "platform": "discord", "token": "..." }
{ "type": "identified", "platform": "discord", "sessionId": "abc-123" }
{ "type": "call:create", "sourceChannelId": "...", "sourceGuildId": "...", "targetChannelName": "Geral" }
{ "type": "call:create:response", "bridgeId": "...", "discord": {...}, "fluxy": {...}, "status": "active" }
{ "type": "call:hangup", "bridgeId": "..." }
{ "type": "error", "code": "...", "message": "..." }
```

**Binary frames** carry audio packets:

```
[4 bytes: JSON header length (BE)]
[JSON header: { "type":"audio:packet", "bridgeId":"...", "origin":"discord", "sequence":42, "timestamp":... }]
[Opus audio data]
```

### Message types

| Type | Direction | Payload |
|------|-----------|---------|
| `identify` | Client → Server | `{ platform, token }` |
| `identified` | Server → Client | `{ platform, sessionId }` |
| `calls:list` | Client → Server | — |
| `calls:list:response` | Server → Client | `{ channels: ChannelInfo[] }` |
| `call:create` | Client → Server | `{ sourceChannelId, sourceGuildId, targetChannelName }` |
| `call:create:response` | Server → Client | `{ bridgeId, discord, fluxy, status }` |
| `call:hangup` | Client → Server | `{ bridgeId }` |
| `call:hangup:response` | Server → Client | `{ bridgeId, success }` |
| `call:ended` | Server → Client | `{ bridgeId, reason }` |
| `audio:packet` | Bidirectional (binary) | `{ bridgeId, origin, sequence, timestamp }` + Opus |

## Fluxer API Integration

The Fluxy bot uses two mechanisms to join voice:

1. **REST API** — Get LiveKit token and update voice state
2. **LiveKit** — Connect to room, publish/subscribe audio

### Getting a Voice Token

```
POST /v1/channels/{channel_id}/voice/token
Authorization: Bot <token>
Body: { "channel_id": "...", "guild_id": "..." }

Response:
{
  "token": "eyJ...",          // LiveKit JWT
  "endpoint": "wss://voice-us-west.fluxer.app",
  "connection_id": "conn_...",
  "token_nonce": "550e..."
}
```

### Joining Voice

```
PATCH /v1/guilds/{guild_id}/voice-states/@me
Authorization: Bot <token>
Body: { "channel_id": "...", "self_mute": false, "self_deaf": false }
```

## Limitations

1. **Fluxer API beta** — The Fluxer platform is in beta; endpoints may change.
2. **LiveKit Node SDK** — `@livekit/rtc-node` uses native Rust FFI; requires build tools.
3. **No standalone Fluxer bot** — The Fluxy bot runs as a Node process, not a hosted bot.
4. **Single-process** — Each bot is a single process; no clustering yet.
5. **No persistence** — Bridge state and channel maps are in-memory only.
6. **Audio quality** — Opus at 48kHz stereo (configurable). Latency depends on network.

## Development

```bash
# Build all packages
npm run build

# Run each component in dev mode with hot reload
npm run dev:bridge
npm run dev:discord
npm run dev:fluxy
```

## License

MIT
