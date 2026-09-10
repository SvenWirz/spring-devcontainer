# DevKit – Dev Container für Java-/Spring-Boot-Microservices mit OpenCode

Vorkonfigurierte Entwicklungsumgebung für die Arbeit an mehreren Spring-Boot-
Microservices mit dem AI-Agenten **OpenCode**, nutzbar aus **IntelliJ IDEA**
(JetBrains Gateway / Dev Containers) oder VS Code.

| Baustein | Umsetzung |
|---|---|
| Docker-in-Docker | eigener `dockerd` im Container (Feature `docker-in-docker`), Testcontainers-tauglich |
| Node/npm | Feature `node:1` (LTS) für Frontend-Anteile, `npx`-Werkzeuge und npm-basierte MCP-Server |
| IntelliJ-Anbindung | `customizations.jetbrains`, Backend-Bibliotheken im Image, persistenter IDE-Cache |
| Root-CA | `.devcontainer/certs/` in System- **und** Java-Truststore, bereits zur Build-Zeit |
| Persistentes Volume | Named Volumes für `/src`, Gradle-Cache, OpenCode-Daten, Docker-Daten, IDE-Cache |
| Repositories | deklarativ in `.devcontainer/config/repositories.yaml`, Klonen nach `/src` |
| Toolchain | Eclipse Temurin JDK **17 und 21**, Gradle, OpenCode, Node LTS + npm, `glab` |
| Registry-Mirror | `daemon.json` des inneren Daemons + Testcontainers-Image-Präfix gegen Docker-Hub-Limits |
| Commit-Signierung | GPG (Schlüsselbund vom Host) oder SSH-Signierung, automatisch eingerichtet |
| Vorgebautes Image | `.gitlab-ci.yml` baut und pusht das Image in die GitLab Registry |
| Self-hosted GitLab | Gruppen-Discovery beim Klonen, Credential-Helper, Container-/Maven-Registry |
| Mountbare Config | `.devcontainer/config/gradle/` und `.devcontainer/config/opencode/` (read-only) |

---

## 1. Voraussetzungen

* Docker Desktop (Linux-Container) oder eine erreichbare Docker-Engine
* Mindestens 8 GB RAM und ~64 GB freier Speicher für die Engine
* **IntelliJ IDEA** 2023.3+ (Ultimate oder Community) bzw. JetBrains Gateway,
  alternativ VS Code mit der Erweiterung *Dev Containers*

---

## 2. Schnellstart

### IntelliJ IDEA

1. `File > Remote Development > Dev Containers > New Dev Container`
   *(alternativ JetBrains Gateway > Dev Containers)*
2. Quelle **From Local Project** wählen und
   `<dieses Verzeichnis>/.devcontainer/devcontainer.json` auswählen
3. `Build Container and Continue`

Der erste Build dauert einige Minuten (JDK, Gradle, OpenCode, Docker). Danach
startet das IDE-Backend im Container und öffnet `/src`.

> In `devcontainer.json` steht `"backend": "IntelliJ"` (= IDEA Ultimate). Für die
> Community Edition auf `"IntelliJIdeaCommunity"` ändern.

### VS Code

`F1 > Dev Containers: Reopen in Container`

### Ohne IDE (CLI)

```bash
npm install -g @devcontainers/cli
devcontainer up --workspace-folder .
devcontainer exec --workspace-folder . bash
```

---

## 3. Aufbau

```
.devcontainer/
├── devcontainer.json          Container-Definition, Mounts, Volumes, Lifecycle
├── Dockerfile                 Temurin 17+21, Gradle, OpenCode, glab, Tooling
├── certs/                     Root-CA-Zertifikate ablegen  (read-only gemountet)
├── config/                    read-only nach /opt/devkit/config gemountet
│   ├── devkit.env.example     Vorlage für lokale Werte (Token, Hostnamen)
│   ├── repositories.yaml      Liste der zu klonenden Repositories
│   ├── docker/
│   │   └── daemon.json.example  Registry-Mirror des inneren Daemons
│   ├── gradle/
│   │   ├── gradle.properties.example
│   │   └── init.d/            global wirksame Gradle-Init-Skripte
│   ├── testcontainers/
│   │   └── testcontainers.properties  Reuse, Image-Präfix
│   └── opencode/
│       ├── opencode.json      globale OpenCode-Config
│       └── AGENTS.md          globale Arbeitsanweisungen für den Agenten
└── scripts/
    ├── post-create.sh         einmalig nach Container-Erstellung
    ├── post-start.sh          bei jedem Start (idempotent)
    ├── install-ca-certs.sh    Root-CA in System- und alle JDK-Truststores
    ├── configure-git.sh       Identität, Token, SSH-Keys
    ├── configure-gpg.sh       Commit-Signierung (GPG oder SSH)
    ├── configure-docker.sh    daemon.json des inneren Daemons
    ├── local-env.sh           lädt devkit.local.env
    ├── link-configs.sh        Config-Mounts zu Gradle-/OpenCode-Pfaden
    ├── clone-repos.sh         repositories.yaml auswerten
    ├── gitlab.sh              GitLab-API, Gruppen-Discovery, glab
    └── devkit.sh              CLI im Container (devkit ...)

.gitlab-ci.yml                 baut das Image zentral und pusht es in die Registry
```

Pfade im Container:

| Pfad | Inhalt |
|---|---|
| `/src` | **persistentes Volume** – hier liegen alle geklonten Repositories |
| `/workspaces/devkit` | dieses Setup-Repo als Bind-Mount (Änderungen wirken sofort) |
| `/opt/devkit/config` | `.devcontainer/config` (read-only) |
| `/opt/devkit/certs` | `.devcontainer/certs` (read-only) |

