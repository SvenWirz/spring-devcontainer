#!/usr/bin/env bash
#
# Konfiguriert den inneren Docker-Daemon (Docker-in-Docker).
#
# Typischer Grund im Firmennetz: Pulls gegen Docker Hub laufen in Rate-Limits
# oder werden vom Proxy blockiert. Ein Pull-Through-Cache (Nexus, Artifactory,
# Harbor) als registry-mirror loest das fuer alle `docker pull`-Aufrufe.
#
#   Quelle: $DEVKIT_CONFIG/docker/daemon.json   (read-only gemountet, optional)
#   Ziel:   /etc/docker/daemon.json             (gemergt mit dem, was das
#                                                docker-in-docker-Feature setzt)
#
# registry-mirrors und insecure-registries sind zur Laufzeit nachladbar - ein
# SIGHUP an dockerd genuegt. Andere Schluessel (z. B. data-root) werden erst
# nach einem Container-Neustart wirksam.

set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SRC="${DEVKIT_DOCKER_CONFIG:-$DEVKIT_CONFIG/docker/daemon.json}"
DST=/etc/docker/daemon.json

section "Docker-Daemon"

if [ ! -f "$SRC" ]; then
    log "Keine daemon.json gemountet - Docker laeuft mit Standardkonfiguration."
    detail "Vorlage: .devcontainer/config/docker/daemon.json.example"
    exit 0
fi

if ! jq -e . "$SRC" >/dev/null 2>&1; then
    err "$SRC ist kein gueltiges JSON - uebersprungen."
    exit 1
fi

current='{}'
if [ -f "$DST" ]; then
    current="$(as_root cat "$DST" 2>/dev/null)" || current='{}'
    jq -e . <<<"$current" >/dev/null 2>&1 || current='{}'
fi

# Unsere Werte gewinnen gegenueber dem, was das Feature vorgibt.
merged="$(jq -s '.[0] * .[1]' <(printf '%s' "$current") "$SRC")" || {
    err "daemon.json konnte nicht zusammengefuehrt werden."
    exit 1
}

if [ "$(jq -S . <<<"$merged")" = "$(jq -S . <<<"$current")" ]; then
    detail "Konfiguration bereits aktuell."
else
    # /etc/docker existiert nicht zwangslaeufig: dockerd laeuft auch ohne
    # daemon.json, und weder das Basis-Image noch das Feature legen den Ordner an.
    as_root install -d -m 0755 "$(dirname "$DST")"

    if ! printf '%s\n' "$merged" | as_root tee "$DST" >/dev/null; then
        err "$DST konnte nicht geschrieben werden."
        exit 1
    fi
    as_root chmod 0644 "$DST"

    # Zurueckgelesen pruefen - ein stiller Schreibfehler wuerde sonst als
    # Erfolg durchgehen und der Mirror waere wirkungslos.
    if ! as_root cat "$DST" | jq -e . >/dev/null 2>&1; then
        err "$DST ist nach dem Schreiben nicht lesbar oder kein gueltiges JSON."
        exit 1
    fi
    ok "$DST aktualisiert."

    if pgrep -x dockerd >/dev/null 2>&1; then
        if as_root pkill -HUP -x dockerd; then
            ok "dockerd neu geladen (SIGHUP)."
        else
            warn "SIGHUP an dockerd fehlgeschlagen - Container neu starten."
        fi
    else
        detail "dockerd laeuft noch nicht - Konfiguration greift beim Start."
    fi
fi

mirrors="$(jq -r '."registry-mirrors" // [] | join(", ")' <<<"$merged")"
[ -n "$mirrors" ] && detail "Registry-Mirror: $mirrors"
insecure="$(jq -r '."insecure-registries" // [] | join(", ")' <<<"$merged")"
[ -n "$insecure" ] && detail "Insecure-Registries: $insecure"

exit 0
