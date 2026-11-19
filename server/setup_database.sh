#!/usr/bin/env bash
#===============================================================================
# setup_database.sh - Datenbank-Ersteinrichtung fuer toa-collector (Debian 13)
#
# Fuehrt alle Schritte der Datenbankeinrichtung in einem Durchgang aus:
#   1. Datenbank anlegen (falls nicht vorhanden)
#   2. TimescaleDB-Erweiterung aktivieren
#   3. schema.sql einspielen (Messtabelle, Hypertable, Index)
#   4. aggregations.sql einspielen (Komprimierung, Langzeit-Aggregate,
#      Aufbewahrung; einmalig NACH schema.sql)
#   5. Datenbankbenutzer fuer den db_writer anlegen bzw. Passwort aktualisieren
#      und Rechte erteilen
#   6. Verbindungstest mit den eingerichteten Zugangsdaten
#   7. Ausgabe der fertigen DB_DSN-Zeile fuer server/db_writer.py
#
# Voraussetzungen:
#   - Debian 13 mit PostgreSQL 17 und TimescaleDB-Extension
#     (Paketinstallation: ANLEITUNG.md, Abschnitt 5.1)
#     ODER TimescaleDB im Docker-Container: dann im Konfigurationsblock
#     DB_UEBER_DOCKER="yes" und DOCKER_CONTAINER auf den Containernamen
#     setzen. Alle Datenbankbefehle laufen dann ueber docker exec im
#     Container; eine Paketinstallation auf dem Host ist nicht noetig.
#   - Aufruf als root oder mit sudo:
#       sudo bash setup_database.sh
#     (im Docker-Modus genuegt die Mitgliedschaft in der Gruppe docker)
#   - schema.sql und aggregations.sql im selben Verzeichnis wie dieses
#     Skript. Sie muessen nicht im Container liegen: das Skript spielt
#     sie ueber stdin ein.
#
# Das Skript ist idempotent: ein erneuter Aufruf ist unproblematisch
# (IF NOT EXISTS / if_not_exists). Bei einer Wiederholung auf einer
# Installation mit grosser Historie laeuft die Erstabfuellung in
# aggregations.sql (Abschnitt 4 der Datei) erneut und kann entsprechend
# lange dauern.
#
#-------------------------------------------------------------------------------
# ANZUPASSENDE STELLEN FUER DATENBANK-ZUGANGSDATEN
#-------------------------------------------------------------------------------
# (1) DIESES SKRIPT: Konfigurationsblock direkt unter diesem Kommentar.
#     Alle Datenbankangaben werden hier vorgegeben; schema.sql und
#     aggregations.sql muessen NICHT bearbeitet werden. Das Skript ersetzt
#     den Standard-Tabellennamen "measurements" in den SQL-Dateien
#     automatisch durch DB_TABLE (einschliesslich der abgeleiteten Namen
#     *_1min, *_1h, *_1day) und legt den Benutzer samt Passwort an.
#     Laeuft die Datenbank im Docker-Container, zusaetzlich
#     DB_UEBER_DOCKER="yes" und DOCKER_CONTAINER setzen. Wurde der Container
#     mit POSTGRES_USER=<andererName> statt des Standards "postgres"
#     erstellt, zudem DB_ADMIN_USER auf diesen Namen setzen (sonst meldet
#     der Container "role postgres does not exist").
#
# (2) server/db_writer.py - Konfigurationsblock am Dateianfang
#     (ca. Zeilen 16 bis 23). Muss die gleichen Werte wie dieses Skript
#     verwenden:
#       - DB_DSN (ca. Zeile 21), Zwischenstand im Paket:
#           DB_DSN = "host=127.0.0.1 dbname=sensordaten user=writer password=GEHEIM"
#         Diese Werte muessen den Angaben hier entsprechen:
#           host     -> DB_HOST      (Adresse des DB-Geraets; bei Docker
#                                   laeuft db_writer.py auf dem Host und
#                                   verbindet sich auf den veroeffentlichten
#                                   Port, sofern nicht selbst containerisiert)
#           dbname   -> DB_NAME
#           user     -> DB_USER
#           password -> DB_PASSWORD
#       - Bei abweichendem Tabellennamen (DB_TABLE != "measurements")
#         zusaetzlich INSERT_SQL anpassen (ca. Zeilen 26 bis 30):
#           "INSERT INTO measurements (time, ..." -> "INSERT INTO <DB_TABLE> ..."
#       - BROKER_USER und BROKER_PASS (ca. Zeilen 18 und 19) sind die
#         MQTT-Zugangsdaten des zentralen Mosquitto-Brokers und KEINE
#         Datenbank-Zugangsdaten; sie muessen mit den Benutzern aus
#         ANLEITUNG.md Abschnitt 5.2 uebereinstimmen.
#
# (3) client/s7_publisher.py - enthaelt KEINE Datenbank-Zugangsdaten.
#     Seine MQTT-Zugangsdaten stehen in client/config.ini im Abschnitt
#     [mqtt] (lokaler Client-Broker, nichts Datenbankbezogenes).
#
# Das Skript gibt am Ende die exakte DB_DSN-Zeile aus, die in db_writer.py
# einzutragen ist.
#===============================================================================
set -euo pipefail