---

## 4. Persistente Volumes

Angelegt werden fünf Named Volumes (`<projektordner>` = Name dieses Verzeichnisses):

| Volume | Mountpunkt | Zweck |
|---|---|---|
| `<projektordner>-src` | `/src` | Quellcode / geklonte Repositories |
| `<projektordner>-gradle` | `~/.gradle` | Dependency- und Build-Cache, Wrapper-Distributionen |
| `<projektordner>-opencode` | `~/.local/share/opencode` | OpenCode-Logins, Sessions |
| `<projektordner>-docker` | `/var/lib/docker` | Images des inneren Docker-Daemons |
| `<projektordner>-jetbrains` | `~/.cache/JetBrains` | IDE-Indizes (kein Re-Indexing nach Rebuild) |

Ein *Rebuild* des Containers lässt alle Volumes unangetastet – Quellcode,
Caches und Logins bleiben erhalten. Vollständig zurücksetzen:

```
docker volume rm devcontainer-setups-src
docker volume rm devcontainer-setups-gradle
docker volume rm devcontainer-setups-opencode
docker volume rm devcontainer-setups-docker
docker volume rm devcontainer-setups-jetbrains
```

> **Achtung:** `-src` enthält den Quellcode inklusive nicht gepushter Commits.

---

## 5. Repositories konfigurieren

> **Interne Namen nicht einchecken:** Lege deine echte Konfiguration als
> `.devcontainer/config/repositories.local.yaml` an. Diese Datei hat Vorrang und
> ist per `.gitignore` ausgeschlossen; `repositories.yaml` bleibt die Vorlage.
> Reihenfolge: `DEVKIT_REPOS_CONFIG` > `repositories.local.yaml` > `repositories.yaml`.

`.devcontainer/config/repositories.yaml`:

```yaml
defaults:
  baseUrl: "https://git.example.com"   # optional, erlaubt Kurzschreibweisen
  branch: ""                           # leer = Default-Branch des Remotes
  depth: 0                             # >0 = Shallow Clone
  updateOnStart: false                 # bei jedem Start fetch + FF-Pull
  submodules: false
  lfs: false

repositories:
  - url: https://github.com/spring-projects/spring-petclinic.git

  - name: order-service
    url: shop/order-service.git        # wird gegen baseUrl aufgelöst
    dir: services/order-service        # Zielpfad relativ zu /src
    branch: develop
    updateOnStart: true
    postClone: "./gradlew --quiet build -x test"
```

Anwenden:

```bash
devkit repos sync      # nur fehlende Repositories klonen (läuft auch bei jedem Start)
devkit repos update    # zusätzlich vorhandene aktualisieren
devkit repos list      # Status: Branch, lokale Änderungen, fehlende Repos
```

Verhalten:

* Bereits vorhandene Repositories werden **nie** überschrieben.
* `updateOnStart` macht `fetch` und einen Fast-Forward-Pull; bei lokalen
  Änderungen wird nur gefetcht.
* Fehlschläge einzelner Repositories brechen den Lauf nicht ab, es gibt eine
  Zusammenfassung am Ende.
* Automatisches Klonen beim Start abschalten: `DEVKIT_SYNC_ON_START=false`.

### Git-Zugang

**SSH** – auf dem Host die Zeile für den SSH-Mount in `devcontainer.json`
einkommentieren (nur wenn `~/.ssh` existiert):

```jsonc
,"source=${localEnv:USERPROFILE}${localEnv:HOME}/.ssh,target=/opt/devkit/ssh,type=bind,readonly"
```

Die Keys werden im `postCreate` mit korrekten Rechten nach `~/.ssh` kopiert.

**HTTPS-Token** – auf dem Host setzen (siehe Abschnitt "Host-Umgebungsvariablen"), dann wird ein
Git-Credential-Helper eingerichtet:

```
DEVKIT_GIT_HOST=git.example.com
DEVKIT_GIT_TOKEN_USER=oauth2
DEVKIT_GIT_TOKEN=<personal access token>
```

Damit landet der Token **nicht** in den Remote-URLs der Repositories.

---

## 6. Self-hosted GitLab

Für eine selbst gehostete GitLab-Instanz bringt das Setup drei Bausteine mit:
die **GitLab-CLI `glab`** im Image, **Gruppen-Discovery** beim Klonen und
vorbereitete Anbindungen für **Package Registry** und **Container Registry**.

### 6.1 Zugang einrichten

Auf dem Host setzen (siehe Abschnitt "Host-Umgebungsvariablen"), im Container sind die Werte dann aktiv:

```
GITLAB_HOST   = gitlab.example.com
GITLAB_TOKEN  = <Personal oder Group Access Token>
```

Empfohlene Token-Scopes:

| Scope | wofür |
|---|---|
| `read_api` | Auflösen von Gruppen (`gitlab.groups`), `devkit gitlab status` |
| `read_repository` | Klonen |
| `write_repository` | Pushen |
| `read_registry`, `write_registry` | Container Registry (nur bei Bedarf) |

Daraus wird automatisch ein Git-Credential-Helper erzeugt – der Token steht
damit **nicht** in den Remote-URLs der Repositories. Prüfen:

```bash
devkit gitlab login    # meldet glab an UND richtet den git-Credential-Helper ein
devkit gitlab status   # Zeile "Git-Zugang" muss "ok" zeigen
```

