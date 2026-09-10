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
#   devkit java              installierte JDKs anzeigen
#   devkit docker            Registry-Mirror anwenden/anzeigen
#   devkit sign              Commit-Signierung (neu) einrichten

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
# shellcheck source=gitlab.sh
source "$SCRIPT_DIR/gitlab.sh"

usage() {
    sed -n '3,16p' "$(readlink -f "${BASH_SOURCE[0]}")" | sed 's/^# \?//'
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
    check "uv"       uv --version
    check "uvx"      uvx --version
    check "Git"      git --version
    check "yq"       yq --version
    check "jq"       jq --version

    section "Installierte JDKs"
    for jh in /usr/lib/jvm/temurin-*; do
        [ -d "$jh" ] || continue
        case "$jh" in *-jdk-*) continue ;; esac
        marker="  "
        [ "$(readlink -f "$jh")" = "$(readlink -f "${JAVA_HOME:-/usr/lib/jvm/default}")" ] && marker=" *"
        printf ' %s %-28s %s
' "$marker" "$jh"             "$("$jh/bin/java" -version 2>&1 | head -n1)"
    done
    printf '  %s· %-28s %s%s
' "$_c_dim" "JAVA_HOME" "${JAVA_HOME:-}" "$_c_reset"
    printf '  %s· %-28s %s%s
' "$_c_dim" "(* = Standard)" "" "$_c_reset"

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

    if [ -f /etc/docker/daemon.json ]; then
        local m
        m="$(as_root cat /etc/docker/daemon.json 2>/dev/null | jq -r '."registry-mirrors" // [] | join(", ")' 2>/dev/null)"
        [ -n "$m" ] && printf '  %s·%s %-14s %s
' "$_c_dim" "$_c_reset" "Mirror" "$m"
    fi
    if [ -f "$HOME/.testcontainers.properties" ]; then
        local tcp
        tcp="$(grep -E '^hub.image.name.prefix=' "$HOME/.testcontainers.properties" | cut -d= -f2- || true)"
        printf '  %s·%s %-14s %s
' "$_c_dim" "$_c_reset" "Testcontainers"             "${tcp:-kein Image-Praefix}"
    fi

    section "Git & Signierung"
    printf '  %-16s %s
' "Identitaet"         "$(git config --global user.name 2>/dev/null || echo '-') <$(git config --global user.email 2>/dev/null || echo '-')>"
    printf '  %-16s %s
' "Signierung"         "$(git config --global commit.gpgsign 2>/dev/null || echo 'aus') ($(git config --global gpg.format 2>/dev/null || echo 'openpgp'), Key: $(git config --global user.signingkey 2>/dev/null || echo '-'))"

    section "Truststore"
    local sys_dir=/usr/local/share/ca-certificates/devkit
    local n_sys n_jvm
    n_sys=$(find "$sys_dir" -maxdepth 1 -name '*.crt' 2>/dev/null | wc -l)
    n_jvm=$(keytool -list -keystore "${JAVA_HOME:-/usr/lib/jvm/temurin-21}/lib/security/cacerts" \
            -storepass "${DEVKIT_TRUSTSTORE_PASS:-changeit}" 2>/dev/null | grep -c '^devkit-' || true)
    printf '  %s·%s %-14s %s\n' "$_c_dim" "$_c_reset" "System-CAs" "$n_sys eigene Zertifikate"
    printf '  %s·%s %-14s %s\n' "$_c_dim" "$_c_reset" "Java-CAs" "$n_jvm eigene Zertifikate"

    section "Volumes & Pfade"
    # /tmp im RAM ist die haeufigste Ursache fuer "no space left on device"
    # trotz freier Platte - deshalb hier ausdruecklich ausweisen.
    local tmpsrc tmpfs_warn=""
    tmpsrc="$(findmnt -no FSTYPE --target /tmp 2>/dev/null || echo unbekannt)"
    [ "$tmpsrc" = "tmpfs" ] && tmpfs_warn="  <-- liegt im RAM!"
    printf '  %-16s %s (%s, frei: %s)%s
' "/tmp" "$tmpsrc"         "$(du -sh /tmp 2>/dev/null | cut -f1)"         "$(df -h --output=avail /tmp 2>/dev/null | tail -1 | tr -d ' ')" "$tmpfs_warn"
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
    java)
        section "Installierte JDKs"
        for jh in /usr/lib/jvm/temurin-*; do
            [ -d "$jh" ] || continue
            case "$jh" in *-jdk-*) continue ;; esac
            printf '  %-28s %s
' "$jh" "$("$jh/bin/java" -version 2>&1 | head -n1)"
        done
        printf '
  Aktuell: JAVA_HOME=%s
' "${JAVA_HOME:-}"
        printf '  Fuer einen einzelnen Build:  JAVA_HOME=/usr/lib/jvm/temurin-17 ./gradlew build
'
        printf '  Dauerhaft pro Projekt:       Gradle-Toolchain in build.gradle.kts setzen
'
        printf '  Standard im Image aendern:   build.args.JAVA_DEFAULT in devcontainer.json
'
        ;;
    docker)  bash "$SCRIPT_DIR/configure-docker.sh" ;;
    sign)    bash "$SCRIPT_DIR/configure-gpg.sh" ;;
    -h|--help|help) usage ;;
    *) err "Unbekannter Befehl: $cmd"; usage; exit 1 ;;
esac
