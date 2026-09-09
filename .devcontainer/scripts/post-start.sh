#!/usr/bin/env bash
#
# Läuft bei jedem Container-Start (auch nach `docker start`).
# Bewusst idempotent und tolerant: ein Fehler hier darf den Start nicht
# blockieren, sonst verbindet sich die IDE nicht mehr.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# Volume-Eigentümer korrigieren, falls das Volume von außen angelegt wurde.
if [ -d "$DEVKIT_WORKSPACE" ] && [ ! -w "$DEVKIT_WORKSPACE" ]; then
    as_root chown "$(id -u):$(id -g)" "$DEVKIT_WORKSPACE" || true
fi

# Neu hinzugefügte Zertifikate übernehmen (idempotent).
bash "$SCRIPT_DIR/install-ca-certs.sh" || warn "CA-Installation fehlgeschlagen."

# Config-Links erneuern (Mount-Inhalt kann sich geändert haben).
bash "$SCRIPT_DIR/link-configs.sh" >/dev/null || warn "Config-Verknüpfung fehlgeschlagen."

# Neu eingetragene Repositories nachziehen; vorhandene bleiben unberührt,
# sofern sie nicht updateOnStart: true gesetzt haben.
if [ "${DEVKIT_SYNC_ON_START:-true}" = "true" ]; then
    bash "$SCRIPT_DIR/clone-repos.sh" sync || warn "Repository-Sync mit Fehlern beendet."
fi

exit 0