> **Wichtig:** Ein gesetzter `GITLAB_TOKEN` allein reicht zum Klonen nicht –
> `git` liest keine Umgebungsvariablen, sondern ausschließlich seine
> Credential-Helper. `devkit gitlab login` erledigt beides: `glab` anmelden und
> git für diesen Host einrichten. `devkit gitlab status` weist den API-Zugriff
> und den Git-Zugang deshalb getrennt aus.

> Bei einer internen CA zuerst den Abschnitt "Root-CA hinterlegen" abarbeiten: ohne die Root-CA im
> Truststore scheitern sowohl `git clone` als auch die API-Aufrufe mit TLS-Fehler.

### 6.2 Ganze Gruppen klonen statt Repos einzeln pflegen

In > **Interne Namen nicht einchecken:** Lege deine echte Konfiguration als
> `.devcontainer/config/repositories.local.yaml` an. Diese Datei hat Vorrang und
> ist per `.gitignore` ausgeschlossen; `repositories.yaml` bleibt die Vorlage.
> Reihenfolge: `DEVKIT_REPOS_CONFIG` > `repositories.local.yaml` > `repositories.yaml`.

`.devcontainer/config/repositories.yaml`:

```yaml
gitlab:
  host: gitlab.example.com
  protocol: https              # oder ssh
  groups:
    - path: platform/services  # Gruppe oder Untergruppe
      includeSubgroups: true
      archived: false
      dirStrategy: relative    # relative | full | flat
      updateOnStart: true
      exclude:
        - "*-deprecated"
        - "platform/services/legacy-*"

repositories: []               # einzelne Zusatz-Repos weiterhin möglich
```

`dirStrategy` bestimmt den Zielpfad unter `/src` für ein Projekt
`platform/services/checkout/order-service`:

| Strategie | Ergebnis |
|---|---|
| `relative` (Default) | `/src/checkout/order-service` |
| `full` | `/src/platform/services/checkout/order-service` |
| `flat` | `/src/order-service` |

Gefundene Projekte werden mit der Liste unter `repositories:` zusammengeführt;
bei gleichem Zielverzeichnis gewinnt der handgepflegte Eintrag. Damit lässt sich
für ein einzelnes Repository ein abweichender Branch oder `postClone` festlegen,
während der Rest der Gruppe automatisch kommt.

```bash
devkit gitlab groups platform/services   # zeigt, was gefunden würde
devkit repos sync                        # klont fehlende Projekte
```

### 6.3 glab – Merge Requests und Pipelines aus dem Container

```bash
devkit gitlab login          # meldet glab an der Instanz an (nutzt GITLAB_TOKEN)
glab mr create --fill
glab mr list
glab ci status
glab ci view
```

### 6.4 Container Registry im Docker-in-Docker

```bash
devkit gitlab registry       # docker login gegen registry.<GITLAB_HOST>
docker pull registry.gitlab.example.com/platform/services/order-service:latest
```

Abweichender Registry-Host: `GITLAB_REGISTRY` auf dem Host setzen. Nutzt die
Registry ein eigenes Zertifikat, zusätzlich
`"DEVKIT_DOCKER_REGISTRIES": "registry.gitlab.example.com"` in `containerEnv`
eintragen (siehe Abschnitt "Root-CA hinterlegen").

### 6.5 Maven Package Registry als Gradle-Repository

`.devcontainer/config/gradle/init.d/20-gitlab-maven.gradle.kts.example` ohne die
Endung `.example` ablegen und konfigurieren – entweder über `GITLAB_MAVEN_URL`
auf dem Host oder in `gradle.properties`:

```properties
gitlabMavenUrl=https://gitlab.example.com/api/v4/groups/42/-/packages/maven
gitlabTokenName=Private-Token
gitlabToken=<token>
```

GitLab authentifiziert die Maven-Registry über einen HTTP-Header
(`Private-Token`, `Deploy-Token` oder `Job-Token`), nicht über Basic Auth – das
Init-Skript setzt das bereits korrekt um und gilt dann für **alle** Builds im
Container.

### 6.6 SSH statt HTTPS

`gitlab.protocol: ssh` in `repositories.yaml` setzen und den SSH-Mount in
`devcontainer.json` einkommentieren (Abschnitt "Repositories konfigurieren", Unterpunkt "Git-Zugang"). Der Hostkey der
Instanz wird beim Start automatisch nach `~/.ssh/known_hosts` übernommen
(`devkit gitlab known-hosts`) – ohne ihn würde `git clone` mit einer interaktiven
Rückfrage hängen bleiben. Abweichender SSH-Port: `GITLAB_SSH_PORT`.

### 6.7 Befehlsübersicht

```
devkit gitlab status              Host, Token, angemeldeter Benutzer, glab, Registry
devkit gitlab login               glab an der Instanz anmelden
devkit gitlab groups <pfad>       Projekte einer Gruppe auflisten
devkit gitlab registry            Docker-Login gegen die Container Registry
devkit gitlab known-hosts         SSH-Hostkey übernehmen
```

---

## 7. Root-CA hinterlegen

Zertifikat(e) nach `.devcontainer/certs/` legen (`.crt`, `.pem`, `.cer`, PEM
oder DER; Bündel mit mehreren Zertifikaten werden automatisch aufgeteilt):

```
.devcontainer/certs/corporate-root-ca.crt
```

Installiert wird an zwei Stellen:

* **Image-Build** – ohne die CA scheitern hinter einem TLS-inspizierenden Proxy
  bereits die Downloads von Adoptium, Gradle und OpenCode.
