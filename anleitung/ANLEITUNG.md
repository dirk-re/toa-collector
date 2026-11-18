# Anleitung: S7-1500 → MQTT → TimescaleDB (10 Clients, Windows 11)

Dieses Paket enthält den vollständigen Quellcode, alle Konfigurationen und
diese Anleitung für den Aufbau einer Messdatenerfassung mit Pufferung bei
Netzwerkausfall.

## 1. Paketinhalt und Zielorte

| Datei in diesem Paket | Zielort |
|---|---|
| `anleitung/ANLEITUNG.md` | Nur Dokumentation |
| `LIZENZEN.md` | Nur Dokumentation (Komponenten- und Lizenzübersicht) |
| `client/config.ini` | `C:\s7-client\config.ini` (je Client anpassen) |
| `client/s7_publisher.py` | `C:\s7-client\s7_publisher.py` |
| `client/mosquitto_client.conf` | `C:\Program Files\mosquitto\mosquitto.conf` (ersetzt die Standardkonfiguration) |
| `server/schema.sql` | DB-Gerät, einmalig mit psql ausführen |
| `server/mosquitto_zentral.conf` | DB-Gerät: Linux `/etc/mosquitto/mosquitto.conf`, Windows `C:\Program Files\mosquitto\mosquitto.conf` |
| `server/db_writer.py` | DB-Gerät: Linux `/opt/s7/db_writer.py`, Windows `C:\s7\db_writer.py` |
| `server/db-writer.service` | Nur Linux: `/etc/systemd/system/db-writer.service` |

## 2. Architektur

```
Client 01 (Win11):  S7-1500 → s7_publisher.py → Mosquitto (lokal) ──┐
Client 02 (Win11):  S7-1500 → s7_publisher.py → Mosquitto (lokal) ──┤  Bridges
   ...                                                             ├──▶ Zentraler Mosquitto (DB-Gerät) ──▶ db_writer.py ──▶ TimescaleDB
Client 10 (Win11):  S7-1500 → s7_publisher.py → Mosquitto (lokal) ──┘
```

Pufferungsverhalten:

- Fällt das Netzwerk oder der zentrale Broker aus, hält jeder lokale Broker
  die QoS-1-Nachrichten in seiner Warteschlange vor (`max_queued_messages`)
  und liefert sie nach dem Reconnect der Bridge automatisch nach.
- Fällt die Datenbank aus, bestätigt der db_writer keine Nachricht vor dem
  erfolgreichen Commit; der zentrale Broker überträgt sie erneut.
- Fällt die S7-1500 aus, verbindet sich der Publisher mit Wartezeit neu.
- Duplikate (QoS 1 = "mindestens einmal") werden über den Primärschlüssel
  `(time, message_id, tag)` in der Datenbank aussortiert.

Jeder Client benötigt eine eindeutige `client_id`, einen eigenen Topic-Präfix
(`s7/client-01/data` … `s7/client-10/data`), eine eigene `site_id` sowie
je Tag `device_id` und eine eindeutige `channel_id`.

## 3. Vorbereitung der S7-1500 im TIA Portal (pro Steuerung einmalig)

1. CPU markieren → Properties → Protection & Security → Connection mechanisms →
   Häkchen bei "Allow access from remote partner" und darunter "Permit access
   with PUT/GET communication from remote partner".
2. Für jeden zu lesenden Datenbaustein: Häkchen bei "Optimized block access"
   entfernen (sonst sind keine absoluten Adressen lesbar). Die festen Offsets
   der Variablen tragen Sie später im Abschnitt `[tags]` der config.ini ein.
3. Projekt kompilieren und in die CPU übertragen.
4. Rack und Slot der S7-1500: Rack 0, Slot 1.

## 4. Installation auf einem Client-Gerät (Windows 11)

Alle Schritte als Administrator in PowerShell. Auf allen zehn Geräten
identisch, nur config.ini und MQTT-Benutzername unterscheiden sich.

### 4.1 Software installieren

