# Voice Bridge — Discord ↔ Fluxer

Ponte de voz bidirecional em tempo real entre Discord e Fluxer.

Um comando só: `/canais` pra ver canais ativos da outra plataforma, `/conectar <ID>` pra entrar. Os bots conectam automaticamente, a bridge roteia o áudio.

## Arquitetura

```
┌──────────────┐     WebSocket      ┌──────────────┐     WebSocket      ┌──────────────┐
│  Discord Bot  │ ◄──────────────► │ Bridge Server │ ◄──────────────► │  Fluxy Bot   │
│  (discord.js  │     Opus/bin     │  (relay puro) │     Opus/bin     │ (LiveKit SDK) │
│   @discordjs/ │                   │               │                   │  Gateway WS   │
│   voice)      │                   │               │                   │  Fluxer REST  │
└──────┬───────┘                   └───────────────┘                   └──────┬───────┘
       │                                                                      │
       ▼                                                                      ▼
┌──────────────┐                                                   ┌──────────────┐
│ Discord Voice │                                                   │  Fluxy Voice  │
│   (Opus)      │                                                   │ (LiveKit/Opus)│
└──────────────┘                                                   └──────────────┘
```

### Componentes

| Componente | Função |
|-----------|--------|
| **bridge-server/** | Relay WebSocket. Encaminha mensagens JSON entre os bots. Roteia áudio Opus binário com origem. Gerencia ponte (criação/remoção). |
| **discord-bot/** | Discord.js + `@discordjs/voice`. Slash commands `/canais` e `/conectar`. Recebe Opus de usuários, encaminha pra bridge. Reproduz Opus recebido. |
| **fluxy-bot/** | Conexão Gateway Fluxer (eventos em tempo real) + REST API + LiveKit. Entra em call via opcode 4 (VOICE_STATE_UPDATE). Converte PCM stereo↔mono. |
| **shared/** | Tipos TypeScript, serialização de frame binário, channel mapper. |

## Pré-requisitos

- **Node.js** >= 20
- **npm** >= 9
- **Token de bot Discord** com intents `Guilds` + `GuildVoiceStates`
- **Token de bot Fluxer** ([portal do desenvolvedor](https://fluxer.app/developers))
- **Ferramentas de build C++** (para `@discordjs/opus` e `@livekit/rtc-node`)
  - Windows: Visual Studio Build Tools
  - macOS: `xcode-select --install`
  - Linux: `apt install build-essential python3`

## Quick Start

```bash
cd voice-bridge
cp .env.example .env   # edite com seus tokens
npm install
npm run build
```

**Rodar tudo (1 terminal):**
```bash
npm run start:all
```

Ou cada componente separado:
```bash
npm run start:bridge   # terminal 1
npm run start:discord  # terminal 2
npm run start:fluxy    # terminal 3
```

## Comandos

### Discord (Slash Commands)

| Comando | Descrição |
|---------|-----------|
| `/canais` | Lista canais de voz **ativos no Fluxy** com IDs reais |
| `/conectar <ID>` | Conecta ao canal do Fluxy — detecta automaticamente onde você está |

### Fluxy (em canais de texto)

| Comando | Descrição |
|---------|-----------|
| `!canais` | Lista canais de voz **ativos no Discord** com IDs reais |
| `!conectar <ID>` | Conecta ao canal do Discord — detecta automaticamente onde você está |

### Fluxo de uso

```
!canais
  → 🎤 Canais ativos no Discord
    **Geral**
    ID: `138472394827349827`
    Usuários: 5

!conectar 138472394827349827
  → 🔊 Conectando Geral (Fluxy) → `138472394827349827` (Discord)
  → ✅ Ponte ativa, áudio nos dois sentidos
```

## Fluxo de Áudio

### Discord → Fluxy

```
Usuário fala no Discord
  → @discordjs/voice VoiceReceiver captura Opus packet
  → discord-bot envia frame binário (header JSON + Opus) via WS
  → bridge-server verifica origem (echo prevention), encaminha
  → fluxy-bot recebe, decodifica Opus → PCM mono 48kHz
  → stereoToMono? Não, PCM já está mono (Discord → Opus mono)
  → monoStereo() duplica para PCM stereo 48kHz
  → AudioSource.captureFrame → LiveKit publica
  → Usuários do Fluxy ouvem
```

### Fluxy → Discord

```
Usuário fala no Fluxy
  → LiveKit AudioStream → frameReceived event
  → PCM stereo 48kHz frame (cópia correta com byteLength exato)
  → stereoToMono() soma L+R → PCM mono 48kHz
  → OpusEncoder.encode() → Opus packet
  → fluxy-bot envia frame binário via WS
  → bridge-server encaminha
  → discord-bot recebe, feedAudio() → FeedableOpusStream
  → AudioPlayer reproduz no canal Discord
```

## Pipeline de Áudio (Detalhado)

| Etapa | Formato | Plataforma |
|-------|---------|------------|
| Captura Discord | Opus packet (mono, 48kHz, 960 samples) | Discord |
| Transporte WS | Opus binário encapsulado (header JSON + payload) | Bridge |
| Recepção Fluxy | Opus → decode → PCM mono 48kHz | Fluxy |
| Conversão | mono → stereo (duplica canal) | Fluxy |
| Publicação LiveKit | AudioFrame (stereo, 48kHz, 20ms frames) | Fluxy |
| Captura LiveKit | AudioFrame (stereo, 48kHz, samplesPerChannel) | Fluxy |
| Conversão | stereo → mono (soma L+R com saturação) | Fluxy |
| Codificação | PCM mono → Opus (mono, 48kHz, 960 samples) | Fluxy |
| Transporte WS | Opus binário (mesmo formato) | Bridge |
| Recepção Discord | Opus → FeedableOpusStream → AudioPlayer | Discord |

### Sincronização

- Jitter buffer: mantém ~5 pacotes (100ms), descarta metade se >50 (1s)
- Pacotes de 20ms a 48kHz (960 samples/frame)
- Opus encapsulado, sem re-codificação na bridge

## Echo Prevention

Cada frame tem `origin: 'discord'` ou `'fluxy'`. A bridge nunca encaminha áudio de volta pra plataforma de origem. O consumo (bot) também confere.

## Múltiplas Pontes

N pontes simultâneas, cada uma independente. Um canal só pode participar de uma ponte por vez (controle de duplicidade no bridge server).

## Projeto

```
voice-bridge/
├── bridge-server/src/       # Relay WS central
│   ├── index.ts             # Entry
│   ├── server.ts            # Conexões, roteamento, bridge lifecycle
│   ├── bridge.ts            # Modelo de dados da ponte
│   ├── bridge-manager.ts    # CRUD de pontes
│   └── client-session.ts    # Sessão WebSocket
├── discord-bot/src/         # Bot Discord
│   ├── index.ts             # Slash commands, handlers, audio relay
│   ├── voice-manager.ts     # Join/leave/receive/play + jitter buffer
│   └── bridge-client.ts     # WS client
├── fluxy-bot/src/           # Bot Fluxer
│   ├── index.ts             # Comandos, auto-join, audio relay
│   ├── fluxer-api.ts        # REST API client
│   ├── livekit-manager.ts   # LiveKit room, tracks, AudioStream
│   ├── audio-codec.ts       # Opus ↔ PCM, stereo↔mono
│   ├── bridge-client.ts     # WS client
│   └── gateway.ts           # Gateway WS (eventos, voz opcode 4)
├── shared/src/              # Tipos + utilidades
│   ├── types.ts             # Protocolo de mensagens
│   ├── protocol.ts          # Serialização binária
│   └── channel-mapper.ts    # Mapeamento de canais
├── config/default.json
├── .env.example
└── package.json             # Workspaces
```

## Protocolo WebSocket

### Text frames (comandos)

```
→ { type: 'identify', platform: 'discord', token: '...' }
← { type: 'identified', sessionId: 'uuid' }

→ { type: 'get:channels' }
→ { type: 'get:channels:response', channels: [{ id, name, userCount, guildId }] }

→ { type: 'connect:bridge', sourcePlatform: 'discord', discordChannelId: '...', fluxyChannelId: '...', ... }
← { type: 'bridge:created', bridgeId, role: 'source'|'target', channelId, guildId }

→ { type: 'disconnect:bridge', bridgeId }
← { type: 'bridge:ended', bridgeId, reason }
```

### Binary frames (áudio)

```
[4 bytes: header JSON length (BE)]
[JSON header: { type:'audio:packet', bridgeId, origin, sequence, timestamp }]
[Opus payload]
```

## Integração Fluxer

### Entrada em canal de voz

1. Bot envia opcode 4 (VOICE_STATE_UPDATE) via Gateway WebSocket:
   ```json
   { "op": 4, "d": { "guild_id": "...", "channel_id": "...", "self_mute": false, "self_deaf": false } }
   ```
2. Gateway responde com `VOICE_SERVER_UPDATE` contendo `token` e `endpoint` LiveKit
3. Bot conecta no LiveKit Room com essas credenciais
4. Publica track de áudio (AudioSource → LocalAudioTrack)
5. Escuta `frameReceived` de tracks remotas → encaminha pra bridge

### API REST

| Endpoint | Uso |
|----------|-----|
| `GET /v1/users/@me` | Verificar token |
| `GET /v1/users/@me/guilds` | Listar servidores |
| `GET /v1/guilds/{id}/channels` | Listar canais de voz |
| `GET /v1/guilds/{id}/voice-states` | Ver quem está em call |
| `POST /v1/channels/{id}/messages` | Responder comandos |
| `GET /v1/gateway/bot` | Obter URL do Gateway |

## Problemas Conhecidos

- **Buffer FFI compartilhado**: `AudioFrame.data.buffer` retorna o backing store do Rust (64KB+). Sempre copiar com `byteOffset` e `byteLength` corretos.
- **Stereo vs Mono**: LiveKit entrega PCM stereo. Discord usa mono. Conversão obrigatória em ambos os sentidos.
- **Latência**: Jitter buffer descarta pacotes quando acumula >50 (~1s). Se persistir, reduzir teto.
- **LiveKit nativo**: `@livekit/rtc-node` usa Rust FFI — requer toolchain C++.

## Licença

MIT