* **Container-Start** – System-Truststore (`/etc/ssl/certs/ca-certificates.crt`)
  und Java-Truststore (`$JAVA_HOME/lib/security/cacerts`, Alias `devkit-*`).

Zusätzlich zeigen `NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE`, `CURL_CA_BUNDLE`,
`REQUESTS_CA_BUNDLE` und `GIT_SSL_CAINFO` auf das System-Bundle, sodass auch
OpenCode, curl und Git die CA verwenden.

```bash
devkit certs install   # nach nachträglicher Änderung (kein Rebuild nötig)
devkit certs list      # installierte Zertifikate anzeigen
```

Ein **Rebuild** ist nur nötig, damit die CA auch zur Build-Zeit greift.

Für Docker-Registries mit eigenem Zertifikat zusätzlich in `devcontainer.json`
unter `containerEnv` setzen:
`"DEVKIT_DOCKER_REGISTRIES": "registry.example.com:5000"`.

---

## 8. Mehrere JDKs und Gradle-Toolchains

In einer gewachsenen Microservice-Landschaft laufen selten alle Services auf
derselben Java-Version. Das Image bringt deshalb mehrere Temurin-JDKs mit:

| Pfad | Inhalt |
|---|---|
| `/usr/lib/jvm/temurin-17` | Temurin 17 |
| `/usr/lib/jvm/temurin-21` | Temurin 21 |
| `/usr/lib/jvm/default` | Symlink auf die Standardversion (`JAVA_DEFAULT`) |

`JAVA_HOME` und der `PATH` zeigen auf `default`. Welche Versionen installiert
werden, steuert `build.args` in `devcontainer.json`:

```jsonc
"JAVA_VERSIONS": "17 21",   // durch Leerzeichen getrennt, beliebig erweiterbar
"JAVA_DEFAULT": "21"        // muss in JAVA_VERSIONS enthalten sein
```

Übersicht im Container:

```bash
devkit java
```

### Toolchain statt JAVA_HOME

Der saubere Weg pro Service ist die Gradle-Toolchain – sie hält die Java-Version
im Build fest, unabhängig davon, womit Gradle gestartet wurde:

```kotlin
java {
    toolchain { languageVersion.set(JavaLanguageVersion.of(17)) }
}
```

Damit Gradle die im Image liegenden JDKs findet (und **nicht** versucht, eines
herunterzuladen), müssen die Pfade in `gradle.properties` stehen – die Vorlage
enthält sie bereits:

```properties
org.gradle.java.installations.paths=/usr/lib/jvm/temurin-17,/usr/lib/jvm/temurin-21
org.gradle.java.installations.auto-download=false
```

Für einen einzelnen Aufruf geht auch:

```bash
JAVA_HOME=/usr/lib/jvm/temurin-17 ./gradlew build
```

> Die Root-CA wird in die Truststores **aller** installierten JDKs importiert.
> Sonst schlägt ein Build fehl, sobald ein Service per Toolchain auf ein anderes
> JDK wechselt.

---

## 9. Gradle-Konfiguration mounten

Das Verzeichnis `.devcontainer/config/gradle/` wird read-only gemountet und im
Container verlinkt:

| Quelle | Ziel im Container |
|---|---|
| `config/gradle/gradle.properties` | `$GRADLE_USER_HOME/gradle.properties` |
| `config/gradle/init.d/*.gradle[.kts]` | `$GRADLE_USER_HOME/init.d/` |

Loslegen:

```bash
cp .devcontainer/config/gradle/gradle.properties.example \
   .devcontainer/config/gradle/gradle.properties
```

Init-Skripte in `init.d/` gelten für **jeden** Build im Container – auch für
Builds über den Gradle-Wrapper eines einzelnen Repositories. Das mitgelieferte
`10-corporate-repository.gradle.kts.example` leitet alle Dependencies auf einen
internen Nexus/Artifactory-Mirror um.

Änderungen wirken sofort (Symlinks); `devkit config link` erneuert die
Verknüpfungen, `devkit config show` zeigt den aktiven Stand.

> `gradle.properties` und aktive Init-Skripte sind per `.gitignore`
> ausgenommen, weil dort typischerweise Zugangsdaten stehen.

Der Cache (`~/.gradle/caches`, Wrapper-Distributionen) liegt im persistenten
Volume und übersteht Rebuilds.

---

## 10. OpenCode-Konfiguration mounten

| Quelle | Ziel im Container |
|---|---|
| `config/opencode/opencode.json` | `~/.config/opencode/opencode.json` + `OPENCODE_CONFIG` |
| `config/opencode/AGENTS.md` | `~/.config/opencode/AGENTS.md` (globale Anweisungen) |
| `config/opencode/agent/`, `command/`, `plugin/` | gleichnamige Verzeichnisse unter `~/.config/opencode/` |

`AGENTS.md` enthält bereits Vorgaben für Spring-Boot-Code, Gradle-Wrapper-Nutzung
und den Umgang mit Proxy und Truststore. Projektspezifische `AGENTS.md`-Dateien
im jeweiligen Repository ergänzen diese.

Anmeldung beim Modellanbieter – einmalig, bleibt im Volume erhalten:

```bash
opencode auth login
```

Alternativ API-Keys auf dem Host als Umgebungsvariable setzen
(`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`); sie werden
durchgereicht.

Weitere Optionen (Modellwahl, Berechtigungen, MCP-Server) gehören in
`opencode.json` – Referenz: <https://opencode.ai/docs/config/>.

Starten:

```bash
cd /src/order-service
opencode
```

---

## 11. Konfiguration von außerhalb des Repos mounten

