#!/usr/bin/env bash
#
# Verknüpft die read-only gemountete Konfiguration mit den Verzeichnissen, in
# denen Gradle und OpenCode sie erwarten.
#
#   $DEVKIT_CONFIG/gradle/gradle.properties  ->  $GRADLE_USER_HOME/gradle.properties
#   $DEVKIT_CONFIG/gradle/init.d/*.gradle[.kts] -> $GRADLE_USER_HOME/init.d/
#   $DEVKIT_CONFIG/opencode/opencode.json    ->  ~/.config/opencode/opencode.json
#   $DEVKIT_CONFIG/opencode/AGENTS.md        ->  ~/.config/opencode/AGENTS.md
#
# Es werden Symlinks gesetzt: Änderungen auf dem Host wirken sofort, ohne
# Container-Neustart. Die eigentlichen Caches (~/.gradle, ~/.local/share/opencode)
# liegen weiterhin auf beschreibbaren Volumes.

set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

section "Konfiguration verknüpfen"

link() { # link <quelle> <ziel>
    local src="$1" dst="$2"
    [ -e "$src" ] || return 1
    install -d "$(dirname "$dst")"
    ln -sfn "$src" "$dst"
    detail "$dst -> $src"
}

# --- Gradle ----------------------------------------------------------------
GRADLE_USER_HOME="${GRADLE_USER_HOME:-$HOME/.gradle}"
install -d "$GRADLE_USER_HOME/init.d"

if link "$DEVKIT_CONFIG/gradle/gradle.properties" "$GRADLE_USER_HOME/gradle.properties"; then
    ok "Gradle: gradle.properties eingebunden."
else
    log "Gradle: keine gradle.properties gemountet (optional)."
    detail "Vorlage: .devcontainer/config/gradle/gradle.properties.example"
fi

# Verwaiste Links aus früheren Läufen entfernen, dann neu setzen.
find "$GRADLE_USER_HOME/init.d" -maxdepth 1 -xtype l -delete 2>/dev/null || true
init_count=0
if [ -d "$DEVKIT_CONFIG/gradle/init.d" ]; then
    shopt -s nullglob
    for f in "$DEVKIT_CONFIG"/gradle/init.d/*.gradle "$DEVKIT_CONFIG"/gradle/init.d/*.gradle.kts; do
        link "$f" "$GRADLE_USER_HOME/init.d/$(basename "$f")" && init_count=$((init_count + 1))
    done
    shopt -u nullglob
fi
[ "$init_count" -gt 0 ] && ok "Gradle: $init_count Init-Skript(e) in init.d/ aktiv."

# --- OpenCode --------------------------------------------------------------
OC_CONFIG_DIR="$HOME/.config/opencode"
install -d "$OC_CONFIG_DIR" "$HOME/.local/share/opencode"

if link "$DEVKIT_CONFIG/opencode/opencode.json" "$OC_CONFIG_DIR/opencode.json"; then
    ok "OpenCode: opencode.json eingebunden."
else
    warn "OpenCode: keine opencode.json unter $DEVKIT_CONFIG/opencode gefunden."
    # OPENCODE_CONFIG darf nicht auf eine fehlende Datei zeigen.
    unset OPENCODE_CONFIG || true
fi

link "$DEVKIT_CONFIG/opencode/AGENTS.md" "$OC_CONFIG_DIR/AGENTS.md" >/dev/null 2>&1 \
    && ok "OpenCode: globale AGENTS.md eingebunden."

# --- Testcontainers --------------------------------------------------------
# Bewusst kopiert statt verlinkt: Testcontainers schreibt selbst in die Datei
# (z. B. die erkannte Docker-Client-Strategie), das ginge auf einem read-only
# Mount schief.
TC_SRC="$DEVKIT_CONFIG/testcontainers/testcontainers.properties"
if [ -f "$TC_SRC" ]; then
    install -m 0644 "$TC_SRC" "$HOME/.testcontainers.properties"
    ok "Testcontainers: ~/.testcontainers.properties aktualisiert."
    prefix="$(grep -E '^hub.image.name.prefix=' "$TC_SRC" | cut -d= -f2- || true)"
    [ -n "$prefix" ] && detail "Image-Praefix: $prefix"
else
    log "Testcontainers: keine Konfiguration gemountet (optional)."
fi

# Weitere optionale Dateien (Agents, Commands, MCP-Definitionen) durchreichen.
for extra in agent command plugin; do
    if [ -d "$DEVKIT_CONFIG/opencode/$extra" ]; then
        link "$DEVKIT_CONFIG/opencode/$extra" "$OC_CONFIG_DIR/$extra"
    fi
done

exit 0
