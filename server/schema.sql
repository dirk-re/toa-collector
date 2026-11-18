-- Tabellenschema für die Messdaten (TimescaleDB).
-- Ausführen mit:  psql -U postgres -d sensordaten -f schema.sql
-- Langformat: eine Zeile pro Messpunkt (Tag), einheitlich für alle 10 Clients.

CREATE TABLE IF NOT EXISTS measurements (
    time        TIMESTAMPTZ      NOT NULL,
    message_id  UUID             NOT NULL,
    tag         TEXT             NOT NULL,
    site_id     TEXT             NOT NULL,
    device_id   TEXT             NOT NULL,
    channel_id  TEXT             NOT NULL,
    value       DOUBLE PRECISION,
    PRIMARY KEY (time, message_id, tag)
);

-- Abfragen nach Herkunft (Standort/Geraet/Kanal) beschleunigen:
CREATE INDEX IF NOT EXISTS measurements_herkunft_idx
    ON measurements (site_id, device_id, channel_id, time DESC);

-- Migration einer bestehenden Installation (alte Tabelle mit sensor_id):
-- ALTER TABLE measurements ADD COLUMN site_id    TEXT NOT NULL DEFAULT '';
-- ALTER TABLE measurements ADD COLUMN device_id  TEXT NOT NULL DEFAULT '';
-- ALTER TABLE measurements ADD COLUMN channel_id TEXT NOT NULL DEFAULT '';
-- ALTER TABLE measurements DROP COLUMN sensor_id;

SELECT create_hypertable('measurements', 'time',
                         if_not_exists => TRUE,
                         chunk_time_interval => INTERVAL '1 day');

-- Komprimierung (7 Tage), Langzeit-Aggregate (Minute/Stunde/Tag) und
-- Aufbewahrung der Rohdaten (5 Jahre) werden separat eingerichtet:
-- siehe aggregations.sql, einmalig nach dieser Datei ausfuehren.