In `devcontainer.json` sind unter `mounts` vorbereitete, auskommentierte Zeilen
enthalten. Damit lässt sich z. B. ein zentrales Firmen-Config-Verzeichnis
einhängen, das nicht Teil dieses Repos ist:

```jsonc
,"source=C:\Users\meinname\corp-devkit\gradle,target=/opt/devkit/config/gradle,type=bind,readonly"
,"source=C:\Users\meinname\corp-devkit\opencode,target=/opt/devkit/config/opencode,type=bind,readonly"
,"source=C:\Users\meinname\corp-devkit\certs,target=/opt/devkit/certs,type=bind,readonly"
```

Diese Mounts überlagern das jeweilige Unterverzeichnis aus dem Standard-Mount.
Wichtig: Backslashes in JSON verdoppeln, oder Forward-Slashes verwenden.

---

## 12. Host-Umgebungsvariablen

Werden über `remoteEnv` in den Container gereicht; nicht gesetzte Variablen
werden ignoriert.

| Variable | Wirkung |
|---|---|
| `DEVKIT_GIT_USER_NAME`, `DEVKIT_GIT_USER_EMAIL` | Git-Identität im Container |
| `GITLAB_HOST`, `GITLAB_TOKEN` | Self-hosted GitLab: API, Klonen, `glab`, Registry |
| `GITLAB_REGISTRY`, `GITLAB_MAVEN_URL`, `GITLAB_SSH_PORT` | abweichende Registry / Maven-Registry / SSH-Port |
| `DEVKIT_GIT_HOST`, `DEVKIT_GIT_TOKEN`, `DEVKIT_GIT_TOKEN_USER` | generischer HTTPS-Credential-Helper (andere Hoster) |
| `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY` | Proxy für Container, Git und Gradle |
| `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY` | OpenCode-Provider |
| `DEVKIT_GIT_SIGN`, `DEVKIT_GIT_SIGN_FORMAT` | Commit-Signierung ein/aus, `openpgp` oder `ssh` |
| `DEVKIT_GPG_SIGNING_KEY`, `DEVKIT_SSH_SIGNING_KEY` | zu verwendender Signaturschlüssel |

Dauerhaft setzen (PowerShell, danach Terminal/IDE neu starten):

```powershell
[Environment]::SetEnvironmentVariable('DEVKIT_GIT_USER_NAME', 'Vorname Nachname', 'User')
[Environment]::SetEnvironmentVariable('DEVKIT_GIT_USER_EMAIL', 'ich@example.com', 'User')
[Environment]::SetEnvironmentVariable('GITLAB_HOST', 'gitlab.example.com', 'User')
[Environment]::SetEnvironmentVariable('GITLAB_TOKEN', 'glpat-xxxxxxxxxxxx', 'User')
```

---

## 13. Lokale Werte hinterlegen

Token, interne Hostnamen und Schlüssel gehören weder ins Repository noch in
Windows-Umgebungsvariablen, wenn es auch einfacher geht. Zwei Dateien im
`config`-Verzeichnis sind dafür vorgesehen; beide sind per `.gitignore`
ausgeschlossen und liegen auf dem Host, überleben also Container-Rebuilds.

| Datei | Inhalt | Vorlage im Repo |
|---|---|---|
| `config/devkit.local.env` | Token, Hostnamen, Signaturschlüssel | `config/devkit.env.example` |
| `config/repositories.local.yaml` | die echte Repository-/Gruppenliste | `config/repositories.yaml` |

> Die Vorlagen heißen bewusst **ohne** `.local.` im Namen – das Ignore-Muster
> ist `*.local.*`. Immer eine Kopie anlegen, nie die Vorlage selbst befüllen.

### Einrichten

```bash
cd .devcontainer/config
cp devkit.env.example devkit.local.env
cp repositories.yaml  repositories.local.yaml
```

`devkit.local.env` befüllen:

```
GITLAB_HOST=gitlab.example.com
GITLAB_TOKEN=glpat-...
DEVKIT_GIT_USER_NAME=Vorname Nachname
DEVKIT_GIT_USER_EMAIL=vorname.nachname@example.com
```

`repositories.local.yaml` bekommt Host und Gruppen:

```yaml
gitlab:
  host: gitlab.example.com
  groups:
    - path: platform/services
      includeSubgroups: true
```

Danach im Container:

```bash
devkit gitlab login     # glab + git-Credential-Helper
devkit gitlab status    # "Git-Zugang" muss ok sein
devkit repos sync       # klont nach /src
devkit doctor
```

Ohne Container-Neustart wirksam: die Dateien liegen im bind-gemounteten
`config`-Verzeichnis. Nach dem allerersten Anlegen einmal ein neues Terminal
öffnen, damit interaktive Shells die Variablen sehen.

### Vorrangregeln

```
devkit.local.env                     ← gewinnt
        ↓
Umgebungsvariable (Host, über remoteEnv)
        ↓
Vorgabe im Skript
```

Die Datei gewinnt bewusst. Was über `remoteEnv` hereinkommt, wurde irgendwann
als Windows-Benutzervariable gesetzt und ist von innen unsichtbar – ein dort
vergessener alter Token überstimmt sonst stillschweigend die Datei, die man
gerade gepflegt hat. Das Ergebnis ist ein `401`, obwohl in `devkit.local.env`
der richtige Wert steht.

Weicht ein Wert aus der Umgebung von der Datei ab, meldet `devkit gitlab status`
das ausdrücklich. Wer das alte Verhalten braucht (etwa weil eine CI gezielt
überschreibt), setzt `DEVKIT_LOCAL_ENV_MODE=fallback` – dann dient die Datei nur
als Rückfallebene.

