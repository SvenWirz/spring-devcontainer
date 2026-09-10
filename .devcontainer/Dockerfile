# syntax=docker/dockerfile:1
#
# Basis-Image für die Java-/Spring-Boot-Microservice-Entwicklung mit OpenCode.
# Enthält: Temurin JDK, Gradle, OpenCode, Git/CLI-Tooling und die Bibliotheken,
# die das JetBrains-Remote-Backend (IntelliJ) benötigt.
#
# Docker-in-Docker kommt über das devcontainer-Feature dazu (siehe devcontainer.json).

ARG BASE_IMAGE=mcr.microsoft.com/devcontainers/base:bookworm
FROM ${BASE_IMAGE}

ARG USERNAME=vscode
# Alle zu installierenden Temurin-Major-Versionen, durch Leerzeichen getrennt.
ARG JAVA_VERSIONS="17 21"
# Version, die auf dem PATH liegt und auf die JAVA_HOME zeigt.
ARG JAVA_DEFAULT=21
ARG GRADLE_VERSION=current
ARG OPENCODE_VERSION=latest
ARG YQ_VERSION=latest
ARG GLAB_VERSION=latest
ARG UV_VERSION=latest
ARG TZ=Europe/Berlin

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    TZ=${TZ}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# ---------------------------------------------------------------------------
# 1) Root-CA bereits zur Build-Zeit einbinden.
#    Ohne diesen Schritt scheitern hinter einem TLS-inspizierenden Proxy alle
#    folgenden Downloads (Adoptium, Gradle, OpenCode).
# ---------------------------------------------------------------------------
COPY certs/ /tmp/devkit-certs/
RUN set -euo pipefail; \
    mkdir -p /usr/local/share/ca-certificates/devkit; \
    found=0; \
    for f in /tmp/devkit-certs/*; do \
        [ -f "$f" ] || continue; \
        case "${f,,}" in *.crt|*.pem|*.cer) ;; *) continue ;; esac; \
        base="$(basename "$f")"; \
        cp "$f" "/usr/local/share/ca-certificates/devkit/${base%.*}.crt"; \
        found=1; \
    done; \
    rm -rf /tmp/devkit-certs; \
    if [ "$found" = "1" ]; then update-ca-certificates; else echo "Keine Root-CA im Build-Kontext gefunden - überspringe."; fi

# ---------------------------------------------------------------------------
# 2) Basis-Tooling
#    - jq/yq: Auswertung von repositories.yaml
#    - libx*/fontconfig/libfreetype: vom JetBrains-Backend benötigt
#    - procps/psmisc: Prozessverwaltung des IDE-Backends
# ---------------------------------------------------------------------------
RUN set -euo pipefail; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates openssl curl wget apt-transport-https \
        gnupg gnupg-agent pinentry-tty \
        git git-lfs openssh-client \
        jq gettext-base unzip zip xz-utils bzip2 \
        less vim-tiny nano tree ripgrep \
        procps psmisc htop \
        iproute2 iputils-ping dnsutils netcat-openbsd socat \
        bash-completion tzdata locales \
        fontconfig libfreetype6 libxext6 libxrender1 libxtst6 libxi6 libxrandr2 \
        python3; \
    ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime && echo "${TZ}" > /etc/timezone; \
    git lfs install --system; \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# 3) yq (mikefarah) für das Parsen von repositories.yaml
# ---------------------------------------------------------------------------
RUN set -euo pipefail; \
    arch="$(dpkg --print-architecture)"; \
    if [ "${YQ_VERSION}" = "latest" ]; then \
        url="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${arch}"; \
    else \
        url="https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${arch}"; \
    fi; \
    curl -fsSL -o /usr/local/bin/yq "$url"; \
    chmod 0755 /usr/local/bin/yq; \
    yq --version

