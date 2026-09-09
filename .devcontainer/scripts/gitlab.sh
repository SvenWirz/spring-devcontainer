#!/usr/bin/env bash
#
# GitLab-Integration für self-hosted Instanzen.
#
# Als Bibliothek (wird von clone-repos.sh eingebunden):
#   gitlab_host / gitlab_token / gitlab_api / gitlab_discover
#
# Als CLI:
#   devkit gitlab status        Verbindung, Token und Benutzer prüfen
#   devkit gitlab login         glab-Authentifizierung gegen die Instanz
#   devkit gitlab groups <pfad> Projekte einer Gruppe auflisten
#   devkit gitlab known-hosts   SSH-Hostkey der Instanz nach ~/.ssh/known_hosts
#   devkit gitlab registry      Docker-Login gegen die GitLab Container Registry

[ -n "${_DEVKIT_LIB_LOADED:-}" ] || source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# --- Ermittlung von Host und Token -----------------------------------------
# Reihenfolge: explizite Umgebungsvariable > gitlab.host aus repositories.yaml

gitlab_host() {
    local host="${GITLAB_HOST:-${DEVKIT_GIT_HOST:-}}"
    if [ -z "$host" ]; then
        local cfg="${DEVKIT_REPOS_CONFIG:-}"
        if [ -z "$cfg" ]; then
            if [ -f "$DEVKIT_CONFIG/repositories.local.yaml" ]; then
                cfg="$DEVKIT_CONFIG/repositories.local.yaml"
            else
                cfg="$DEVKIT_CONFIG/repositories.yaml"
            fi
        fi
        [ -f "$cfg" ] && host="$(yq -r '.gitlab.host // ""' "$cfg" 2>/dev/null)"
    fi
    host="${host#https://}"; host="${host#http://}"; host="${host%/}"
    printf '%s' "$host"
}

gitlab_token() {
    printf '%s' "${GITLAB_TOKEN:-${DEVKIT_GIT_TOKEN:-}}"
}

gitlab_base_url() {
    local host; host="$(gitlab_host)"
    [ -z "$host" ] && return 1
    printf 'https://%s' "$host"
}

# gitlab_api <pfad-mit-query>  ->  ein JSON-Objekt pro Zeile (paginiert)
gitlab_api() {
    local path="$1" base token page=1 body
    base="$(gitlab_base_url)" || { err "Kein GitLab-Host konfiguriert."; return 1; }
    token="$(gitlab_token)"
    local sep='?'; [[ "$path" == *"?"* ]] && sep='&'

    while :; do
        if [ -n "$token" ]; then
            body="$(curl -fsSL -H "PRIVATE-TOKEN: $token" \
                "${base}/api/v4/${path}${sep}per_page=100&page=${page}" 2>/dev/null)" || return 1
        else
            body="$(curl -fsSL \
                "${base}/api/v4/${path}${sep}per_page=100&page=${page}" 2>/dev/null)" || return 1
        fi
        [ -z "$body" ] && break
        local len; len="$(jq 'length' <<<"$body" 2>/dev/null || echo 0)"
        [ "$len" -eq 0 ] && break
        jq -c '.[]' <<<"$body"
        [ "$len" -lt 100 ] && break
        page=$((page + 1))
        [ "$page" -gt 50 ] && { warn "GitLab-API: Abbruch nach 50 Seiten."; break; }
    done
}

# URL-Encoding für Gruppenpfade (platform/services -> platform%2Fservices)
gitlab_urlencode() { jq -rn --arg v "$1" '$v|@uri'; }

