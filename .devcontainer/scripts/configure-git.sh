#!/usr/bin/env bash
#
# Richtet Git im Container ein: Identität, Sicherheitsausnahmen für die
# Volume-Pfade und optional HTTPS-Zugangsdaten oder SSH-Keys vom Host.
#
# Alle Werte sind optional; nicht gesetzte Variablen werden ignoriert.

set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=gitlab.sh
source "$(dirname "${BASH_SOURCE[0]}")/gitlab.sh"

section "Git-Konfiguration"

# Repos im Volume gehören ggf. einer anderen UID - Git sonst: "dubious ownership".
git config --global --replace-all safe.directory '*'
git config --global init.defaultBranch main

if is_set "${DEVKIT_GIT_USER_NAME:-}"; then
    git config --global user.name "$DEVKIT_GIT_USER_NAME"
    detail "user.name  = $DEVKIT_GIT_USER_NAME"
fi
if is_set "${DEVKIT_GIT_USER_EMAIL:-}"; then
    git config --global user.email "$DEVKIT_GIT_USER_EMAIL"
    detail "user.email = $DEVKIT_GIT_USER_EMAIL"
fi
if ! git config --global user.email >/dev/null 2>&1; then
    warn "Keine Git-Identität gesetzt - Commits im Container schlagen fehl."
    detail "Auf dem Host DEVKIT_GIT_USER_NAME und DEVKIT_GIT_USER_EMAIL setzen"
    detail "oder im Container: git config --global user.email you@example.com"
fi

# --- HTTPS-Token (GitLab Personal/Group Access Token) -----------------------
# GITLAB_HOST/GITLAB_TOKEN haben Vorrang, DEVKIT_GIT_* bleiben als generische
# Variante fuer andere Git-Hoster bestehen.
cred_host="${GITLAB_HOST:-${DEVKIT_GIT_HOST:-}}"
cred_host="${cred_host#https://}"; cred_host="${cred_host#http://}"; cred_host="${cred_host%/}"
cred_token="${GITLAB_TOKEN:-${DEVKIT_GIT_TOKEN:-}}"

if is_set "$cred_token" && is_set "$cred_host"; then
    DEVKIT_GIT_HOST="$cred_host"; DEVKIT_GIT_TOKEN="$cred_token"
    user="${DEVKIT_GIT_TOKEN_USER:-oauth2}"
    umask 077
    printf 'https://%s:%s@%s\n' "$user" "$DEVKIT_GIT_TOKEN" "$DEVKIT_GIT_HOST" > "$HOME/.git-credentials"
    chmod 600 "$HOME/.git-credentials"
    git config --global credential.helper store
    ok "HTTPS-Zugangsdaten für $cred_host hinterlegt."
fi

# --- SSH-Keys vom Host (optionaler Mount, siehe devcontainer.json) ----------
if [ -d /opt/devkit/ssh ]; then
    install -d -m 700 "$HOME/.ssh"
    shopt -s nullglob
    for f in /opt/devkit/ssh/*; do
        [ -f "$f" ] || continue
        case "$(basename "$f")" in
            known_hosts|config) install -m 644 "$f" "$HOME/.ssh/$(basename "$f")" ;;
            *.pub)              install -m 644 "$f" "$HOME/.ssh/$(basename "$f")" ;;
            id_*)               install -m 600 "$f" "$HOME/.ssh/$(basename "$f")" ;;
        esac
    done
    shopt -u nullglob
    ok "SSH-Keys vom Host übernommen (~/.ssh)."
fi

# --- GitLab: SSH-Hostkey vorab hinterlegen ---------------------------------
# Ohne bekannten Hostkey blockiert `git clone` über SSH mit einer interaktiven
# Rückfrage - im Lifecycle-Hook würde das den Container-Start haengen lassen.
if [ -n "$(gitlab_host)" ]; then
    gitlab_known_hosts
fi

# --- Proxy an Git durchreichen ---------------------------------------------
if is_set "${HTTPS_PROXY:-}"; then
    git config --global http.proxy "$HTTPS_PROXY"
    detail "http.proxy = $HTTPS_PROXY"
fi

exit 0
