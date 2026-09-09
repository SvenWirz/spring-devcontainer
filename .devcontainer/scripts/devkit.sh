#!/usr/bin/env bash
#
# devkit - kleines Hilfswerkzeug im Container.
#
#   devkit doctor            Umgebung prüfen
#   devkit repos [sync|update|list]
#   devkit certs [install|list]
#   devkit config link       Gradle-/OpenCode-Config neu verknüpfen
#   devkit config show       aktive Pfade und Mounts anzeigen
#   devkit gitlab [status|login|registry|known-hosts|groups <pfad>]

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
# shellcheck source=gitlab.sh
source "$SCRIPT_DIR/gitlab.sh"

usage() {
    sed -n '3,13p' "$(readlink -f "${BASH_SOURCE[0]}")" | sed 's/^# \?//'
}

check() { # check <label> <kommando...>
    local label="$1"; shift
    local out
    if out="$("$@" 2>&1 | head -n1)"; then
        printf '  %s✓%s %-14s %s\n' "$_c_green" "$_c_reset" "$label" "$out"
    else
        printf '  %s✗%s %-14s %s\n' "$_c_red" "$_c_reset" "$label" "nicht verfügbar"
        return 1
    fi
}

doctor() {
    section "Umgebung"
    check "Java"     java -version
    check "javac"    javac -version
    check "Gradle"   bash -c 'gradle --version | grep -m1 "^Gradle"'
    check "OpenCode" opencode --version
    check "Node"     node --version
    check "npm"      npm --version
    check "Git"      git --version
    check "yq"       yq --version
    check "jq"       jq --version

    section "Docker-in-Docker"
    if docker info >/dev/null 2>&1; then
        printf '  %s✓%s %-14s %s\n' "$_c_green" "$_c_reset" "Daemon" \
            "$(docker version --format '{{.Server.Version}}' 2>/dev/null) ($(docker info --format '{{.Driver}}' 2>/dev/null))"
        printf '  %s·%s %-14s %s\n' "$_c_dim" "$_c_reset" "Images" \
            "$(docker images -q 2>/dev/null | wc -l) lokal"
    else
        printf '  %s✗%s %-14s %s\n' "$_c_red" "$_c_reset" "Daemon" \
            "nicht erreichbar - startet ggf. noch (docker info)"
    fi

    section "Truststore"
    local sys_dir=/usr/local/share/ca-certificates/devkit
    local n_sys n_jvm
    n_sys=$(find "$sys_dir" -maxdepth 1 -name '*.crt' 2>/dev/null | wc -l)
    n_jvm=$(keytool -list -keystore "${JAVA_HOME:-/usr/lib/jvm/temurin-21}/lib/security/cacerts" \
            -storepass "${DEVKIT_TRUSTSTORE_PASS:-changeit}" 2>/dev/null | grep -c '^devkit-' || true)
    printf '  %s·%s %-14s %s\n' "$_c_dim" "$_c_reset" "System-CAs" "$n_sys eigene Zertifikate"
    printf '  %s·%s %-14s %s\n' "$_c_dim" "$_c_reset" "Java-CAs" "$n_jvm eigene Zertifikate"

    section "Volumes & Pfade"
    printf '  %-16s %s\n' "Workspace"  "$DEVKIT_WORKSPACE ($(du -sh "$DEVKIT_WORKSPACE" 2>/dev/null | cut -f1))"
    printf '  %-16s %s\n' "Gradle-Home" "${GRADLE_USER_HOME:-$HOME/.gradle}"
    printf '  %-16s %s\n' "Config-Mount" "$DEVKIT_CONFIG"
    printf '  %-16s %s\n' "Cert-Mount"  "$DEVKIT_CERTS"
    printf '  %-16s %s\n' "Setup-Repo"  "$DEVKIT_HOME"

    if [ -n "$(gitlab_host)" ]; then
        gitlab_status || true
    fi

    section "Repositories"
    bash "$SCRIPT_DIR/clone-repos.sh" list 2>/dev/null | tail -n +3
}

config_show() {
    section "Aktive Konfiguration"
    printf '  %-24s %s\n' "repositories.yaml" "$DEVKIT_CONFIG/repositories.yaml"
    printf '  %-24s %s\n' "gradle.properties" "$(readlink -f "${GRADLE_USER_HOME:-$HOME/.gradle}/gradle.properties" 2>/dev/null || echo '-')"
    printf '  %-24s %s\n' "opencode.json" "$(readlink -f "$HOME/.config/opencode/opencode.json" 2>/dev/null || echo '-')"
    printf '  %-24s %s\n' "OPENCODE_CONFIG" "${OPENCODE_CONFIG:--}"
    printf '  %-24s %s\n' "JAVA_HOME" "${JAVA_HOME:--}"
    section "Gradle init.d"
    ls -l "${GRADLE_USER_HOME:-$HOME/.gradle}/init.d" 2>/dev/null | tail -n +2 || echo "  (leer)"
}

cmd="${1:-doctor}"; shift || true
case "$cmd" in
    doctor)  doctor ;;
    repos)   bash "$SCRIPT_DIR/clone-repos.sh" "${1:-sync}" ;;
    certs)
        case "${1:-install}" in
            install) bash "$SCRIPT_DIR/install-ca-certs.sh" ;;
            list)
                section "Hinterlegte Zertifikate"
                shopt -s nullglob
                for c in /usr/local/share/ca-certificates/devkit/*.crt; do
                    printf '  %-40s %s\n' "$(basename "$c")" \
                        "$(openssl x509 -in "$c" -noout -subject 2>/dev/null | sed 's/^subject=//')"
                done
                shopt -u nullglob
                ;;
            *) die "Unbekannt: devkit certs $1" ;;
        esac ;;
    config)
        case "${1:-show}" in
            link) bash "$SCRIPT_DIR/link-configs.sh" ;;
            show) config_show ;;
            *) die "Unbekannt: devkit config $1" ;;
        esac ;;
    gitlab)  bash "$SCRIPT_DIR/gitlab.sh" "$@" ;;
    -h|--help|help) usage ;;
    *) err "Unbekannter Befehl: $cmd"; usage; exit 1 ;;
esac
