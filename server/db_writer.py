#!/usr/bin/env python3
"""
Abonniert s7/+/data am zentralen Broker (QoS 1, persistente Session)
und schreibt die Messwerte gebuendelt in die TimescaleDB.
Ack an den Broker erst nach erfolgreichem Commit.
"""
import json
import logging
import time

import psycopg2
from psycopg2.extras import execute_values

import paho.mqtt.client as mqtt
from paho.mqtt.client import CallbackAPIVersion

# ------------------------- Konfiguration -----------------------------------
BROKER_HOST = "127.0.0.1"          # zentraler Broker (dieses Geraet)
BROKER_PORT = 1883
BROKER_USER = "db-subscriber"
BROKER_PASS = "GEHEIM"
DB_DSN = "host=127.0.0.1 dbname=sensordaten user=writer password=GEHEIM"

TOPIC = "s7/+/data"
CLIENT_ID = "db-writer-1"           # fest lassen: daran haengt die persistente Session

BATCH_MAX = 200                     # spaetestens nach so vielen Nachrichten
BATCH_SEKUNDEN = 2.0                # oder so vielen Sekunden schreiben
# ----------------------------------------------------------------------------

INSERT_SQL = """
    INSERT INTO measurements (time, message_id, tag, site_id, device_id, channel_id, value)
    VALUES %s
    ON CONFLICT (time, message_id, tag) DO NOTHING
"""

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("db_writer")

conn = psycopg2.connect(DB_DSN)
batch = []
letzter_flush = time.monotonic()


def on_connect(client, userdata, flags, reason_code, properties):
    # Bei jedem (Wieder-)Verbinden abonnieren. Mit persistenter Session
    # nimmt der Broker die Session wieder auf und liefert die gepufferten
    # Nachrichten nach.
    client.subscribe(TOPIC, qos=1)
    log.info("Verbunden, Session vorhanden: %s", flags.session_present)


def flush(client):
    """Schreibt den Batch in die Datenbank und bestaetigt erst danach."""
    global batch, letzter_flush
    if not batch:
        return
    rows = []
    for nachricht, _ in batch:
        for tag, eintrag in nachricht["values"].items():
            rows.append((nachricht["time"], nachricht["message_id"], tag,
                         nachricht["site_id"], eintrag["device_id"],
                         eintrag["channel_id"], eintrag["value"]))
    with conn.cursor() as cur:
        execute_values(cur, INSERT_SQL, rows)
    conn.commit()
    for _, mid in batch:
        client.ack(mid)            # manueller Ack: erst nach dem Commit
    log.info("%d Nachrichten (%d Zeilen) geschrieben", len(batch), len(rows))
    batch.clear()
    letzter_flush = time.monotonic()


def on_message(client, userdata, msg):
    global batch, letzter_flush
    nachricht = json.loads(msg.payload)
    batch.append((nachricht, msg.mid))
    if len(batch) >= BATCH_MAX or time.monotonic() - letzter_flush >= BATCH_SEKUNDEN:
        try:
            flush(client)
        except psycopg2.Error as e:
            conn.rollback()
            log.error("Datenbankfehler: %s", e)
            # Nicht geackte Nachrichten uebertraegt der Broker nach dem
            # Reconnect erneut.
            time.sleep(2)
            client.reconnect()


client = mqtt.Client(CallbackAPIVersion.VERSION2,
                     client_id=CLIENT_ID, clean_session=False)
client.manual_ack_set(True)
client.username_pw_set(BROKER_USER, BROKER_PASS)
client.on_connect = on_connect
client.on_message = on_message
client.connect(BROKER_HOST, BROKER_PORT)
client.loop_forever(retry_first_connection=True)
