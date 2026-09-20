# Windows 11 Desktop

Ein vollwertiger Windows-11-Desktop pro Studierendem, erreichbar per
Remote Desktop (RDP). Gedacht fuer Kurse, die echtes Windows brauchen —
Office, Visual Studio, Windows-spezifische Werkzeuge.

## Zugriff

Jeder Nutzer erhaelt **eine eigene VM** und verbindet sich mit dem
Remote-Desktop-Client:

- **Windows:** `mstsc` (vorinstalliert)
- **macOS / iOS / Android:** "Windows App" von Microsoft (kostenlos)
- **Linux:** Remmina oder FreeRDP

Der AppStore zeigt den fertigen Verbindungsbefehl an und verschickt ihn
zusammen mit Benutzername und Passwort per Mail.

> **IPv6 erforderlich.** Die VMs sind ausschliesslich ueber IPv6
> erreichbar — die Cloud vergibt keine oeffentlichen IPv4-Adressen. Das
> gilt fuer alle Apps dieser Plattform, nicht nur fuer diese. Aus dem
> DHBW-Netz und per VPN funktioniert es; aus einem reinen
> IPv4-Anschluss nicht.

## Warum eine VM pro Nutzer?

Nicht aus Lizenzgruenden, sondern technisch: **Windows 11 Client
erlaubt genau eine interaktive Sitzung gleichzeitig.** Meldet sich ein
zweiter Nutzer per RDP an, wird der erste getrennt. Das Modell der
Linux-Apps (eine gemeinsame VM, viele SSH-Nutzer) ist hier nicht
uebertragbar:

- **Windows 11 Enterprise multi-session** ist Azure-exklusiv und darf
  auf der eigenen OpenStack-Umgebung nicht betrieben werden.
- **Windows Server + RDS-CALs** waere der legitime Mehrbenutzer-Weg,
  ist von der A3-Lizenzierung der Hochschule aber nicht abgedeckt.

Lizenzrechtlich gilt zusaetzlich: die Windows-Enterprise-/VDA-Rechte aus
Microsoft 365 A3 haengen **am benannten Nutzer**. Es darf also nur
deployt werden fuer Personen, die selbst lizenziert sind. Die genauen
Vertragsbedingungen sind mit der Lizenzstelle der DHBW abzuklaeren.

## Kapazitaet — wichtig bei der Kursplanung

Die Projekt-Quota begrenzt die Anzahl gleichzeitiger Desktops. Bei
`win11.medium` (2 vCPU / 8 GB / 80 GB) ist der **Arbeitsspeicher** der
limitierende Faktor:

| Ressource | Limit | Reicht fuer |
|---|---|---|
| RAM | 131 072 MB (abzgl. laufender Infrastruktur) | **~12 Desktops** |
| vCPU | 50 | 20 Desktops |
| Instanzen | 30 | 27 Desktops |

Kleiner als 8 GB geht nicht: das Image verlangt `min_disk = 64 GB`, und
kein Flavor mit >= 64 GB Disk hat weniger als 8 GB RAM. **Ein Kurs mit
25 Teilnehmenden passt nicht** — entweder in Gruppen deployen oder die
Quota erhoehen lassen.

Die VMs booten vom Image auf ephemeren Datentraeger, belegen also
**keine** Block-Storage-Quota (die ist mit 200 von 256 GB fast
ausgeschoepft). Das bedeutet zugleich: **keine persistenten
Datentraeger** — beim Zerstoeren des Deployments sind alle Daten weg.
Studierende muessen ihre Arbeit selbst sichern.

## User-Management

- **Ein lokales Konto pro Nutzer**, abgeleitet aus der Mailadresse
  (`alice.smith@dhbw.de` -> `alicesmith`, max. 20 Zeichen).
- Zufaelliges 20-stelliges Passwort pro Nutzer, vom AppStore per Mail
  zugestellt.
- Mitglied in *Remotedesktopbenutzer* — aufgeloest ueber die
  well-known SID `S-1-5-32-555`, weil das Image deutschsprachig ist und
  der englische Gruppenname nicht existiert.
