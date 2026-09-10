#!/usr/bin/env bash
#
# Klont bzw. aktualisiert die in repositories.yaml deklarierten Repositories
# im persistenten Volume ($DEVKIT_WORKSPACE, default /src).
#
#   clone-repos.sh sync     nur fehlende Repositories klonen (default)
#   clone-repos.sh update   zusätzlich vorhandene Repositories aktualisieren
#   clone-repos.sh list     Übersicht anzeigen, nichts verändern
#
# Fehler bei einzelnen Repositories brechen den Lauf nicht ab; am Ende gibt es
# eine Zusammenfassung und einen Exit-Code != 0, falls etwas fehlschlug.

set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=gitlab.sh
source "$(dirname "${BASH_SOURCE[0]}")/gitlab.sh"

MODE="${1:-sync}"
ROOT="$DEVKIT_WORKSPACE"

# repositories.local.yaml hat Vorrang und ist per .gitignore ausgeschlossen.
# Damit bleiben interne Hostnamen und Gruppenpfade aus dem Repository heraus,
# waehrend repositories.yaml als committete Vorlage dient.
CONFIG="${DEVKIT_REPOS_CONFIG:-}"
if [ -z "$CONFIG" ]; then
    if [ -f "$DEVKIT_CONFIG/repositories.local.yaml" ]; then
        CONFIG="$DEVKIT_CONFIG/repositories.local.yaml"
    else
        CONFIG="$DEVKIT_CONFIG/repositories.yaml"
    fi
fi

case "$MODE" in
    sync|update|list) ;;
    *) die "Unbekannter Modus '$MODE' (erlaubt: sync, update, list)" ;;
esac

# Fehlen Zugangsdaten, fragt git interaktiv nach Benutzername und Passwort.
# Im postStart-Hook blockiert das den Container-Start auf unbestimmte Zeit.
# Deshalb: schnell scheitern und im Fehlerfall sagen, was zu tun ist.
# Zum bewussten Abschalten: DEVKIT_GIT_TERMINAL_PROMPT=1
export GIT_TERMINAL_PROMPT="${DEVKIT_GIT_TERMINAL_PROMPT:-0}"

section "Repositories ($MODE)"

[ -f "$CONFIG" ] || { warn "Keine Repository-Konfiguration unter $CONFIG - übersprungen."; exit 0; }
have yq || die "yq nicht gefunden - wird für das Parsen von $CONFIG benötigt."
have jq || die "jq nicht gefunden - wird für das Parsen von $CONFIG benötigt."

json="$(yq -o=json '.' "$CONFIG")" || die "$CONFIG ist kein gültiges YAML."

# --- Defaults aus der Konfiguration ---------------------------------------
d_base="$(jq -r '.defaults.baseUrl // ""'          <<<"$json")"
d_branch="$(jq -r '.defaults.branch // ""'         <<<"$json")"
d_depth="$(jq -r '.defaults.depth // 0'            <<<"$json")"
d_update="$(jq -r '.defaults.updateOnStart // false' <<<"$json")"
d_subs="$(jq -r '.defaults.submodules // false'    <<<"$json")"
d_lfs="$(jq -r '.defaults.lfs // false'            <<<"$json")"