```
DEVKIT_REPOS_CONFIG   ← explizit gesetzter Pfad gewinnt
        ↓
repositories.local.yaml
        ↓
repositories.yaml
```

`devkit.local.env` wird **nicht** als Shell ausgeführt, sondern zeilenweise
geparst: `KEY=VALUE`, `#` am Zeilenanfang ist Kommentar, umgebende
Anführungszeichen werden entfernt, CRLF wird toleriert. `$VAR`, `` ` `` und
`$(...)` bleiben Text – ein Token mit Sonderzeichen kann nichts auslösen.

---

## 14. Docker-in-Docker

Im Container läuft ein **eigener** Docker-Daemon; er ist vom Host-Docker
isoliert. Container, die hier gestartet werden, erscheinen nicht in Docker
Desktop.

```bash
docker run --rm hello-world
docker compose up -d
./gradlew test          # Testcontainers funktioniert ohne Zusatzkonfiguration
```

* Erfordert `"privileged": true` (in `devcontainer.json` gesetzt).
* Images liegen im Volume `...-docker` und überleben Rebuilds.
* Aus einem Service heraus ist ein Nachbarcontainer über den Compose-Netzwerknamen
  erreichbar, nicht über `localhost`.

**Alternative ohne privilegierten Modus** (Docker-outside-of-Docker – nutzt den
Host-Daemon, Testcontainers-Port-Mapping verhält sich dann anders): in
`devcontainer.json` das Feature ersetzen durch
`"ghcr.io/devcontainers/features/docker-outside-of-docker:1": {}`,
`"privileged": true` entfernen und das Volume `...-docker` löschen.

### Registry-Mirror gegen Docker-Hub-Rate-Limits

Im Firmennetz ist das die Stelle, an der Docker-in-Docker als Erstes bricht:
anonyme Pulls gegen Docker Hub laufen in `toomanyrequests`, oder der Proxy
blockt sie ganz. Abhilfe – Vorlage kopieren und anpassen:

```bash
cp .devcontainer/config/docker/daemon.json.example    .devcontainer/config/docker/daemon.json
```

```jsonc
{
  "registry-mirrors": ["https://nexus.example.com:8082"],
  "insecure-registries": [],
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
```

Die Datei wird beim Start mit der Konfiguration des `docker-in-docker`-Features
zusammengeführt (unsere Werte gewinnen) und per `SIGHUP` nachgeladen – für
`registry-mirrors` und `insecure-registries` reicht das, ein Rebuild ist nicht
nötig. Anwenden und prüfen:

```bash
devkit docker
```

> `registry-mirrors` gilt **nur** für Docker Hub und setzt einen Pull-Through-
> Cache voraus, der die Registry-API auf Host-Ebene anbietet (Nexus, Artifactory,
> Harbor). GitLabs **Dependency Proxy** ist kein gültiger `registry-mirror` –
> dort wird der Imagename präfixiert, siehe nächster Abschnitt.

### Testcontainers

`.devcontainer/config/testcontainers/testcontainers.properties` wird beim Start
nach `~/.testcontainers.properties` **kopiert** (nicht verlinkt – Testcontainers
schreibt selbst hinein). Vorbelegt ist:

```properties
testcontainers.reuse.enable=true
```

Für die Docker-Hub-Umleitung – inklusive der internen Helfer-Images (Ryuk, Tiny
Image) – zusätzlich eine der beiden Zeilen aktivieren:

```properties
# GitLab Dependency Proxy (Gruppenebene, docker login erforderlich)
hub.image.name.prefix=gitlab.example.com/meine-gruppe/dependency_proxy/containers/
# oder Nexus/Artifactory/Harbor
hub.image.name.prefix=nexus.example.com:8082/
```

Benötigt Testcontainers 1.19+. Der Docker-Daemon selbst muss nicht konfiguriert
werden – Testcontainers findet ihn im Container über `/var/run/docker.sock`.
Nach Änderungen: `devkit config link`.

---

## 15. Commit-Signierung

Verlangt eure GitLab-Instanz signierte Commits, richtet der Container das beim
Start selbst ein. Zwei Varianten, umgeschaltet über `DEVKIT_GIT_SIGN_FORMAT`:

### GPG (Default)

Schlüsselbund des Hosts einbinden – in `devcontainer.json` unter `mounts`:

```jsonc
,"source=${localEnv:USERPROFILE}${localEnv:HOME}/.gnupg,target=/opt/devkit/gnupg,type=bind,readonly"
```

Der Inhalt wird nach `~/.gnupg` **kopiert** (700/600), weil `gpg` strikte Rechte
verlangt und in den Socket-Pfad schreibt – ein Bind-Mount taugt dafür nicht.
Zusätzlich wird `pinentry-tty` als Pinentry gesetzt, damit die Passphrase-Abfrage
im Terminal funktioniert.

Gibt es genau einen geheimen Schlüssel, wird er automatisch verwendet. Bei
mehreren:

```
DEVKIT_GPG_SIGNING_KEY=<Key-ID, Fingerprint oder E-Mail>
```

### SSH

Ohne GPG, signiert mit dem vorhandenen SSH-Key (Git 2.34+):

```
DEVKIT_GIT_SIGN_FORMAT=ssh
DEVKIT_SSH_SIGNING_KEY=/home/vscode/.ssh/id_ed25519.pub   # optional, sonst automatisch
```

Zusätzlich wird eine `allowed_signers`-Datei angelegt, damit
`git log --show-signature` auch lokal verifizieren kann. Der öffentliche
Schlüssel muss in GitLab unter *Preferences ▸ SSH Keys* als **Signing Key**
hinterlegt sein.

### Steuerung

| Variable | Wirkung |
|---|---|
| `DEVKIT_GIT_SIGN` | `false` = konfigurieren, aber nicht erzwingen (Default `true`) |
| `DEVKIT_GIT_SIGN_FORMAT` | `openpgp` (Default) oder `ssh` |
| `DEVKIT_GPG_SIGNING_KEY` | Schlüssel für OpenPGP |
| `DEVKIT_SSH_SIGNING_KEY` | Pfad zum öffentlichen SSH-Key |

```bash
devkit sign      # Signierung neu einrichten
devkit doctor    # zeigt aktive Signierung und Schlüssel
```

---

## 16. Vorgebautes Image aus der GitLab CI

Ohne Prebuild baut jede:r Entwickler:in das ~2,6 GB große Image selbst – hinter
einem Proxy schnell 15 Minuten. `.gitlab-ci.yml` im Projektwurzelverzeichnis
baut es stattdessen einmal zentral:

| Job | Wann | Was |
|---|---|---|
| `lint` | jeder Push / MR | shellcheck, YAML-/JSON-Prüfung, `devcontainer read-configuration` |
| `build` | MR (nur bauen), Default-Branch und Tags (bauen + pushen), Schedule | `devcontainer build` inklusive Features |
| `smoke-test` | nach dem Push | JDKs, Gradle, OpenCode, Node, Pfade im gebauten Image |

Einmalige Einrichtung unter *Settings ▸ CI/CD ▸ Variables*:

| Variable | Typ | Zweck |
|---|---|---|
| `CORPORATE_ROOT_CA` | File | PEM der Firmen-Root-CA – ohne sie scheitern die Downloads im Build hinter TLS-Inspection |
| `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` | Variable | falls der Runner einen Proxy braucht |

Der Runner muss privilegierte Container erlauben (Docker-in-Docker).

### Im Team verwenden

Der schnellste Weg ohne zweite Konfigurationsdatei ist das Image als
**Layer-Cache** – in `devcontainer.json` einkommentieren:

```jsonc
"build": {
  "dockerfile": "Dockerfile",
  "context": ".",
  "cacheFrom": "registry.example.com/platform/devkit:latest"
}
```

Der lokale Build läuft dann durch, zieht aber alle Layer aus der Registry statt
sie neu zu bauen. Alternativ komplett auf das fertige Image umstellen: `build`
durch `"image": "registry.example.com/platform/devkit:latest"` ersetzen und den
`features`-Block entfernen – die Features sind bereits eingebacken.

> Ein Schedule (*CI/CD ▸ Schedules*, z. B. wöchentlich) hält Basis-Image und
> Paketstand aktuell, ohne dass jemand etwas committen muss.

---

## 17. devkit-Befehle

```
devkit doctor           JDK, Gradle, OpenCode, Docker, Truststore, Volumes prüfen
devkit repos sync       fehlende Repositories klonen
devkit repos update     alle Repositories aktualisieren
devkit repos list       Status je Repository
devkit certs install    Root-CA (neu) einlesen
devkit certs list       installierte Zertifikate anzeigen
devkit config link      Gradle-/OpenCode-/Testcontainers-Config neu übernehmen
devkit config show      aktive Konfigurationspfade anzeigen
devkit java             installierte JDKs anzeigen
devkit docker           daemon.json des inneren Daemons anwenden/anzeigen
devkit sign             Commit-Signierung (neu) einrichten
devkit gitlab status    Verbindung zur GitLab-Instanz prüfen
```

---

## 18. Anpassen

| Ziel | Vorgehen |
|---|---|
| Weitere JDK-Version | `build.args.JAVA_VERSIONS` ergänzen (z. B. `"17 21 25"`) und den Pfad in `gradle.properties` nachtragen |
| Andere Standard-JDK | `build.args.JAVA_DEFAULT` – `JAVA_HOME` folgt automatisch über `/usr/lib/jvm/default` |
| Gradle-Version pinnen | `build.args.GRADLE_VERSION` von `current` auf z. B. `8.14.3` setzen |
| OpenCode-Version pinnen | `build.args.OPENCODE_VERSION` auf eine konkrete Version setzen |
| Node-Version | `features` -> `node:1` -> `version` (`lts` oder z. B. `22`) |
| Zusätzliches Tooling | Pakete im `Dockerfile` (Schritt 2) ergänzen oder ein Feature in `devcontainer.json` hinzufügen |
| Weitere Ports | `forwardPorts` / `portsAttributes` erweitern |
| Zeitzone | `build.args.TZ` |

Nach Änderungen an `Dockerfile` oder `devcontainer.json` ist ein **Rebuild**
nötig; Änderungen an `config/`, `certs/` und `scripts/` wirken ohne Rebuild.

`.devcontainer/devcontainer-lock.json` pinnt die Features auf konkrete
SHA-256-Digests und wird beim `up` automatisch aktualisiert. Die Datei gehört ins
Repository – sie sorgt dafür, dass alle im Team dieselben Feature-Versionen
bekommen. Zum Aktualisieren löschen und den Container neu bauen.

---

## 19. Troubleshooting

**`docker info` schlägt direkt nach dem Start fehl**
Der innere Daemon braucht einige Sekunden. Bleibt es dabei: prüfen, ob
`"privileged": true` aktiv ist und die Docker-Engine des Hosts privilegierte
Container erlaubt.

**Gradle/Git melden `PKIX path building failed` oder `unable to get local issuer certificate`**
Root-CA fehlt oder wurde nach dem Build hinzugefügt: `devkit certs install`,
danach `devkit doctor`. Läuft schon der *Build* ins Zertifikatsproblem, muss die
CA vor dem Rebuild in `.devcontainer/certs/` liegen.

**API antwortet `401`, obwohl in `devkit.local.env` ein gültiger Token steht**
Auf dem Host ist zusätzlich eine Umgebungsvariable `GITLAB_TOKEN` gesetzt – oft
vor Monaten angelegt und längst abgelaufen. Sie kommt über `remoteEnv` in den
Container. `devkit gitlab status` zeigt die Quelle des Tokens an und warnt bei
Abweichung. Den alten Wert auf dem Host entfernen:

```powershell
[Environment]::SetEnvironmentVariable('GITLAB_TOKEN', $null, 'User')
```

Danach das Terminal bzw. die IDE neu starten. Ohne das Aufräumen benutzt zwar
DevKit den Wert aus der Datei, `glab` und andere Werkzeuge sehen aber weiterhin
den alten Token aus der Umgebung.

**`git clone` fragt nach Username/Passwort, obwohl `devkit gitlab status` grün ist**
Zwei verschiedene Dinge: `status` prüft den **API**-Zugriff (curl mit
`PRIVATE-TOKEN`), `git clone` benutzt ausschließlich seine **Credential-Helper**
und liest `GITLAB_TOKEN` nicht. Auch `glab auth login` konfiguriert nur `glab`,
nicht git. Lösung:

```bash
devkit gitlab login     # meldet glab an UND richtet den git-Credential-Helper ein
devkit gitlab status    # Zeile "Git-Zugang" muss "ok" zeigen
```

Manuell prüfen, was git tatsächlich findet:

```bash
printf 'protocol=https
host=gitlab.example.com

' | git credential fill
```

Kommt keine `password=`-Zeile, greift kein Helper. Beachten: VS Code und
JetBrains setzen einen eigenen globalen `credential.helper`, der Zugangsdaten
vom Host durchreicht und interne Instanzen nicht kennt. Deshalb registriert
DevKit seinen Helper **host-spezifisch**
(`credential.https://<host>.helper=store`) und lässt den globalen unangetastet.

**Beim Container-Start: „Gruppen sind konfiguriert, aber es wurde kein Projekt aufgelöst"**
Die Fehlermeldung nennt die Ursache mit: `Token abgelehnt (401)`,
`zu wenig Rechte (403)`, `Pfad nicht gefunden (404)` oder
`Instanz nicht erreichbar`. Letzteres heißt VPN/Netz – der Aufruf wiederholt
sich dreimal, bevor er aufgibt, damit ein noch nicht fertiges Netz beim Start
nicht sofort zum Fehler führt. `devkit repos sync` holt das jederzeit nach.

**Repositories werden nicht geklont**
`devkit repos list` zeigt den Status. Bei privaten Repos Zugangsdaten prüfen
(Abschnitt "Repositories konfigurieren"). `clone-repos.sh` setzt
`GIT_TERMINAL_PROMPT=0`, damit ein fehlendes Credential sofort als Fehler
auffällt statt den Container-Start mit einem Anmelde-Prompt zu blockieren.

**IntelliJ indexiert bei jedem Start neu**
Das Volume `...-jetbrains` muss existieren und darf nicht gelöscht werden;
mit `docker volume ls` prüfen.

**Gradle-Build läuft out of memory**
`org.gradle.jvmargs` in `.devcontainer/config/gradle/gradle.properties` senken
oder der Docker-Engine mehr RAM zuweisen (Docker Desktop > Settings > Resources).

**git meldet "dubious ownership"**
Sollte durch `safe.directory=*` abgedeckt sein; sonst
`bash /workspaces/devkit/.devcontainer/scripts/configure-git.sh` erneut ausführen.

**`docker pull` bzw. Testcontainers meldet `toomanyrequests`**
Docker-Hub-Rate-Limit. Registry-Mirror in
`.devcontainer/config/docker/daemon.json` eintragen und/oder
`hub.image.name.prefix` in
`.devcontainer/config/testcontainers/testcontainers.properties` setzen –
siehe Abschnitt "Docker-in-Docker". Danach `devkit docker` bzw.
`devkit config link`.

**Gradle will ein JDK herunterladen (`No matching toolchain / auto-download`)**
Die angeforderte Toolchain-Version ist nicht im Image. Entweder die Version zu
`build.args.JAVA_VERSIONS` hinzufügen und neu bauen, oder den Pfad in
`org.gradle.java.installations.paths` ergänzen. `devkit java` zeigt, was da ist.

**Signierter Commit schlägt fehl (`gpg failed to sign the data`)**
Meist fehlt das TTY für die Passphrase-Abfrage: in der Shell
`export GPG_TTY=$(tty)` (wird über `/etc/profile.d` normalerweise gesetzt) und
`echo test | gpg --clearsign` zum Prüfen. Bei Schlüsseln ohne Passphrase auf dem
Host reicht der Mount; sonst ist ein `gpg --card-status` bzw. eine
Agent-Weiterleitung nötig. Alternative ohne GPG:
`DEVKIT_GIT_SIGN_FORMAT=ssh`.

**Skripte scheitern mit `bad interpreter: /bin/bash^M`**
Die Dateien wurden mit CRLF ausgecheckt. `.gitattributes` erzwingt LF –
Repository neu klonen oder `git add --renormalize .` ausführen.
