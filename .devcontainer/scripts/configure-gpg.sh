#!/usr/bin/env bash
#
# Commit-Signierung im Dev Container.
#
# Zwei Varianten, gesteuert ueber DEVKIT_GIT_SIGN_FORMAT:
#
#   openpgp (Default)  GPG-Schluessel des Hosts wird verwendet. Dazu in
#                      devcontainer.json den ~/.gnupg-Mount einkommentieren;
#                      der Inhalt wird mit korrekten Rechten nach ~/.gnupg
#                      kopiert (ein Bind-Mount taugt nicht, weil gpg strikt
#                      700/600 verlangt und in den Socket-Pfad schreibt).
#
#   ssh                Signieren mit dem vorhandenen SSH-Key - kein GPG noetig.
#                      Setzt Git 2.34+ voraus (hier erfuellt).
#
# Relevante Variablen (alle optional):
#   DEVKIT_GIT_SIGN            true|false - Signierung ein-/ausschalten
#   DEVKIT_GIT_SIGN_FORMAT     openpgp|ssh
#   DEVKIT_GPG_SIGNING_KEY     Key-ID, Fingerprint oder E-Mail
#   DEVKIT_SSH_SIGNING_KEY     Pfad zum oeffentlichen SSH-Key

set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

section "Commit-Signierung"

FORMAT="${DEVKIT_GIT_SIGN_FORMAT:-openpgp}"
GNUPG_SRC="${DEVKIT_GNUPG_DIR:-/opt/devkit/gnupg}"

# GPG_TTY wird von pinentry-tty benoetigt, sonst schlaegt die Passphrase-Abfrage
# in einer nicht-interaktiven Umgebung kommentarlos fehl.
if [ ! -f /etc/profile.d/devkit-gpg.sh ]; then
    printf 'export GPG_TTY="$(tty 2>/dev/null || true)"\n' \
        | as_root tee /etc/profile.d/devkit-gpg.sh >/dev/null
    as_root chmod 0644 /etc/profile.d/devkit-gpg.sh
fi

case "$FORMAT" in
ssh)
    key="${DEVKIT_SSH_SIGNING_KEY:-}"
    if [ -z "$key" ]; then
        for cand in "$HOME"/.ssh/id_ed25519.pub "$HOME"/.ssh/id_rsa.pub; do
            [ -f "$cand" ] && { key="$cand"; break; }
        done
    fi
    if [ -z "$key" ] || [ ! -f "$key" ]; then
        warn "SSH-Signierung gewuenscht, aber kein oeffentlicher Schluessel gefunden."
        detail "DEVKIT_SSH_SIGNING_KEY setzen oder den ~/.ssh-Mount aktivieren."
        exit 0
    fi
    git config --global gpg.format ssh
    git config --global user.signingkey "$key"
    # allowed_signers erlaubt `git log --show-signature` auch lokal zu verifizieren.
    signers="$HOME/.config/git/allowed_signers"
    email="$(git config --global user.email || true)"
    if [ -n "$email" ]; then
        install -d "$(dirname "$signers")"
        printf '%s %s\n' "$email" "$(cat "$key")" > "$signers"
        git config --global gpg.ssh.allowedSignersFile "$signers"
    fi
    ok "SSH-Signierung aktiv ($key)."
    ;;

openpgp)
    # Schluesselbund vom Host uebernehmen, falls gemountet.
    if [ -d "$GNUPG_SRC" ]; then
        install -d -m 700 "$HOME/.gnupg"
        cp -r "$GNUPG_SRC/." "$HOME/.gnupg/" 2>/dev/null || true
        chown -R "$(id -u):$(id -g)" "$HOME/.gnupg" 2>/dev/null || true
        find "$HOME/.gnupg" -type d -exec chmod 700 {} + 2>/dev/null
        find "$HOME/.gnupg" -type f -exec chmod 600 {} + 2>/dev/null
        # Sockets aus dem Host-Verzeichnis sind im Container wertlos.
        rm -f "$HOME"/.gnupg/S.gpg-agent* 2>/dev/null
        ok "GPG-Schluesselbund vom Host uebernommen."
    fi

    if [ ! -d "$HOME/.gnupg" ]; then
        log "Kein GPG-Schluesselbund vorhanden - Signierung nicht konfiguriert."
        detail "GPG-Mount in devcontainer.json aktivieren (Ziel: $HOME/.gnupg) oder"
        detail "DEVKIT_GIT_SIGN_FORMAT=ssh setzen."
        exit 0
    fi

    if [ ! -f "$HOME/.gnupg/gpg-agent.conf" ] \
       || ! grep -q pinentry "$HOME/.gnupg/gpg-agent.conf" 2>/dev/null; then
        printf 'pinentry-program /usr/bin/pinentry-tty\ndefault-cache-ttl 3600\nmax-cache-ttl 28800\n' \
            >> "$HOME/.gnupg/gpg-agent.conf"
        chmod 600 "$HOME/.gnupg/gpg-agent.conf"
        gpgconf --kill gpg-agent >/dev/null 2>&1 || true
    fi

    key="${DEVKIT_GPG_SIGNING_KEY:-}"
    if [ -z "$key" ]; then
        # Genau ein geheimer Schluessel -> automatisch verwenden.
        mapfile -t keys < <(gpg --list-secret-keys --with-colons 2>/dev/null \
                            | awk -F: '$1 == "sec" { print $5 }')
        if [ "${#keys[@]}" -eq 1 ]; then
            key="${keys[0]}"
        elif [ "${#keys[@]}" -gt 1 ]; then
            warn "Mehrere geheime GPG-Schluessel gefunden - DEVKIT_GPG_SIGNING_KEY setzen."
            gpg --list-secret-keys --keyid-format=long 2>/dev/null | sed 's/^/          /'
            exit 0
        fi
    fi

    if [ -z "$key" ]; then
        log "Kein geheimer GPG-Schluessel im Schluesselbund - Signierung nicht konfiguriert."
        exit 0
    fi

    git config --global gpg.format openpgp
    git config --global gpg.program gpg
    git config --global user.signingkey "$key"
    ok "GPG-Signierung aktiv (Schluessel $key)."
    ;;

*)
    warn "Unbekanntes DEVKIT_GIT_SIGN_FORMAT '$FORMAT' (erlaubt: openpgp, ssh)."
    exit 0
    ;;
esac

if [ "${DEVKIT_GIT_SIGN:-true}" = "true" ]; then
    git config --global commit.gpgsign true
    git config --global tag.gpgsign true
    detail "commit.gpgsign und tag.gpgsign aktiviert."
else
    git config --global commit.gpgsign false
    detail "Signierung konfiguriert, aber nicht erzwungen (DEVKIT_GIT_SIGN=false)."
fi

exit 0