#=============================== KONFIGURATION =================================
# Hier alle Werte der Datenbank vorgeben. DB_NAME, DB_USER und DB_TABLE
# duerfen nur Buchstaben, Ziffern und Unterstriche enthalten und nicht mit
# einer Ziffer beginnen (Kleinschreibung ohne Sonderzeichen empfohlen).

DB_NAME="sensordaten"      # Name der Datenbank
DB_USER="writer"           # Datenbankbenutzer fuer den db_writer
DB_PASSWORD="GEHEIM"       # Passwort des Datenbankbenutzers
DB_TABLE="measurements"    # Name der Messtabelle (Standard: measurements)
DB_HOST="127.0.0.1"        # Adresse, unter der db_writer.py die
                           # Datenbank erreicht (bei Docker: Adresse des
                           # Hosts, wenn der Port veroeffentlicht ist)
DB_PORT="5432"             # PostgreSQL-Port (bei Docker: der in -p
                           # veroeffentlichte Host-Port)

# Laeuft die Datenbank in einem Docker-Container (z. B. offizielles Image
# timescale/timescaledb)?
#   yes = alle Datenbankbefehle laufen ueber docker exec im Container
#         (DOCKER_CONTAINER auf den Containernamen setzen, siehe 'docker ps');
#         auf dem Host ist keine Paketinstallation noetig.
#   no  = native installiertes PostgreSQL auf diesem Geraet
#         (Standardweg aus ANLEITUNG.md, Abschnitt 5.1).
DB_UEBER_DOCKER="no"
DOCKER_CONTAINER="timescaledb"

# Administrator-Zugang fuer die Einrichtung (SUPERUSER-Rolle):
#   Docker-Modus: Standard des offiziellen Images ist "postgres"
#     (timescale/timescaledb). Wurde der Container mit
#     POSTGRES_USER=<andererName> erstellt, hier genau diesen Namen
#     eintragen (pruefen mit: docker exec <Container> env | grep ^POSTGRES).
#   Native Installation: immer "postgres" lassen (das Skript arbeitet dort
#     als Systembenutzer postgres).
DB_ADMIN_USER="postgres"

# Soll der Benutzer ausserdem die drei Aggregat-Views lesen duerfen
# (${DB_TABLE}_1min, ${DB_TABLE}_1h, ${DB_TABLE}_1day; nuetzlich fuer
# Auswertungen)? yes = Rechte erteilen, no = nur Schreib-/Lesezugriff
# auf die Messtabelle.
GRANT_AGGREGATE_READ="yes"

#========================== ab hier keine Aenderungen ==========================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA_SQL="$SCRIPT_DIR/schema.sql"
AGGREGATIONS_SQL="$SCRIPT_DIR/aggregations.sql"

log()  { echo "[OK]      $*"; }
info() { echo "[Hinweis] $*"; }
err()  { echo "[Fehler]  $*" >&2; }
die()  { err "$*"; exit 1; }

# Datenbankbefehle als PostgreSQL-Administrator ausfuehren:
# im Docker-Modus im Container, ansonsten als Systembenutzer postgres.
as_pg() {
    if [ "$DB_UEBER_DOCKER" = "yes" ]; then
        docker exec -i "$DOCKER_CONTAINER" "$@"
    elif [ "$(id -u)" -eq 0 ]; then
        runuser -u postgres -- "$@"
    else
        sudo -u postgres -- "$@"
    fi
}