# ---------------------------------------------------------------------------
# 4) Eclipse Temurin JDKs aus dem offiziellen Adoptium-APT-Repository
#
#    In einer gewachsenen Microservice-Landschaft laufen selten alle Services
#    auf derselben Java-Version. Deshalb werden alle in JAVA_VERSIONS gelisteten
#    JDKs installiert; JAVA_DEFAULT bestimmt, welches auf dem PATH liegt.
#    Jedes JDK ist zusätzlich über den stabilen, architekturunabhängigen
#    Symlink /usr/lib/jvm/temurin-<major> erreichbar - genau die Pfade, die in
#    org.gradle.java.installations.paths eingetragen werden.
# ---------------------------------------------------------------------------
RUN set -euo pipefail; \
    install -d -m 0755 /etc/apt/keyrings; \
    curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public \
        | gpg --dearmor -o /etc/apt/keyrings/adoptium.gpg; \
    chmod 0644 /etc/apt/keyrings/adoptium.gpg; \
    . /etc/os-release; \
    echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb ${VERSION_CODENAME} main" \
        > /etc/apt/sources.list.d/adoptium.list; \
    apt-get update; \
    for v in ${JAVA_VERSIONS}; do \
        apt-get install -y --no-install-recommends "temurin-${v}-jdk"; \
    done; \
    apt-get clean && rm -rf /var/lib/apt/lists/*; \
    for v in ${JAVA_VERSIONS}; do \
        d="$(find /usr/lib/jvm -maxdepth 1 -type d -name "temurin-${v}-jdk-*" | sort | head -n1)"; \
        if [ -z "$d" ]; then echo "Temurin ${v} nicht gefunden" >&2; exit 1; fi; \
        ln -snf "$d" "/usr/lib/jvm/temurin-${v}"; \
        "/usr/lib/jvm/temurin-${v}/bin/java" -version; \
    done; \
    if [ ! -d "/usr/lib/jvm/temurin-${JAVA_DEFAULT}" ]; then \
        echo "JAVA_DEFAULT=${JAVA_DEFAULT} ist nicht in JAVA_VERSIONS=${JAVA_VERSIONS} enthalten" >&2; exit 1; \
    fi; \
    ln -snf "/usr/lib/jvm/temurin-${JAVA_DEFAULT}" /usr/lib/jvm/default; \
    printf '%s\n' "${JAVA_VERSIONS}" > /usr/lib/jvm/.devkit-versions

# /usr/lib/jvm/default zeigt auf JAVA_DEFAULT - dadurch muss beim Wechsel der
# Standardversion nur der Build-Arg angepasst werden, nicht jede Referenz.
ENV JAVA_HOME=/usr/lib/jvm/default
ENV PATH="${JAVA_HOME}/bin:${PATH}"

# ---------------------------------------------------------------------------
# 5) Gradle (Distribution von services.gradle.org, SHA-256-verifiziert)
#    Projekte sollten weiterhin ihren Gradle-Wrapper nutzen; dieses Gradle ist
#    für `gradle init`, `gradle wrapper` und wrapper-lose Aufrufe gedacht.
# ---------------------------------------------------------------------------
RUN set -euo pipefail; \
    if [ "${GRADLE_VERSION}" = "current" ]; then \
        url="$(curl -fsSL https://services.gradle.org/versions/current | jq -r '.downloadUrl')"; \
    else \
        url="https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip"; \
    fi; \
    echo "Gradle-Distribution: $url"; \
    curl -fsSL -o /tmp/gradle.zip "$url"; \
    expected="$(curl -fsSL "${url}.sha256")"; \
    echo "${expected}  /tmp/gradle.zip" | sha256sum -c -; \
    unzip -q /tmp/gradle.zip -d /opt; \
    rm -f /tmp/gradle.zip; \
    ln -snf "$(find /opt -maxdepth 1 -type d -name 'gradle-*' | sort -V | tail -n1)" /opt/gradle; \
    ln -snf /opt/gradle/bin/gradle /usr/local/bin/gradle

ENV GRADLE_HOME=/opt/gradle

# ---------------------------------------------------------------------------
# 6) OpenCode (AI-Coding-Agent) - natives Binary, kein Node erforderlich.
#    Das Install-Skript legt das Binary je nach Version direkt in
#    $OPENCODE_INSTALL_DIR oder in dessen bin/ ab - beide Varianten werden
#    abgedeckt und auf /opt/opencode/bin/opencode normalisiert.
# ---------------------------------------------------------------------------
RUN set -eu; \
    export OPENCODE_INSTALL_DIR=/opt/opencode; \
    if [ "${OPENCODE_VERSION}" = "latest" ]; then \
        curl -fsSL https://opencode.ai/install | bash; \
    else \
        curl -fsSL https://opencode.ai/install | VERSION="${OPENCODE_VERSION}" bash; \
    fi; \
    bin=""; \
    for cand in /opt/opencode/opencode /opt/opencode/bin/opencode \
                "${HOME:-/root}/.opencode/bin/opencode" "${HOME:-/root}/.opencode/opencode"; do \
        if [ -f "$cand" ]; then bin="$cand"; break; fi; \
    done; \
    if [ -z "$bin" ]; then \
        bin="$(find /opt/opencode "${HOME:-/root}/.opencode" -maxdepth 4 -type f -name opencode 2>/dev/null | head -n1 || true)"; \
    fi; \
    if [ -z "$bin" ]; then echo "OpenCode-Binary nach der Installation nicht gefunden" >&2; exit 1; fi; \
    install -D -m 0755 "$bin" /opt/opencode/bin/opencode.tmp; \
    mv -f /opt/opencode/bin/opencode.tmp /opt/opencode/bin/opencode; \
    rm -rf "${HOME:-/root}/.opencode"; \
    ln -snf /opt/opencode/bin/opencode /usr/local/bin/opencode; \
    opencode --version

