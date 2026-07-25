# Tangara Sync Server

The Tangara sync server links individual Tangara devices to Jellyfin users, reads their playlists and favorites, generates device-specific download manifests, and proxies media downloads.

## Requirements

Docker, Docker Compose, a running Jellyfin server, a Jellyfin API key, and a Jellyfin fallback user ID are required.

## Configuration

Copy the example environment file:

    cp .env.example .env

Edit `.env` and provide values for:

- JELLYFIN_URL
- JELLYFIN_USER_ID
- TANGARA_SYNC_PORT
- PUID
- PGID

Place the Jellyfin API key in `.jellyfin-api-key` and restrict its permissions:

    chmod 600 .jellyfin-api-key

## Start

    docker compose -f docker-compose.example.yml up -d --build

## Jellyfin account linking

Begin account linking:

    POST /devices/<device-id>/link/start

Poll until the user approves the Quick Connect code:

    GET /devices/<device-id>/link/status

The Jellyfin token remains on the sync server and is never returned to the device.

## Sync sources

List the linked user's playlists and favorites:

    GET /devices/<device-id>/sync/sources

Read the device's selected sync sources:

    GET /devices/<device-id>/sync/preferences

Replace the selected sync sources:

    PUT /devices/<device-id>/sync/preferences

The request body is:

    {"favorites":false,"playlists":["playlist-id"]}

## Device endpoints

    GET /health
    GET /devices/<device-id>/manifest
    GET /devices/<device-id>/items/<jellyfin-id>/media

Linked devices generate manifests from their selected Jellyfin playlists and favorites. Duplicate tracks are included once. Removing a track from a selected source changes the manifest, but firmware file deletion remains disabled.