# ---------------------------------------------------------------------------
# gitlab_discover <config-json>
#
# Löst den Abschnitt `gitlab.groups` aus repositories.yaml über die GitLab-API
# in konkrete Repository-Einträge auf und gibt sie als JSON-Array aus - im
# gleichen Format wie die statischen Einträge unter `repositories:`.
# ---------------------------------------------------------------------------
gitlab_discover() {
    local json="$1"
    local n; n="$(jq -r '(.gitlab.groups // []) | length' <<<"$json")"
    [ "$n" -eq 0 ] && { echo '[]'; return 0; }

    local host; host="$(gitlab_host)"
    if [ -z "$host" ]; then
        warn "gitlab.groups konfiguriert, aber kein Host gesetzt (gitlab.host oder GITLAB_HOST)."
        echo '[]'; return 0
    fi
    if [ -z "$(gitlab_token)" ]; then
        warn "Kein GITLAB_TOKEN gesetzt - es werden nur öffentliche Projekte gefunden."
    fi

    local protocol; protocol="$(jq -r '.gitlab.protocol // "https"' <<<"$json")"
    local out='[]' i

    for ((i = 0; i < n; i++)); do
        local g path subs archived strategy excludes
        g="$(jq -c ".gitlab.groups[$i]" <<<"$json")"
        # Kurzschreibweise: einfacher String statt Objekt
        if [ "$(jq -r 'type' <<<"$g")" = "string" ]; then
            path="$(jq -r '.' <<<"$g")"; g='{}'
        else
            path="$(jq -r '.path // ""' <<<"$g")"
        fi
        [ -z "$path" ] && { warn "gitlab.groups[$i]: 'path' fehlt."; continue; }

        subs="$(jq -r '.includeSubgroups // true' <<<"$g")"
        archived="$(jq -r '.archived // false' <<<"$g")"
        strategy="$(jq -r '.dirStrategy // "relative"' <<<"$g")"
        excludes="$(jq -c '.exclude // []' <<<"$g")"

        log "GitLab-Gruppe '$path' wird aufgelöst ..." >&2
        local query projects found=0
        query="groups/$(gitlab_urlencode "$path")/projects?include_subgroups=${subs}&archived=${archived}&order_by=path&sort=asc"
        projects="$(gitlab_api "$query")" || { err "Gruppe '$path' konnte nicht gelesen werden."; continue; }

        while IFS= read -r p; do
            [ -z "$p" ] && continue
            local pname pfull url dir skip=0 pat
            pname="$(jq -r '.path' <<<"$p")"
            pfull="$(jq -r '.path_with_namespace' <<<"$p")"
            if [ "$protocol" = "ssh" ]; then
                url="$(jq -r '.ssh_url_to_repo' <<<"$p")"
            else
                url="$(jq -r '.http_url_to_repo' <<<"$p")"
            fi

            case "$strategy" in
                flat) dir="$pname" ;;
                full) dir="$pfull" ;;
                *)    dir="${pfull#"$path"/}" ;;
            esac

            # exclude-Muster (Shell-Globs) gegen Projektpfad und -namen prüfen
            while IFS= read -r pat; do
                [ -z "$pat" ] && continue
                # shellcheck disable=SC2053
                if [[ "$pfull" == $pat || "$pname" == $pat ]]; then skip=1; break; fi
            done < <(jq -r '.[]' <<<"$excludes")
            [ "$skip" = "1" ] && continue

            local inherit
            inherit="$(jq -c '{branch, depth, updateOnStart, submodules, lfs} | with_entries(select(.value != null))' <<<"$g")"
            out="$(jq -c --arg name "$pname" --arg url "$url" --arg dir "$dir" \
                        --argjson inherit "$inherit" \
                        '. + [ {name: $name, url: $url, dir: $dir} + $inherit ]' <<<"$out")"
            found=$((found + 1))
        done <<<"$projects"

        detail "$found Projekt(e) in '$path' gefunden." >&2
    done

    printf '%s' "$out"
}

# --- SSH-Hostkey hinterlegen, damit `git clone` nicht interaktiv nachfragt ---
gitlab_known_hosts() {
    local host port; host="$(gitlab_host)"
    [ -z "$host" ] && { warn "Kein GitLab-Host konfiguriert."; return 0; }
    port="${GITLAB_SSH_PORT:-22}"
    install -d -m 700 "$HOME/.ssh"
    touch "$HOME/.ssh/known_hosts" && chmod 600 "$HOME/.ssh/known_hosts"
    if ssh-keygen -F "$host" >/dev/null 2>&1; then
        detail "SSH-Hostkey für $host bereits bekannt."
        return 0
    fi
    if ssh-keyscan -T 5 -p "$port" "$host" >> "$HOME/.ssh/known_hosts" 2>/dev/null \
       && ssh-keygen -F "$host" >/dev/null 2>&1; then
        ok "SSH-Hostkey von $host übernommen."
    else
        warn "SSH-Hostkey von $host nicht abrufbar (Netz bzw. Port $port prüfen)."
    fi
}

