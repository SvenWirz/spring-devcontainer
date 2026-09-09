# Gradle-Init-Skripte

Alle `*.gradle` und `*.gradle.kts` aus diesem Verzeichnis werden nach
`$GRADLE_USER_HOME/init.d/` verlinkt und dadurch von **jedem** Gradle-Build im
Container automatisch geladen – auch von Builds, die über den Gradle-Wrapper
eines einzelnen Repositories laufen.

Typische Anwendungsfälle:

* Umleitung aller Repositories auf einen internen Nexus/Artifactory-Mirror
  (siehe `10-corporate-repository.gradle.kts.example`)
* Erzwingen einer Java-Toolchain
* Zentrale Build-Scan- oder Cache-Konfiguration

Dateien mit der Endung `.example` werden **nicht** verlinkt – zum Aktivieren die
Endung entfernen. Änderungen wirken sofort, ein Container-Neustart ist nicht
nötig (`devkit config link` erneuert die Verknüpfungen bei Bedarf).
