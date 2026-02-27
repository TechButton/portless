#!/usr/bin/env bash
# App catalog: Plex
APP_NAME="plex"
APP_DESCRIPTION="Plex Media Server — stream your media library to any device"
APP_CATEGORY="media"
APP_PORT_VAR="PLEX_PORT"
APP_DEFAULT_HOST_PORT="32400"
APP_SERVICE_PORT="32400"
APP_DEFAULT_SUBDOMAIN="plex"
APP_AUTH="none"
APP_PROFILES="media,all"
APP_IMAGE="lscr.io/linuxserver/plex:latest"
APP_COMPOSE_FILE="compose/{HOSTNAME}/plex.yml"
APP_APPDATA_DIR="appdata/plex"
APP_REQUIRES_VOLUMES="appdata,data"
# Plex uses its own auth — no middleware needed
APP_NOTES="Plex has built-in authentication. No Traefik auth middleware is applied."
