#!/bin/bash
# Start all three components in separate terminals
# Requires: Windows (Git Bash) or WSL

echo "Starting Voice Bridge..."
echo ""

# Load .env
export $(grep -v '^#' .env | xargs)

# Start bridge server
echo "Starting bridge server on port $BRIDGE_PORT..."
npx tsx bridge-server/src/index.ts &
BRIDGE_PID=$!

sleep 2

# Start discord bot
echo "Starting Discord bot..."
npx tsx discord-bot/src/index.ts &
DISCORD_PID=$!

sleep 1

# Start fluxy bot
echo "Starting Fluxy bot..."
npx tsx fluxy-bot/src/index.ts &
FLUXY_PID=$!

echo ""
echo "All components started."
echo "  Bridge:  $BRIDGE_PID"
echo "  Discord: $DISCORD_PID"
echo "  Fluxy:   $FLUXY_PID"
echo ""
echo "Press Ctrl+C to stop all"

trap "kill $BRIDGE_PID $DISCORD_PID $FLUXY_PID 2>/dev/null; exit" SIGINT SIGTERM
wait
