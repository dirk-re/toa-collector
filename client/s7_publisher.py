#!/usr/bin/env python3
"""
Liest zyklisch Daten aus einer Siemens S7-1500 (PUT/GET) und
veroeffentlicht sie mit QoS 1 an den lokalen Mosquitto-Broker.
Der lokale Broker puffert bei Netzwerkausfall und spielt die
Nachrichten nach der Bridge-Wiederverbindung automatisch nach.

Aufruf:  python s7_publisher.py --config C:\s7-client\config.ini
"""
import argparse
import configparser
import json
import logging
import time
import uuid
from datetime import datetime, timezone

import paho.mqtt.client as mqtt
from paho.mqtt.client import CallbackAPIVersion

from s7 import Client  # python-snap7 >= 3.0, reines Python, keine DLL
from s7.util import get_bool, get_int, get_dint, get_real, get_lreal

TYPEN = {
    "bool":  (get_bool, 1),
    "int":   (get_int, 2),
    "dint":  (get_dint, 4),
    "real":  (get_real, 4),
    "lreal": (get_lreal, 8),
}

def lade_tags(cfg):
    """Wandelt den [tags]-Abschnitt der INI in eine Liste von Tag-Definitionen."""
    tags = []
    for name, roh in cfg["tags"].items():
        teile = [t.strip() for t in roh.split(",")]
        db, offset, typ = int(teile[0]), int(teile[1]), teile[2].lower()
        if typ not in TYPEN:
            raise ValueError(f"Unbekannter Typ '{typ}' bei Tag '{name}'")
        bit = int(teile[3]) if typ == "bool" else None
        if typ == "bool" and bit is None:
            raise ValueError(f"Tag '{name}' (bool) benoetigt eine Bit-Nummer")
        tags.append(dict(name=name, db=db, offset=offset, typ=typ, bit=bit))
    return tags

def lies_werte(plc, tags):
    """Liest alle konfigurierten Tags aus den Datenbausteinen."""
    werte = {}
    for tag in tags:
        lesen, laenge = TYPEN[tag["typ"]]
        raw = plc.db_read(tag["db"], tag["offset"], laenge)
        if tag["typ"] == "bool":
            werte[tag["name"]] = bool(lesen(raw, 0, tag["bit"]))
        else:
            werte[tag["name"]] = lesen(raw, 0)
    return werte

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    args = parser.parse_args()

    cfg = configparser.ConfigParser()
    cfg.read(args.config, encoding="utf-8")

    client_id = cfg["geraet"]["client_id"]
    sensor_id = cfg["geraet"]["sensor_id"]
    topic = cfg["mqtt"]["topic"]
    zyklus = cfg.getfloat("plc", "zyklus", fallback=1.0)

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        handlers=[logging.StreamHandler(),
                  # Eine Log-Datei je Instanz: erlaubt mehrere Publisher-
                  # Prozesse (mehrere S7-1500 an einem Client-Geraet),
                  # client_id wird aus der jeweiligen config.ini gelesen.
                  logging.FileHandler(rf"C:\s7-client\logs\publisher-{client_id}.log",
                                      encoding="utf-8")])
    log = logging.getLogger(client_id)

    tags = lade_tags(cfg)
    plc = Client()

    def plc_verbinden():
        """Endloser Verbindungsversuch mit Wartezeit (Steuerung kann aus sein)."""
        while True:
            try:
                plc.connect(cfg["plc"]["ip"], cfg.getint("plc", "rack"),
                            cfg.getint("plc", "slot"))
                log.info("S7-1500 verbunden: %s", cfg["plc"]["ip"])
                return
            except Exception as e:
                log.warning("PLC nicht erreichbar (%s), neuer Versuch in 5 s", e)
                time.sleep(5)

    mqttc = mqtt.Client(CallbackAPIVersion.VERSION2,
                        client_id=client_id, clean_session=False)
    mqttc.username_pw_set(cfg["mqtt"]["user"], cfg["mqtt"]["passwort"])
    mqttc.connect(cfg["mqtt"]["host"], cfg.getint("mqtt", "port"))
    mqttc.loop_start()

    plc_verbinden()
    log.info("Publisher aktiv: %d Tags, Zyklus %.1f s", len(tags), zyklus)

    while True:
        try:
            werte = lies_werte(plc, tags)
        except Exception as e:
            log.error("S7-Lesefehler: %s", e)
            try:
                plc.disconnect()
            except Exception:
                pass
            plc_verbinden()
            continue

        payload = {
            "message_id": str(uuid.uuid4()),
            "time": datetime.now(timezone.utc).isoformat(),
            "sensor_id": sensor_id,
            "values": werte,
        }
        # QoS 1: Der lokale Broker uebernimmt die Nachricht zuverlaessig
        # und puffert sie fuer die Bridge zum zentralen Broker.
        mqttc.publish(topic, json.dumps(payload), qos=1)
        time.sleep(zyklus)


if __name__ == "__main__":
    main()