#-------------------------------------------------------------------------------
# Vorpruefungen
#-------------------------------------------------------------------------------
[ -r "$SCHEMA_SQL" ]         || die "schema.sql nicht gefunden in: $SCRIPT_DIR"
[ -r "$AGGREGATIONS_SQL" ]   || die "aggregations.sql nicht gefunden in: $SCRIPT_DIR"
[ -n "$DB_PASSWORD" ]        || die "DB_PASSWORD ist leer. Bitte ein Passwort vergeben."
case "$GRANT_AGGREGATE_READ" in yes|no) ;; *) die "GRANT_AGGREGATE_READ muss yes oder no sein." ;; esac
case "$DB_UEBER_DOCKER"       in yes|no) ;; *) die "DB_UEBER_DOCKER muss yes oder no sein." ;; esac

for var_name in DB_NAME DB_USER DB_TABLE; do
    val="${!var_name}"
    case "$val" in
        ""|[0-9]*|*[!A-Za-z0-9_]*)
            die "$var_name ('$val') ist kein gueltiger SQL-Identifier (nur Buchstaben, Ziffern, Unterstrich; darf nicht mit einer Ziffer beginnen)." ;;
    esac
done

if [ "$DB_UEBER_DOCKER" = "yes" ]; then
    command -v docker >/dev/null 2>&1 || die "docker nicht gefunden. DB_UEBER_DOCKER=\"yes\" benoetigt die docker-CLI."
    [ -n "$DOCKER_CONTAINER" ] || die "DOCKER_CONTAINER ist leer. Bitte den Containernamen eintragen ('docker ps')."
    docker inspect "$DOCKER_CONTAINER" >/dev/null 2>&1 || die "Container '$DOCKER_CONTAINER' nicht gefunden. Laufende Container mit 'docker ps' pruefen."
    [ "$(docker inspect -f '{{.State.Running}}' "$DOCKER_CONTAINER")" = "true" ] || die "Container '$DOCKER_CONTAINER' laeuft nicht."
    info "Docker-Modus: alle Datenbankbefehle laufen im Container '$DOCKER_CONTAINER'."
else
    command -v psql    >/dev/null 2>&1 || die "psql nicht gefunden. PostgreSQL zuerst installieren (ANLEITUNG.md, Abschnitt 5.1) oder DB_UEBER_DOCKER=\"yes\" fuer den Betrieb im Docker-Container."
    command -v runuser >/dev/null 2>&1 || die "runuser nicht gefunden. Das Skript bitte als root oder mit sudo ausfuehren."
fi

as_pg true 2>/dev/null || die "Zugriff auf den Container bzw. die lokale Installation fehlgeschlagen. Skript als root bzw. mit sudo ausfuehren (Docker-Modus: Gruppenmitgliedschaft docker genuegt)."

# Wartungsdatenbank ermitteln: Standard ist "postgres"; wurde der Container
# mit POSTGRES_USER=<name> erstellt, existiert weder die Rolle "postgres" noch
# die Datenbank "postgres", und die Wartungsdatenbank heisst wie der
# Administrator. Beide Faelle werden automatisch erkannt.
ADMIN_DB=""
for kandidat in postgres "$DB_ADMIN_USER"; do
    if as_pg psql -U "$DB_ADMIN_USER" -d "$kandidat" -tAc "SELECT 1" >/dev/null 2>&1; then
        ADMIN_DB="$kandidat"
        break
    fi
done
if [ -z "$ADMIN_DB" ]; then
    if [ "$DB_UEBER_DOCKER" = "yes" ]; then
        die "Anmeldung als Administrator '$DB_ADMIN_USER' fehlgeschlagen; die Rolle existiert vermutlich nicht. Im Docker-Modus muss DB_ADMIN_USER dem POSTGRES_USER des Containers entsprechen (pruefen: docker exec $DOCKER_CONTAINER env | grep ^POSTGRES_USER)."
    fi
    die "Anmeldung als Administrator '$DB_ADMIN_USER' fehlgeschlagen. Bei nativer Installation DB_ADMIN_USER bitte auf 'postgres' lassen und das Skript als root bzw. mit sudo ausfuehren."
fi
if [ "$ADMIN_DB" != "postgres" ]; then
    info "Wartungsdatenbank: '$ADMIN_DB' (Container wurde offenbar mit POSTGRES_USER='$DB_ADMIN_USER' eingerichtet)."
fi

if [ -z "$(as_pg psql -U "$DB_ADMIN_USER" -d "$ADMIN_DB" -tAc "SELECT 1 FROM pg_available_extensions WHERE name = 'timescaledb'")" ]; then
    die "Die TimescaleDB-Extension ist nicht installiert. Abhilfe: bei Docker ein TimescaleDB-Image verwenden (timescale/timescaledb); nativ siehe ANLEITUNG.md, Abschnitt 5.1."
