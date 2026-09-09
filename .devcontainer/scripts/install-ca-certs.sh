#!/usr/bin/env bash
#
# Installiert alle Root-/Intermediate-CAs aus $DEVKIT_CERTS in
#   * den System-Truststore (/usr/local/share/ca-certificates -> ca-certificates.crt)
#   * die Truststores ALLER installierten JDKs
#     (/usr/lib/jvm/temurin-*/lib/security/cacerts)
#
# Idempotent: kann bei jedem Container-Start erneut laufen.
# Zertifikatsbündel (mehrere PEM-Blöcke in einer Datei) werden aufgeteilt,
# weil keytool pro Import genau ein Zertifikat erwartet.

set -euo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CERT_SRC="${DEVKIT_CERTS}"
SYS_DIR="/usr/local/share/ca-certificates/devkit"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

section "Root-CA-Zertifikate"

if [ ! -d "$CERT_SRC" ]; then
    warn "Zertifikatsverzeichnis $CERT_SRC existiert nicht - übersprungen."
    exit 0
fi

# --- 1) Kandidaten einsammeln und Bündel in Einzelzertifikate zerlegen ------
count=0
shopt -s nullglob nocaseglob
for src in "$CERT_SRC"/*.crt "$CERT_SRC"/*.pem "$CERT_SRC"/*.cer "$CERT_SRC"/*.der; do
    [ -f "$src" ] || continue
    base="$(basename "$src")"
    stem="$(echo "${base%.*}" | tr -c '[:alnum:]._-' '-')"

    # DER (binär) nach PEM konvertieren, PEM direkt weiterverwenden.
    if grep -qs -- '-----BEGIN CERTIFICATE-----' "$src"; then
        pem="$src"
    else
        pem="$WORK_DIR/$stem.converted.pem"
        if ! openssl x509 -inform DER -in "$src" -out "$pem" 2>/dev/null; then
            warn "$base ist weder gültiges PEM noch DER - ignoriert."
            continue
        fi
    fi

    # Bündel aufteilen: pro BEGIN/END-Block eine Datei.
    awk -v out="$WORK_DIR" -v stem="$stem" '
        /-----BEGIN CERTIFICATE-----/ { n++; f = sprintf("%s/%s-%02d.crt", out, stem, n) }
        f { print > f }
        /-----END CERTIFICATE-----/ { close(f); f = "" }
    ' "$pem"
done
shopt -u nullglob nocaseglob

for c in "$WORK_DIR"/*.crt; do
    [ -f "$c" ] || continue
    count=$((count + 1))
done

if [ "$count" -eq 0 ]; then
    log "Keine Zertifikate in $CERT_SRC gefunden - nichts zu tun."
    detail "Root-CA als .crt/.pem/.cer nach .devcontainer/certs/ legen und Container neu starten."
    exit 0
fi

# --- 2) System-Truststore --------------------------------------------------
as_root install -d -m 0755 "$SYS_DIR"
as_root find "$SYS_DIR" -maxdepth 1 -name '*.crt' -delete
for c in "$WORK_DIR"/*.crt; do
    as_root install -m 0644 "$c" "$SYS_DIR/$(basename "$c")"
done
as_root update-ca-certificates >/dev/null
ok "$count Zertifikat(e) im System-Truststore installiert."

# --- 3) Java-Truststores ---------------------------------------------------
# Es sind mehrere JDKs installiert (siehe Dockerfile, JAVA_VERSIONS). Jedes
# bringt seinen eigenen cacerts mit - die CA muss in alle, sonst schlaegt ein
# Build fehl, sobald ein Service per Gradle-Toolchain auf ein anderes JDK geht.
STOREPASS="${DEVKIT_TRUSTSTORE_PASS:-changeit}"

keystores=()
seen=""
for jh in /usr/lib/jvm/temurin-* "${JAVA_HOME:-}"; do
    [ -n "$jh" ] || continue
    ks="$jh/lib/security/cacerts"
    [ -f "$ks" ] || continue
    real="$(readlink -f "$ks")"
    case " $seen " in *" $real "*) continue ;; esac
    seen="$seen $real"
    keystores+=("$ks")
done

if [ ${#keystores[@]} -eq 0 ]; then
    warn "Kein Java-Truststore gefunden - JVM-Import übersprungen."
    exit 0
fi

for ks in "${keystores[@]}"; do
    imported=0
    for c in "$WORK_DIR"/*.crt; do
        alias="devkit-$(basename "$c" .crt)"
        # Alten Eintrag entfernen, damit ein ausgetauschtes Zertifikat wirklich greift.
        as_root keytool -delete -alias "$alias" -keystore "$ks" \
            -storepass "$STOREPASS" >/dev/null 2>&1 || true
        if as_root keytool -importcert -noprompt -trustcacerts -alias "$alias" \
            -file "$c" -keystore "$ks" -storepass "$STOREPASS" >/dev/null 2>&1; then
            imported=$((imported + 1))
        else
            warn "Import von $(basename "$c") in $ks fehlgeschlagen."
        fi
    done
    jdk="$(basename "$(dirname "$(dirname "$(dirname "$ks")")")")"
    ok "$imported Zertifikat(e) im Java-Truststore ($jdk)."
done

for c in "$WORK_DIR"/*.crt; do
    subject="$(openssl x509 -in "$c" -noout -subject 2>/dev/null | sed 's/^subject=//')"
    detail "devkit-$(basename "$c" .crt)  ${subject:-}"
done

# --- 4) Hinweis für den inneren Docker-Daemon ------------------------------
# Docker liest Registry-CAs aus dem System-Store; für Registries mit eigenem
# Zertifikat kann zusätzlich /etc/docker/certs.d/<host>/ca.crt nötig sein.
if [ -n "${DEVKIT_DOCKER_REGISTRIES:-}" ]; then
    bundle="/etc/ssl/certs/ca-certificates.crt"
    for reg in $DEVKIT_DOCKER_REGISTRIES; do
        as_root install -d -m 0755 "/etc/docker/certs.d/$reg"
        as_root install -m 0644 "$bundle" "/etc/docker/certs.d/$reg/ca.crt"
        detail "Registry-CA hinterlegt: /etc/docker/certs.d/$reg/ca.crt"
    done
fi
