# Root-CA-Zertifikate

Zertifikate, die in diesem Verzeichnis liegen, werden automatisch installiert:

1. **beim Image-Build** – damit Downloads (Adoptium, Gradle, OpenCode) hinter
   einem TLS-inspizierenden Proxy funktionieren;
2. **bei jedem Container-Start** – in den System-Truststore
   (`/etc/ssl/certs/ca-certificates.crt`) *und* in den Java-Truststore
   (`$JAVA_HOME/lib/security/cacerts`, Alias-Präfix `devkit-`).

## Verwendung

Zertifikatsdatei hierher kopieren, z. B. `corporate-root-ca.crt`:

```
.devcontainer/certs/
├── corporate-root-ca.crt
└── corporate-issuing-ca.crt
```

Akzeptierte Endungen: `.crt`, `.pem`, `.cer` (PEM oder DER). Bündel mit mehreren
Zertifikaten in einer Datei werden automatisch aufgeteilt.

* Bereits laufender Container: `devkit certs install`
* Nach dem Hinzufügen für den Image-Build: **Rebuild** des Containers
  (IntelliJ / VS Code: *Rebuild Container*)
* Prüfen: `devkit certs list` bzw. `devkit doctor`

## Hinweise

* Die Zertifikatsdateien sind per `.gitignore` vom Einchecken ausgeschlossen.
  Soll die Firmen-CA im Repository liegen, die entsprechende Zeile in
  `.gitignore` anpassen.
* Für Docker-Registries mit eigenem Zertifikat kann zusätzlich
  `DEVKIT_DOCKER_REGISTRIES="registry.example.com:5000"` gesetzt werden; das
  Bundle wird dann auch nach `/etc/docker/certs.d/<host>/ca.crt` gelegt.
