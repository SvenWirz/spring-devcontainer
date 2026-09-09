# Arbeitsanweisungen für OpenCode in dieser Entwicklungsumgebung

Diese Datei wird als globale Instruktion in jede OpenCode-Session geladen
(`~/.config/opencode/AGENTS.md`). Projektspezifische `AGENTS.md`-Dateien im
jeweiligen Repository ergänzen bzw. überschreiben diese Vorgaben.

## Umgebung

* Container mit Eclipse Temurin JDK 21 (`JAVA_HOME=/usr/lib/jvm/temurin-21`)
  und Gradle. Die Repositories liegen unter `/src`, jedes Verzeichnis dort ist
  ein eigenständiger Microservice.
* Builds laufen bevorzugt über den Gradle-Wrapper des jeweiligen Repositories
  (`./gradlew`), nicht über das global installierte `gradle`.
* Ein eigener Docker-Daemon läuft im Container (Docker-in-Docker). Testcontainers
  und `docker compose` funktionieren, Container laufen aber **nicht** auf dem Host.

## Erwartetes Vorgehen

* Vor Änderungen den betroffenen Service verstehen: Build-Datei, Package-Struktur
  und bestehende Tests lesen.
* Änderungen mit `./gradlew test` bzw. für einzelne Tests mit
  `./gradlew test --tests "<Klasse>"` verifizieren. Bei Integrationstests mit
  Testcontainers ist der erste Lauf langsam (Image-Pull).
* Nur ein Repository pro Aufgabe anfassen, sofern nicht ausdrücklich anders
  gefordert. Änderungen an mehreren Services immer explizit benennen.
* Keine Commits oder Pushes ohne ausdrückliche Aufforderung.

## Konventionen für Spring-Boot-Code

* Konstruktor-Injection statt `@Autowired` auf Feldern.
* Konfiguration über typsichere `@ConfigurationProperties`-Klassen statt
  verstreuter `@Value`-Annotationen.
* Kein Feld-, Methoden- oder Klassen-Kommentar, der nur den Code wiederholt.
* Fachliche Ausnahmen als eigene Exception-Typen, Übersetzung nach HTTP in einem
  zentralen `@RestControllerAdvice`.
* Tests: `@SpringBootTest` nur wenn nötig; für einzelne Schichten `@WebMvcTest`,
  `@DataJpaTest` oder reine Unit-Tests mit JUnit 5 und AssertJ.
* Neue Abhängigkeiten zurückhaltend hinzufügen und dabei das vom Spring-Boot-BOM
  verwaltete Versionsschema respektieren (keine expliziten Versionen, wenn das
  BOM sie bereits vorgibt).

## Netzwerk und Zugangsdaten

* Der Container läuft unter Umständen hinter einem TLS-inspizierenden Proxy; die
  Firmen-Root-CA ist bereits im System- und Java-Truststore installiert. Zertifikats-
  fehler daher nicht mit `-k`, `--insecure` oder deaktivierter TLS-Prüfung umgehen,
  sondern melden.
* Zugangsdaten stehen in `gradle.properties` oder Umgebungsvariablen. Sie dürfen
  niemals in Quellcode, Testdaten oder Commit-Nachrichten auftauchen.