# --- GitLab-Gruppen auflösen und mit der statischen Liste zusammenführen ---
# Statische Einträge haben Vorrang: bei gleichem Zielverzeichnis gewinnt der
# handgepflegte Eintrag aus `repositories:`.
discovered="$(gitlab_discover "$json")"
if [ "$(jq 'length' <<<"$discovered")" -gt 0 ]; then
    json="$(jq -c --argjson d "$discovered" '
        .repositories = ((.repositories // []) + $d)
        | .repositories |= (
            map(. + {_key: (.dir // .name // .url)})
            | group_by(._key) | map(.[0] | del(._key))
          )' <<<"$json")"
fi

total="$(jq -r '(.repositories // []) | length' <<<"$json")"
if [ "$total" -eq 0 ]; then
    # Unterscheiden: gar nichts konfiguriert vs. Gruppenaufloesung fehlgeschlagen.
    # Beides mit derselben Meldung zu quittieren, schickt einen bei einem
    # Netzproblem auf die Suche nach einem Konfigurationsfehler.
    if [ "$(jq -r '(.gitlab.groups // []) | length' <<<"$json")" -gt 0 ]; then
        err "Gruppen sind konfiguriert, aber es wurde kein Projekt aufgelöst."
        detail "Verbindung prüfen: devkit gitlab status"
        detail "Danach erneut: devkit repos sync"
        exit 1
    fi
    log "In $CONFIG ist kein Repository eingetragen."
    detail "Repositories unter 'repositories:' ergänzen und 'devkit repos sync' ausführen."
    exit 0
fi

mkdir -p "$ROOT" 2>/dev/null || as_root install -d -o "$(id -u)" -g "$(id -g)" -m 0755 "$ROOT"

cloned=0; updated=0; skipped=0; failed=0
failed_names=()

for i in $(seq 0 $((total - 1))); do
    entry="$(jq -c ".repositories[$i]" <<<"$json")"

    name="$(jq -r '.name // ""' <<<"$entry")"
    url="$(jq -r '.url // ""' <<<"$entry")"
    dir="$(jq -r '.dir // ""' <<<"$entry")"
    branch="$(jq -r ".branch // \"$d_branch\"" <<<"$entry")"
    depth="$(jq -r ".depth // $d_depth" <<<"$entry")"
    upd="$(jq -r ".updateOnStart // $d_update" <<<"$entry")"
    subs="$(jq -r ".submodules // $d_subs" <<<"$entry")"
    lfs="$(jq -r ".lfs // $d_lfs" <<<"$entry")"
    post="$(jq -r '.postClone // ""' <<<"$entry")"

    # Relative URLs gegen defaults.baseUrl auflösen.
    if [ -n "$url" ] && [ -n "$d_base" ] && [[ "$url" != *://* ]] && [[ "$url" != *@*:* ]]; then
        url="${d_base%/}/$url"
    fi
    # Platzhalter wie ${DEVKIT_GIT_TOKEN} in der URL ersetzen.
    url="$(printf '%s' "$url" | envsubst)"

    [ -z "$name" ] && name="$(basename "${url%.git}")"
    [ -z "$dir" ] && dir="$name"
    target="$ROOT/$dir"

    if [ -z "$url" ]; then
        err "Eintrag #$i ($name): keine 'url' gesetzt."
        failed=$((failed + 1)); failed_names+=("$name"); continue
    fi

    # --- list ---------------------------------------------------------------
    if [ "$MODE" = "list" ]; then
        if [ -d "$target/.git" ]; then
            cur="$(git -C "$target" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
            dirty=""; [ -n "$(git -C "$target" status --porcelain 2>/dev/null)" ] && dirty="*"
            printf '  %-34s %-20s %s\n' "$dir" "[${cur}${dirty}]" "$url"
        else
            printf '  %-34s %-20s %s\n' "$dir" "[fehlt]" "$url"
        fi
        continue
    fi

    # --- vorhandenes Repository --------------------------------------------
    if [ -d "$target/.git" ]; then
        if [ "$MODE" = "update" ] || [ "$upd" = "true" ]; then
            log "Aktualisiere $dir"
            if git -C "$target" fetch --all --prune --quiet; then
                if [ -z "$(git -C "$target" status --porcelain)" ]; then
                    git -C "$target" pull --ff-only --quiet 2>/dev/null \
                        || detail "$dir: kein Fast-Forward möglich - nur gefetcht."
                else
                    detail "$dir: lokale Änderungen vorhanden - nur gefetcht."
                fi
                updated=$((updated + 1))
            else
                err "$dir: fetch fehlgeschlagen."
                failed=$((failed + 1)); failed_names+=("$dir")
            fi
        else
            skipped=$((skipped + 1))
        fi
        continue
    fi

    if [ -e "$target" ] && [ -n "$(ls -A "$target" 2>/dev/null)" ]; then
        warn "$target existiert und ist kein Git-Repository - übersprungen."
        skipped=$((skipped + 1)); continue
    fi

    # --- neu klonen ---------------------------------------------------------
    args=(clone --quiet)
    [ -n "$branch" ] && args+=(--branch "$branch")
    if [ -n "$depth" ] && [ "$depth" != "0" ] && [ "$depth" != "null" ]; then
        args+=(--depth "$depth" --no-single-branch)
    fi
    [ "$subs" = "true" ] && args+=(--recurse-submodules)

    log "Klone $dir${branch:+ (Branch: $branch)}"
    mkdir -p "$(dirname "$target")"
    if git "${args[@]}" "$url" "$target"; then
        cloned=$((cloned + 1))
        [ "$lfs" = "true" ] && git -C "$target" lfs pull >/dev/null 2>&1
        if [ -n "$post" ]; then
            detail "postClone: $post"
            ( cd "$target" && bash -lc "$post" ) || warn "$dir: postClone-Kommando fehlgeschlagen."
        fi
    else
        err "$dir: clone von $url fehlgeschlagen."
        # Haeufigste Ursache bei HTTPS: git findet keine Zugangsdaten. Ein
        # gueltiger GITLAB_TOKEN in der Umgebung hilft git nicht - es liest
        # ausschliesslich seine Credential-Helper.
        if [[ "$url" == http://* || "$url" == https://* ]]; then
            proto="${url%%://*}"
            host="${url#*://}"; host="${host%%/*}"; host="${host#*@}"
            if ! git_can_auth "$host" "$proto"; then
                detail "git hat keine Zugangsdaten für $host."
                detail "Beheben mit: devkit gitlab login"
            fi
        fi
        rmdir "$target" 2>/dev/null || true
        failed=$((failed + 1)); failed_names+=("$dir")
    fi
done

[ "$MODE" = "list" ] && exit 0

printf '\n'
ok "geklont: $cloned | aktualisiert: $updated | unverändert: $skipped | fehlgeschlagen: $failed"
if [ "$failed" -gt 0 ]; then
    detail "Fehlgeschlagen: ${failed_names[*]}"
    detail "Bei privaten Repos Zugangsdaten prüfen (siehe README, Abschnitt 'Git-Zugang')."
    exit 1
fi
