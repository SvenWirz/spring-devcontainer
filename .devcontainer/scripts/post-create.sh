#!/usr/bin/env bash
#
# Läuft einmalig, nachdem der Container erstellt wurde.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

printf '\n%s' "$_c_blue"
cat <<'BANNER'
  ____              _  ___ _
 |  _ \  _____   __| |/ (_) |_    Java 21 · Spring Boot · OpenCode
 | | | |/ _ \ \ / /| ' /| | __|
 | |_| |  __/\ V / | . \| | |_
 |____/ \___| \_/  |_|\_\_|\__|
BANNER
printf '%s\n' "$_c_reset"

# `devkit` als globalen Befehl verfügbar machen.
as_root ln -sfn "$SCRIPT_DIR/devkit.sh" /usr/local/bin/devkit
as_root chmod +x "$SCRIPT_DIR"/*.sh 2>/dev/null || true

bash "$SCRIPT_DIR/install-ca-certs.sh" || warn "Root-CA konnte nicht vollstaendig installiert werden."
bash "$SCRIPT_DIR/configure-git.sh"       || warn "Git-Konfiguration unvollstaendig."
bash "$SCRIPT_DIR/link-configs.sh"        || warn "Config-Verknuepfung unvollstaendig."
bash "$SCRIPT_DIR/clone-repos.sh" sync || warn "Nicht alle Repositories konnten geklont werden."

bash "$SCRIPT_DIR/devkit.sh" doctor || true

section "Bereit"
cat <<'HINTS'
  devkit doctor        Umgebung prüfen (JDK, Gradle, OpenCode, Docker, CA)
  devkit repos sync    fehlende Repositories nach /src klonen
  devkit repos update  alle Repositories aktualisieren
  devkit repos list    Status der konfigurierten Repositories
  devkit certs install Root-CA erneut einlesen (nach Änderung in certs/)
  devkit gitlab status Verbindung zur self-hosted GitLab-Instanz prüfen
  opencode             AI-Agent im aktuellen Verzeichnis starten

  Quellcode liegt im persistenten Volume unter /src.
  Setup und Konfiguration: /workspaces/devkit/.devcontainer
HINTS
printf '\n'