```powershell
# Python 3.12 (oder neuer): offizieller Installer,
# Häkchen "Add python.exe to PATH" setzen.

# Mosquitto: offiziellen Windows-Installer von mosquitto.org installieren
# und die Komponente "Service" auswählen. Der Installer registriert den
# Windows-Dienst "mosquitto" über den eingebauten Dienstmodus von mosquitto.exe
# (Aufrufargument "run") und setzt die Systemvariable MOSQUITTO_DIR auf das
# Installationsverzeichnis. Im Dienstmodus liest Mosquitto seine Konfiguration
# aus diesem Verzeichnis.

# Python-Pakete:
pip install paho-mqtt python-snap7
# python-snap7 ab Version 3.0 ist reines Python, keine snap7.dll erforderlich.

# NSSM: nssm.exe von nssm.cc laden und nach C:\Tools\nssm.exe legen.

# Verzeichnisse anlegen:
mkdir C:\s7-client, C:\s7-client\logs, C:\mosquitto-data
```

### 4.2 Dateien kopieren und konfigurieren

1. `s7_publisher.py` nach `C:\s7-client\` kopieren.
2. `config.ini` nach `C:\s7-client\` kopieren und anpassen:
   - `[geraet]`: `client_id`, `site_id` (z. B. s7-client-02),
   - `[plc]`: IP-Adresse der S7-1500,
   - `[mqtt]`: Benutzer, Passwort, Topic-Präfix,
   - `[tags]`: Geraete-ID, Kanal-ID, DB-Nummer, Startbyte,
     Typ (und Bitnummer bei bool) je Variable.
3. `mosquitto_client.conf` als `C:\Program Files\mosquitto\mosquitto.conf`
   speichern (ersetzt die Standardkonfiguration) und darin `ZENTRAL-IP`
   auf die Adresse des Datenbankgeräts setzen.

### 4.3 Mosquitto-Benutzer anlegen und Dienst starten

```powershell
cd "C:\Program Files\mosquitto"
.\mosquitto_passwd.exe -c passwd sensor-01
# Weitere Benutzer ohne -c hinzufuegen, z. B.:
# .\mosquitto_passwd.exe -b passwd client-02 CLIENT_PASSWORT
Restart-Service mosquitto
```

Wichtig: `C:\mosquitto-data` muss für das Dienstkonto, unter dem Mosquitto
läuft, beschreibbar sein (Rechte über die Registerkarte "Sicherheit" prüfen).

Hinweis: Der Mosquitto-Dienst liest seine Konfiguration aus dem in der
Systemvariable MOSQUITTO_DIR hinterlegten Verzeichnis (vom Installer
gesetzt), nicht aus dem aktuellen Arbeitsverzeichnis.

Startet der Dienst nicht und bleibt in der Dienste-Verwaltung auf "Beendet"
stehen (SC-Fehler 1053: "Der Dienst antwortete nicht rechtzeitig auf die
Start- oder Steuerungsanforderung"), obwohl der manuelle Start mit
`mosquitto.exe -c mosquitto.conf` funktioniert, wurde der Dienst meist
manuell per `sc create` mit einem `-c`-Argument statt über den Installer
bzw. `mosquitto.exe install` registriert. mosquitto.exe meldet sich in
diesem Fall nicht beim Windows-Dienststeuerungs-Manager. Prüfen mit
`sc qc mosquitto`: Der BINARY_PATH_NAME muss auf
`"...\mosquitto.exe" run` lauten. Falls nicht, Dienst entfernen und
korrekt neu registrieren:

```powershell
sc.exe stop mosquitto
sc.exe delete mosquitto
cd "C:\Program Files\mosquitto"
.\mosquitto.exe install
sc.exe start mosquitto
```

### 4.4 Publisher testen und als Dienst einrichten

Zuerst manuell prüfen:

```powershell
python C:\s7-client\s7_publisher.py --config C:\s7-client\config.ini
```

Läuft der Test erfolgreich, als Windows-Dienst einrichten (NSSM):

```powershell
C:\Tools\nssm.exe install S7Publisher "C:\Program Files\Python312\python.exe"
C:\Tools\nssm.exe set S7Publisher AppParameters "--config C:\s7-client\config.ini"
C:\Tools\nssm.exe set S7Publisher AppDirectory "C:\s7-client"
C:\Tools\nssm.exe set S7Publisher AppStdout "C:\s7-client\logs\stdout.log"
C:\Tools\nssm.exe set S7Publisher AppStderr "C:\s7-client\logs\stderr.log"
C:\Tools\nssm.exe set S7Publisher AppRotateFiles 1
Start-Service S7Publisher
```

## 5. Installation auf dem Datenbankgerät

### 5.1 PostgreSQL mit TimescaleDB (Debian 13)

Debian 13 ("trixie") liefert PostgreSQL 17. Die TimescaleDB-Pakete stammen
aus der offiziellen Paketquelle von Timescale (packagecloud); das
kommerzielle TSL-Paket (`timescaledb-2-postgresql-17`, ohne `-oss-` im
Namen) deckt die interne Nutzung ab:

```bash
# PostgreSQL-Community-Repository (PGDG) einrichten:
apt update
apt install -y gnupg postgresql-common apt-transport-https lsb-release wget
/usr/share/postgresql-common/pgdg/apt.postgresql.org.sh

