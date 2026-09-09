#!/usr/bin/env bash
#
# Laedt lokale Werte (Token, Hostnamen, Signaturschluessel) aus einer nicht
# versionierten Datei im gemounteten config-Verzeichnis:
#
#     .devcontainer/config/devkit.local.env   ->   /opt/devkit/config/devkit.local.env
#
# Vorlage dafuer: devkit.env.example (liegt im Repository).
#
# Die Datei liegt auf dem Host und ueberlebt damit Container-Rebuilds - anders
# als alles, was nur in ~/ oder in einer einzelnen Shell gesetzt wird.
#
# Wird von lib.sh (alle devkit-Skripte) und von /etc/profile.d (interaktive
# Shells) eingebunden. Mehrfaches Einbinden ist unschaedlich.
#
# Bewusst kein `source` der Datei: sie wird zeilenweise geparst statt als Shell
# ausgefuehrt. Ein Token mit Sonderzeichen kann so nichts ausloesen, und ein
# Tippfehler beendet nicht das aufrufende Skript.

devkit_load_local_env() {
    local f="${DEVKIT_LOCAL_ENV:-${DEVKIT_CONFIG:-/opt/devkit/config}/devkit.local.env}"
    [ -f "$f" ] || return 0
    local line key val
    # tr entfernt CRLF - die Datei wird typischerweise unter Windows bearbeitet.
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[![:space:]]*}"}"        # fuehrende Leerzeichen
        [ -z "$line" ] && continue
        case "$line" in '#'*) continue ;; esac
        line="${line#export }"
        case "$line" in *=*) ;; *) continue ;; esac
        key="${line%%=*}"; val="${line#*=}"
        case "$key" in ''|*[!A-Za-z0-9_]*) continue ;; esac
        case "$val" in
            \"*\") val="${val#\"}"; val="${val%\"}" ;;
            \'*\') val="${val#\'}"; val="${val%\'}" ;;
        esac
        # Nur setzen, wenn nichts Sinnvolles gesetzt ist: remoteEnv reicht nicht
        # gesetzte Host-Variablen als leeren String durch, echte Host-Werte
        # sollen dagegen Vorrang behalten.
        if [ -z "${!key:-}" ]; then
            export "$key=$val"
        fi
    done < <(tr -d '\r' < "$f")
}

devkit_load_local_env