fi

#-------------------------------------------------------------------------------
# 1) Datenbank anlegen
#-------------------------------------------------------------------------------
if [ -n "$(as_pg psql -U "$DB_ADMIN_USER" -d "$ADMIN_DB" -tAc "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'")" ]; then
    log "Datenbank '$DB_NAME' existiert bereits."
else
    log "Datenbank '$DB_NAME' wird angelegt ..."
    as_pg psql -U "$DB_ADMIN_USER" -d "$ADMIN_DB" -v ON_ERROR_STOP=1 \
        -c "CREATE DATABASE $DB_NAME;" >/dev/null
fi

#-------------------------------------------------------------------------------
# 2) TimescaleDB-Erweiterung aktivieren
#-------------------------------------------------------------------------------
log "TimescaleDB-Erweiterung wird aktiviert ..."
as_pg psql -U "$DB_ADMIN_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 \
    -c "CREATE EXTENSION IF NOT EXISTS timescaledb;" >/dev/null

#-------------------------------------------------------------------------------
# 3) + 4) schema.sql und aggregations.sql einspielen
#
# Die Original-Dateien bleiben unveraendert: fuer einen abweichenden
# Tabellennamen wird eine Arbeitskopie erzeugt und darin "measurements"
# global ersetzt (inkl. measurements_1min/_1h/_1day). Wird kein abweichender
# Name vergeben, sind die Kopien identisch zum Original.
#
# Der Modus ist bewusst identisch fuer beide Betriebsarten: die SQL-Dateien
# werden per stdin (-f -) durchgereicht. Nativ liest psql direkt, im
# Docker-Modus ueber docker exec -i vom Host aus.
#-------------------------------------------------------------------------------
ARBEITS_VERZ="$(mktemp -d)"
trap 'rm -rf "$ARBEITS_VERZ"' EXIT

cp "$SCHEMA_SQL"       "$ARBEITS_VERZ/schema.sql"
cp "$AGGREGATIONS_SQL" "$ARBEITS_VERZ/aggregations.sql"

if [ "$DB_TABLE" != "measurements" ]; then
    info "Tabellenname wird auf '$DB_TABLE' angepasst (Arbeitskopien der SQL-Dateien)."
    sed -i "s/measurements/${DB_TABLE}/g" "$ARBEITS_VERZ/schema.sql" "$ARBEITS_VERZ/aggregations.sql"
fi

log "schema.sql wird eingespielt ..."
as_pg psql -U "$DB_ADMIN_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 \
    -f - < "$ARBEITS_VERZ/schema.sql" >/dev/null

log "aggregations.sql wird eingespielt (Komprimierung, Aggregate, Aufbewahrung) ..."
as_pg psql -U "$DB_ADMIN_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 \
    -f - < "$ARBEITS_VERZ/aggregations.sql" >/dev/null

#-------------------------------------------------------------------------------
# 5) Datenbankbenutzer anlegen bzw. aktualisieren und Rechte erteilen
#
# Das Passwort wird direkt als SQL-Literal eingebaut; einfache Hochkommas im
# Passwort werden dazu verdoppelt (SQL-Standard-Quotierung). DB_USER ist als
# Identifier validiert. Bewusst KEINE psql-Variablen (:"rol"/:'pass') in -c:
# psql interpoliert Variablen innerhalb von -c nicht (die -c-Dokumentation
# verlangt einen serverseitig voll parsbaren Befehl), der Server wuerde die
# Platzhalter wortgleich erhalten und einen Syntaxfehler melden.
#-------------------------------------------------------------------------------
DB_PASSWORD_SQL="$(printf '%s' "$DB_PASSWORD" | sed "s/'/''/g")"

if [ -n "$(as_pg psql -U "$DB_ADMIN_USER" -d "$ADMIN_DB" -tAc "SELECT 1 FROM pg_roles WHERE rolname = '$DB_USER'")" ]; then
    log "Datenbankbenutzer '$DB_USER' existiert bereits, Passwort wird aktualisiert ..."
    as_pg psql -U "$DB_ADMIN_USER" -d "$ADMIN_DB" -v ON_ERROR_STOP=1 \
        -c "ALTER ROLE \"$DB_USER\" WITH LOGIN PASSWORD '$DB_PASSWORD_SQL';" \
        >/dev/null
else
    log "Datenbankbenutzer '$DB_USER' wird angelegt ..."
    as_pg psql -U "$DB_ADMIN_USER" -d "$ADMIN_DB" -v ON_ERROR_STOP=1 \
        -c "CREATE ROLE \"$DB_USER\" LOGIN PASSWORD '$DB_PASSWORD_SQL';" >/dev/null
fi

log "Rechte werden erteilt ..."
as_pg psql -U "$DB_ADMIN_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 \
    -c "GRANT CONNECT ON DATABASE $DB_NAME TO $DB_USER;" \
    -c "GRANT USAGE ON SCHEMA public TO $DB_USER;" \
    -c "GRANT INSERT, SELECT ON $DB_TABLE TO $DB_USER;" >/dev/null

if [ "$GRANT_AGGREGATE_READ" = "yes" ]; then
    as_pg psql -U "$DB_ADMIN_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 \
        -c "GRANT SELECT ON ${DB_TABLE}_1min, ${DB_TABLE}_1h, ${DB_TABLE}_1day TO $DB_USER;" >/dev/null
    log "Lesezugriff auf die Aggregate eingerichtet."
fi

#-------------------------------------------------------------------------------
# 6) Verbindungstest mit den eingerichteten Zugangsdaten
#-------------------------------------------------------------------------------
log "Verbindungstest als '$DB_USER' ueber $DB_HOST:$DB_PORT ..."
if command -v psql >/dev/null 2>&1; then
    if PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
            -tAc "SELECT 'Verbindung ok';" 2>/dev/null; then
        :
    else
        info "Der Verbindungstest ist fehlgeschlagen. Moegliche Ursachen:"
        info "  - DB_HOST/DB_PORT falsch (db_writer muss das DB-Geraet erreichen)."
        if [ "$DB_UEBER_DOCKER" = "yes" ]; then
            info "  - Ist der Port im Container veroeffentlicht (-p $DB_PORT:5432)?"
        fi
        info "  - pg_hba.conf erlaubt keine Passwort-Anmeldung fuer diesen Host."
        info "    Abhilfe:  host  all  all  <netz>  scram-sha-256"
        info "    und danach neu laden (native Installation: systemctl reload postgresql;"
        info "    Docker: Container neu starten bzw. Image-Konfiguration anpassen)."
    fi
elif [ "$DB_UEBER_DOCKER" = "yes" ]; then
    info "psql auf dem Host nicht gefunden; der Test laeuft daher im Container."
    info "Er prueft die Zugangsdaten, aber nicht die Portweiterleitung (-p)."
    if docker exec -i -e PGPASSWORD="$DB_PASSWORD" "$DOCKER_CONTAINER" \
            psql -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT 'Verbindung ok';" >/dev/null 2>&1; then
        log "Verbindungstest im Container erfolgreich."
    else
        info "Der Verbindungstest im Container ist fehlgeschlagen."
    fi
else
    info "psql auf dem Host nicht gefunden; Verbindungstest uebersprungen."
fi

#-------------------------------------------------------------------------------
# 7) Zusammenfassung
#-------------------------------------------------------------------------------
echo
log "Datenbankeinrichtung abgeschlossen."
echo "      Datenbank : $DB_NAME"
if [ "$DB_UEBER_DOCKER" = "yes" ]; then
    echo "      Modus     : Docker-Container '$DOCKER_CONTAINER'"
else
    echo "      Modus     : native Installation (PostgreSQL auf diesem Geraet)"
fi
echo "      Tabelle   : $DB_TABLE (Hypertable, TimescaleDB)"
echo "      Benutzer  : $DB_USER (INSERT/SELECT auf die Tabelle)"
echo
echo "      >>> Diese Zeile jetzt in server/db_writer.py eintragen <<<"
echo "      >>> (Konfigurationsblock am Dateianfang, ca. Zeile 21): <<<"
echo
printf '      DB_DSN = "host=%s dbname=%s user=%s password=%s"\n' \
       "$DB_HOST" "$DB_NAME" "$DB_USER" "$DB_PASSWORD"
echo

if [ "$DB_TABLE" != "measurements" ]; then
    info "Abweichender Tabellenname '$DB_TABLE': in server/db_writer.py"
    info "  bitte auch das INSERT_SQL anpassen (ca. Zeilen 26 bis 30):"
    info '    "INSERT INTO measurements (time, ..."  ->  "INSERT INTO '"$DB_TABLE"' (time, ..."'
fi