# TimescaleDB-Repository hinzufuegen:
echo "deb https://packagecloud.io/timescale/timescaledb/debian/ trixie main" \
  > /etc/apt/sources.list.d/timescaledb.list
wget --quiet -O - https://packagecloud.io/timescale/timescaledb/gpgkey \
  | gpg --dearmor -o /etc/apt/trusted.gpg.d/timescaledb.gpg
apt update

# TimescaleDB fuer PostgreSQL 17 installieren und konfigurieren:
apt install -y timescaledb-2-postgresql-17 timescaledb-tools
timescaledb-tune --pg-config=/usr/lib/postgresql/17/bin/pg_config
systemctl restart postgresql
```

Dann Datenbank anlegen, Erweiterung aktivieren und das Schema einspielen:

```bash
su - postgres
createdb sensordaten
psql -d sensordaten -c "CREATE EXTENSION timescaledb;"
psql -d sensordaten -f schema.sql
```

Datenbankbenutzer `writer` anlegen und Rechte auf die Tabelle erteilen:

```bash
psql -d sensordaten -c "CREATE USER writer WITH PASSWORD 'GEHEIM';"
psql -d sensordaten -c "GRANT INSERT, SELECT ON measurements TO writer;"
```

### 5.2 Zentraler Mosquitto-Broker (Debian 13)

1. Mosquitto installieren (der Dienst startet automatisch mit der
   Standardkonfiguration):

```bash
apt install -y mosquitto mosquitto-clients
```

2. `mosquitto_zentral.conf` als `/etc/mosquitto/mosquitto.conf` speichern.
3. Benutzer anlegen:
   - `dbwriter` (für die zehn Bridges der Clients),
   - `db-subscriber` (für den db_writer).

```bash
systemctl stop mosquitto
mosquitto_passwd -c /etc/mosquitto/passwd dbwriter
mosquitto_passwd -b /etc/mosquitto/passwd db-subscriber GEHEIM
chown mosquitto:mosquitto /etc/mosquitto/passwd
systemctl restart mosquitto
```

Hinweis: Das Persistenzverzeichnis `/var/lib/mosquitto/` legt das
Debian-Paket bereits mit korrekten Rechten an.

### 5.3 db_writer

1. `db_writer.py` nach `/opt/s7/` (Linux) bzw. `C:\s7\` (Windows) kopieren.
2. Im Kopf der Datei die Konfiguration anpassen:
   `BROKER_USER`, `BROKER_PASS`, `DB_DSN` (Datenbank, Benutzer, Passwort).
3. Abhängigkeiten: `pip install paho-mqtt psycopg2-binary`
4. Als Dienst einrichten:

Linux (systemd): `db-writer.service` nach
`/etc/systemd/system/` kopieren, dann:

```bash
systemctl daemon-reload
systemctl enable --now db-writer
```

Windows: NSSM wie in Abschnitt 4.4, mit Programm `python.exe` und
AppParameters `C:\s7\db_writer.py`, Dienstname z. B. `S7DbWriter`.

## 6. Inbetriebnahme in dieser Reihenfolge

1. DB-Gerät: Schema anlegen, zentralen Broker konfigurieren, Benutzer
   anlegen, db_writer starten.
2. Ein Client-Gerät vollständig einrichten, Publisher manuell starten.
3. Kontrolle am DB-Gerät:
   `mosquitto_sub -t "s7/#" -v` zeigt die eintreffenden Nachrichten;
   `SELECT * FROM measurements ORDER BY time DESC LIMIT 20;` zeigt die Zeilen.
4. Ausfalltest: Netzwerkverbindung des Clients trennen, einige Minuten
   Messwerte erzeugen lassen, Verbindung wiederherstellen und prüfen,
   dass die Lücke in der Tabelle geschlossen wird.
5. Publisher als Dienst installieren und die Schritte 2 bis 4 für die
   übrigen neun Clients wiederholen.

## 7. Mehrere S7-1500 an einem Client-Gerät

Ein Client-Gerät kann mehrere Steuerungen bedienen. Pro Steuerung wird eine
eigene Publisher-Instanz betrieben:

1. Je Steuerung eine eigene `config.ini` anlegen, z. B. `config-presse.ini`
   und `config-drehmaschine.ini`. Darin jeweils eindeutige Werte vergeben:
   `client_id`, `site_id`, `topic` und die PLC-IP. Die Tag-Liste je
   Steuerung individuell eintragen.
2. Pro Instanz einen eigenen Windows-Dienst einrichten (NSSM):

```powershell
C:\Tools\nssm.exe install S7Publisher-Presse "C:\Program Files\Python312\python.exe"
C:\Tools\nssm.exe set S7Publisher-Presse AppParameters "--config C:\s7-client\config-presse.ini"
C:\Tools\nssm.exe set S7Publisher-Presse AppDirectory "C:\s7-client"
C:\Tools\nssm.exe set S7Publisher-Presse AppRotateFiles 1
Start-Service S7Publisher-Presse
```

3. Jede Instanz schreibt ihre eigene Log-Datei
   (`publisher-{client_id}.log`); die Dateien vermischen sich nicht.
4. Jede Instanz veröffentlicht unter ihrem eigenen Topic
   (`s7/presse/data`, `s7/drehmaschine/data`). Die Bridge leitet `s7/#`
   weiter, der db_writer empfängt alles; in der Tabelle unterscheiden
   `site_id`, `device_id` und `channel_id` die Herkunft.