# ---------------------------------------------------------------------------
# 7) glab - offizielle GitLab-CLI, funktioniert auch gegen self-hosted Instanzen
#    (Merge Requests, Pipelines, Issues, Registry-Login aus dem Container heraus).
#    Nicht build-kritisch: schlaegt der Download fehl, laeuft der Build weiter.
# ---------------------------------------------------------------------------
RUN set -uo pipefail; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
        amd64) pat="(amd64|x86_64)" ;; \
        arm64) pat="(arm64|aarch64)" ;; \
        *)     pat="$arch" ;; \
    esac; \
    if [ "${GLAB_VERSION}" = "latest" ]; then \
        api="https://gitlab.com/api/v4/projects/gitlab-org%2Fcli/releases/permalink/latest"; \
    else \
        api="https://gitlab.com/api/v4/projects/gitlab-org%2Fcli/releases/v${GLAB_VERSION}"; \
    fi; \
    url="$(curl -fsSL "$api" 2>/dev/null \
          | jq -r --arg p "$pat" '.assets.links[]? | select((.name|test("(?i)linux")) and (.name|test($p)) and (.name|endswith(".tar.gz"))) | .url' \
          | head -n1)"; \
    if [ -n "$url" ] && curl -fsSL -o /tmp/glab.tar.gz "$url"; then \
        mkdir -p /tmp/glab && tar -xzf /tmp/glab.tar.gz -C /tmp/glab; \
        bin="$(find /tmp/glab -type f -name glab 2>/dev/null | head -n1)"; \
        if [ -n "$bin" ]; then \
            install -m 0755 "$bin" /usr/local/bin/glab; glab --version; \
        else \
            echo "WARN: glab-Binary im Archiv nicht gefunden."; \
        fi; \
    else \
        echo "WARN: glab konnte nicht heruntergeladen werden - 'devkit gitlab' funktioniert dann nur eingeschraenkt."; \
    fi; \
    rm -rf /tmp/glab /tmp/glab.tar.gz

# ---------------------------------------------------------------------------
# 8) uv / uvx - schneller Python-Paketmanager von Astral.
#    uvx fuehrt Python-Werkzeuge in einer Wegwerf-Umgebung aus, ohne sie global
#    zu installieren - praktisch fuer npm-lose MCP-Server, yamllint, pre-commit
#    und aehnliches Beiwerk neben dem Java-Stack.
#    Der Installer respektiert SSL_CERT_FILE, laeuft also auch hinter der
#    Firmen-CA aus Schritt 1.
# ---------------------------------------------------------------------------
RUN set -eu; \
    if [ "${UV_VERSION}" = "latest" ]; then \
        url="https://astral.sh/uv/install.sh"; \
    else \
        url="https://astral.sh/uv/${UV_VERSION}/install.sh"; \
    fi; \
    export UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1; \
    curl -LsSf "$url" | sh; \
    uv --version; \
    uvx --version

# ---------------------------------------------------------------------------
# 9) Verzeichnisse für die Volume-Mounts anlegen.
#    Docker übernimmt beim erstmaligen Anlegen eines Named Volumes Rechte und
#    Eigentümer des Pfads aus dem Image – dadurch gehören die Volumes direkt
#    dem Entwicklungs-User und nicht root.
#
#    /tmp bekommt bewusst 1777 (sticky, world-writable): es liegt zur Laufzeit
#    auf einem Volume, das diese Rechte beim ersten Anlegen aus dem Image erbt.
#    Ohne das koennten nicht-root-Prozesse dort nichts ablegen.
# ---------------------------------------------------------------------------
RUN set -euo pipefail; \
    install -d -o "${USERNAME}" -g "${USERNAME}" -m 0755 \
        /src \
        "/home/${USERNAME}/.gradle" \
        "/home/${USERNAME}/.gradle/init.d" \
        "/home/${USERNAME}/.config" \
        "/home/${USERNAME}/.config/opencode" \
        "/home/${USERNAME}/.config/JetBrains" \
        "/home/${USERNAME}/.cache" \
        "/home/${USERNAME}/.cache/JetBrains" \
        "/home/${USERNAME}/.cache/uv" \
        "/home/${USERNAME}/.local" \
        "/home/${USERNAME}/.local/share" \
        "/home/${USERNAME}/.local/share/opencode"; \
    install -d -m 0755 /opt/devkit /opt/devkit/config /opt/devkit/certs \
        /var/lib/docker /etc/docker; \
    chmod 1777 /tmp

# Gradle-Daemon-Speicher konservativ vorbelegen; per gradle.properties übersteuerbar.
ENV GRADLE_USER_HOME=/home/${USERNAME}/.gradle \
    GRADLE_OPTS="-Dorg.gradle.daemon=false" \
    DEVKIT_HOME=/workspaces/devkit/.devcontainer \
    DEVKIT_CONFIG=/opt/devkit/config \
    DEVKIT_CERTS=/opt/devkit/certs \
    DEVKIT_WORKSPACE=/src

USER ${USERNAME}
WORKDIR /src
