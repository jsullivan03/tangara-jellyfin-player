# Tangara Sync Server

The Tangara sync server converts Jellyfin audio items into device-specific manifests and proxies media downloads to Tangara devices.

## Requirements

Docker, Docker Compose, a running Jellyfin server, a Jellyfin API key, a Jellyfin user ID, and one or more Jellyfin audio item IDs are required.

## Configuration

Copy the example environment file:

    cp .env.example .env

Edit `.env` and provide values for:

- JELLYFIN_URL
- JELLYFIN_USER_ID
- TANGARA_ITEM_IDS
- TANGARA_SYNC_PORT

Place the Jellyfin API key in `.jellyfin-api-key` and restrict its permissions:

    chmod 600 .jellyfin-api-key

## Start

    docker compose -f docker-compose.example.yml up -d --build

## Endpoints

    GET /health
    GET /devices/<device-id>/manifest
    GET /devices/<device-id>/items/<jellyfin-id>/media

## Current limitations

Assigned tracks are configured with TANGARA_ITEM_IDS. Device assignments are not yet stored separately. Playlist and collection synchronization are not yet implemented. File deletion remains disabled in the firmware.