Der lokale Mosquitto-Broker und die Bridge werden nur einmal pro
Client-Gerät betrieben; die Pufferung bei Netzwerkausfall gilt gemeinsam
für alle Instanzen auf dem Gerät.

## 8. Fehlersuche

| Symptom | Prüfen |
|---|---|
| Publisher startet nicht | config.ini vorhanden? Log in `C:\s7-client\logs\`, Konsole manuell starten |
| Mosquitto-Dienst startet nicht (Fehler 1053) | `sc qc mosquitto`: BINARY_PATH_NAME muss `"...\mosquitto.exe" run` lauten, sonst Dienst per `sc.exe delete mosquitto` entfernen und mit `mosquitto.exe install` neu registrieren (Abschnitt 4.3); MOSQUITTO_DIR gesetzt? |
| Keine Werte, "PLC nicht erreichbar" | IP, Rack 0/Slot 1, PUT/GET im TIA Portal freigegeben, DB nicht optimiert |
| Keine Nachrichten am zentralen Broker | Bridge-Konfiguration, ZENTRAL-IP, Benutzer/Passwort, Windows-Firewall (Port 1883) |
| Tabelle bleibt leer | db_writer-Log, DB_DSN, Rechte des Datenbankbenutzers |
| Lücken in der Tabelle | `max_queued_messages` groß genug? Persistenzverzeichnis beschreibbar? |

## 9. Hinweise für den Betrieb

- Computer-Uhr der Clients per NTP synchronisieren, da der Zeitstempel beim
  Client erzeugt wird.
- Die `client_id` des db_writer niemals ändern; die persistente Broker-Session
  hängt daran.
- Bei hohen Datenraten BATCH_MAX und BATCH_SEKUNDEN im db_writer erhöhen oder
  mehrere db_writer-Prozesse betreiben (einer pro Client-Topic).
- Für unsichere Netze TLS einrichten (Port 8883, Zertifikate auf beiden
  Brokern und in den Bridges).
