#!/usr/bin/env bash
# Gemeinsame Helfer für alle DevKit-Skripte. Wird per `source` eingebunden.

DEVKIT_HOME="${DEVKIT_HOME:-/workspaces/devkit/.devcontainer}"
DEVKIT_CONFIG="${DEVKIT_CONFIG:-/opt/devkit/config}"
DEVKIT_CERTS="${DEVKIT_CERTS:-/opt/devkit/certs}"
DEVKIT_WORKSPACE="${DEVKIT_WORKSPACE:-/src}"
export DEVKIT_HOME DEVKIT_CONFIG DEVKIT_CERTS DEVKIT_WORKSPACE

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    _c_reset=$'\033[0m'; _c_blue=$'\033[34m'; _c_yellow=$'\033[33m'
    _c_red=$'\033[31m'; _c_green=$'\033[32m'; _c_dim=$'\033[2m'
else
    _c_reset=''; _c_blue=''; _c_yellow=''; _c_red=''; _c_green=''; _c_dim=''
fi

log()     { printf '%s[devkit]%s %s\n' "$_c_blue" "$_c_reset" "$*"; }
ok()      { printf '%s[devkit]%s %s\n' "$_c_green" "$_c_reset" "$*"; }
warn()    { printf '%s[devkit] WARN:%s %s\n' "$_c_yellow" "$_c_reset" "$*" >&2; }
err()     { printf '%s[devkit] FEHLER:%s %s\n' "$_c_red" "$_c_reset" "$*" >&2; }
detail()  { printf '%s          %s%s\n' "$_c_dim" "$*" "$_c_reset"; }
die()     { err "$*"; exit 1; }

section() {
    printf '\n%s==> %s%s\n' "$_c_blue" "$*" "$_c_reset"
}

have() { command -v "$1" >/dev/null 2>&1; }

# sudo nur benutzen, wenn wir nicht ohnehin root sind.
as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

# Prüft, ob eine Variable einen nicht-leeren Wert hat (leere localEnv-Werte
# kommen als leerer String an, nicht als "unset").
is_set() { [ -n "${1:-}" ]; }

# Kann git fuer <host> Zugangsdaten aufloesen? Das ist etwas anderes als "der
# API-Token funktioniert": git liest keine Umgebungsvariablen, sondern
# ausschliesslich seine Credential-Helper.
#   git_can_auth <host> [protocol]   protocol: https (Default) oder http
git_can_auth() {
    local host="$1" proto="${2:-https}" out
    [ -n "$host" ] || return 1
    out="$(printf 'protocol=%s\nhost=%s\n\n' "$proto" "$host" \
           | GIT_TERMINAL_PROMPT=0 git credential fill 2>/dev/null)" || return 1
    grep -q '^password=.' <<<"$out"
}

# Lokale Werte aus devkit.local.env laden (nicht versioniert, ueberlebt Rebuilds).
# shellcheck source-path=SCRIPTDIR
# shellcheck source=local-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/local-env.sh"

_DEVKIT_LIB_LOADED=1