- **Standardmaessig kein lokaler Administrator** (`student_is_admin`).
- Das eingebaute Konto `Administrator` ist im Basis-Image **deaktiviert**
  und bleibt es. Es wird kein Admin-Zugang ausgeliefert.

## VM-Deployment

| | |
|---|---|
| VMs gesamt | **1 pro Nutzer** |
| Flavor | `win11.medium` (konfigurierbar) |
| Image | Packer-Build auf Basis von `Windows 11 25H2 (UEFI)` |
| Netz | konfigurierbar, oeffentliches IPv6 |
| Zugang | RDP / TCP 3389 |

## Konfigurierbare Variablen

| Variable | Beschreibung | Default |
|---|---|---|
| `network_uuid` | Netzwerk der VMs | — (Pflicht) |
| `flavor_name` | VM-Groesse; >= 4 GB RAM und >= 64 GB Disk | `win11.medium` |
| `rdp_allowed_prefixes` | IPv6-Praefixe, die RDP erreichen duerfen | `2001:7c0:1b20::/48` |
| `kms_host` | KMS-Server fuer die Aktivierung | `""` (DNS-Discovery) |
| `student_is_admin` | Studierende als lokale Admins | `false` |

## Sicherheit

- **RDP nie auf `::/0` oeffnen.** `rdp_allowed_prefixes` ist auf das
  DHBW-Praefix vorbelegt. RDP mit Passwort-Login am offenen Netz ist ein
  bekanntes Brute-Force-Ziel.
- **NLA ist aktiv**, dazu eine Kontosperre (10 Versuche / 15 Minuten).
- **Egress-Allowlist:** die Security Group erlaubt ausgehend nur DNS,
  HTTP/HTTPS, NTP und KMS. Das ist bewusst: alle VMs dieses Projekts
  haengen am selben geteilten Netz. Ohne diese Allowlist koennte ein
  uebernommener Studierenden-Desktop andere Hosts desselben Netzes auf
  beliebigen Ports erreichen statt nur ueber Web-Protokolle.
- **Passwoerter liegen im Terraform-State** (`random_password` wird dort
  im Klartext abgelegt) und gehen per Mail raus. Das ist eine bewusste
  Abwaegung: es sind Einweg-Zugaenge zu wegwerfbaren Lab-VMs. Der
  State-Postgres gehoert entsprechend geschuetzt.
- **`user_data` ist von der VM aus lesbar** (Metadata-Service und
  Config-Drive) — das ist OpenStack-inhaerent. Vertretbar, weil dort
  ausschliesslich das Passwort des jeweils eigenen Nutzers steht.
  **Niemals ein geteiltes Geheimnis in `bootstrap.ps1.tpl` legen.**

## Aktivierung

Das Basis-Image ist `VOLUME_KMSCLIENT`, also fuer KMS-Aktivierung
vorbereitet. Der Bootstrap ruft `slmgr /ato` auf. Findet die
DNS-Discovery (`_vlmcs._tcp`) keinen KMS-Server, muss `kms_host` gesetzt
werden — Adresse bei der DHBW-IT erfragen.

## Patchstand

Der Packer-Build spielt **bewusst keine Windows-Updates ein**: der
Worker bricht Builds nach 3600 s ab, was ein voller Update-Lauf allein
reissen kann. Patches kommen dadurch, dass dieses Image regelmaessig neu
gebaut wird — immer gegen das **unveraenderte** Hersteller-Image, denn
Sysprep `/generalize` hat ein Rearm-Limit von ca. 3.

## Deployment-Dauer

| Schritt | Dauer (ca.) |
|---|---|
| Packer Image Build | 20–45 min |
| Terraform apply | 5–10 min |
| Windows-Erststart bis RDP bereit | 3–6 min nach `apply` |

Terraform meldet die VM als fertig, bevor Windows durchgebootet ist.
Studierende sollten nach dem Deployment einige Minuten warten.

## Aenderungen in diesem Release

- Erstversion.