# --- CLI -------------------------------------------------------------------
gitlab_status() {
    local host token base me
    host="$(gitlab_host)"; token="$(gitlab_token)"
    section "GitLab"
    if [ -z "$host" ]; then
        err "Kein Host konfiguriert."
        detail "gitlab.host in repositories.yaml setzen oder GITLAB_HOST exportieren."
        return 1
    fi
    printf '  %-16s %s\n' "Host" "https://$host"
    printf '  %-16s %s\n' "Token" "$([ -n "$token" ] && echo gesetzt || echo 'nicht gesetzt')"

    base="$(gitlab_base_url)"
    if [ -n "$token" ]; then
        me="$(curl -fsSL -H "PRIVATE-TOKEN: $token" "$base/api/v4/user" 2>/dev/null)" || me=""
    else
        me=""
    fi
    if [ -n "$me" ] && [ -n "$(jq -r '.username // ""' <<<"$me")" ]; then
        printf '  %-16s %s (%s)\n' "Angemeldet als" \
            "$(jq -r '.username' <<<"$me")" "$(jq -r '.name' <<<"$me")"
    else
        warn "Keine authentifizierte API-Verbindung."
        detail "Token als GITLAB_TOKEN setzen; Scopes: read_api, read_repository, write_repository."
        detail "Bei TLS-Fehlern die Root-CA hinterlegen (README, Abschnitt 7 Root-CA)."
    fi
    printf '  %-16s %s\n' "glab" \
        "$(have glab && glab --version 2>/dev/null | head -n1 || echo 'nicht installiert')"
    printf '  %-16s %s\n' "Registry" "${GITLAB_REGISTRY:-registry.$host}"

    # Bewusst getrennt vom API-Token ausgewiesen: der API-Zugriff kann laengst
    # funktionieren, waehrend `git clone` noch nach Zugangsdaten fragt - git
    # liest keine Umgebungsvariablen, nur seine Credential-Helper.
    if git_can_auth "$host"; then
        printf '  %-16s %s\n' "Git-Zugang" "ok (Credential-Helper liefert Zugangsdaten)"
    else
        printf '  %-16s %s\n' "Git-Zugang" "FEHLT - git clone würde interaktiv nachfragen"
        detail "Beheben mit: devkit gitlab login"
    fi
}

gitlab_login() {
    local host token
    host="$(gitlab_host)"; token="$(gitlab_token)"
    [ -z "$host" ] && die "Kein GitLab-Host konfiguriert."
    have glab || die "glab ist nicht installiert (siehe Dockerfile, Abschnitt 7)."
    if [ -n "$token" ]; then
        printf '%s' "$token" | glab auth login --hostname "$host" --stdin
    else
        glab auth login --hostname "$host"
    fi
    glab auth status

    # glab anzumelden reicht NICHT zum Klonen: git kennt weder glab noch
    # GITLAB_TOKEN und benutzt ausschliesslich seine Credential-Helper.
    # Ohne den folgenden Schritt fragt `git clone` interaktiv nach Zugangsdaten.
    section "Git-Zugang für $host"
    if [ -n "$token" ]; then
        GITLAB_HOST="$host" GITLAB_TOKEN="$token" \
            bash "$(dirname "${BASH_SOURCE[0]}")/configure-git.sh" >/dev/null \
            && ok "git nutzt jetzt den Token für $host."
    else
        # Kein Token in der Umgebung - dann glab selbst als Helper eintragen.
        # Der Token bleibt so ausschliesslich in der glab-Konfiguration.
        git config --global --replace-all \
            "credential.https://${host}.helper" '!glab auth git-credential'
        ok "glab als Credential-Helper für $host eingetragen."
    fi

    if git_can_auth "$host"; then
        ok "Prüfung: git erhält Zugangsdaten für $host."
    else
        warn "git erhält trotzdem keine Zugangsdaten für $host."
        detail "Prüfen mit: git credential fill  (protocol=https, host=$host)"
    fi
}

gitlab_registry_login() {
    local host token registry
    host="$(gitlab_host)"; token="$(gitlab_token)"
    [ -z "$host" ] && die "Kein GitLab-Host konfiguriert."
    [ -z "$token" ] && die "GITLAB_TOKEN wird für den Registry-Login benötigt."
    registry="${GITLAB_REGISTRY:-registry.$host}"
    printf '%s' "$token" | docker login "$registry" \
        --username "${GITLAB_REGISTRY_USER:-${DEVKIT_GIT_TOKEN_USER:-oauth2}}" --password-stdin \
        && ok "Docker-Login gegen $registry erfolgreich."
}

# Direkter Aufruf (nicht als Bibliothek)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    set -uo pipefail
    case "${1:-status}" in
        status)      gitlab_status ;;
        login)       gitlab_login ;;
        registry)    gitlab_registry_login ;;
        known-hosts) gitlab_known_hosts ;;
        groups)
            [ -n "${2:-}" ] || die "Verwendung: devkit gitlab groups <gruppenpfad>"
            gitlab_api "groups/$(gitlab_urlencode "$2")/projects?include_subgroups=true" \
                | jq -r '"  " + .path_with_namespace + "   " + .http_url_to_repo'
            ;;
        *) die "Unbekannt: devkit gitlab ${1:-}" ;;
    esac
fi
