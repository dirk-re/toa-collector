-- Komprimierung, Langzeit-Aggregation und Aufbewahrung fuer measurements.
-- Ausfuehren mit:  psql -U postgres -d sensordaten -f aggregations.sql
-- Voraussetzung:  server/schema.sql ist eingespielt.
-- Benoetigt TimescaleDB >= 2.9 (hierarchische Continuous Aggregates);
-- das in der Anleitung installierte TSL-Paket fuer PostgreSQL 17 erfuellt das.

\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------------
-- 1) Komprimierung der Rohdaten-Chunks nach 7 Tagen
--
-- Alle Spalten des Primaerschluessels (time, message_id, tag) muessen von
-- compress_segmentby oder compress_orderby abgedeckt sein, sonst verweigert
-- TimescaleDB die Aktivierung der Komprimierung.
-- - tag steht im segmentby (wenige Werte, gut fuer Komprimierung und Filter).
-- - message_id steht bewusst im orderby: Nur so bleibt der Primaerschluessel
--   auch auf komprimierten Chunks erzwingbar und das INSERT ... ON CONFLICT
--   des db_writer funktioniert nach wie vor, wenn nach einem laengeren
--   Netzwerkausfall gepufferte Nachrichten mit alten Zeitstempeln in
--   bereits komprimierten Bereichen ankommen.
-- Die Sortierung innerhalb der Segmente ist gut komprimierbar; nur die
-- UUID-Spalte selbst bleibt je Zeile erhalten.
-- ---------------------------------------------------------------------------
ALTER TABLE measurements SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'site_id, device_id, channel_id, tag',
    timescaledb.compress_orderby   = 'time DESC, message_id DESC'
);

SELECT add_compression_policy('measurements', INTERVAL '7 days',
                              if_not_exists => TRUE);

-- ---------------------------------------------------------------------------
-- 2) Continuous Aggregates: Minute -> Stunde -> Tag
--
-- Jede Stufe liest die Stufe darunter (nicht die Rohdaten), gruppiert nach
-- site_id, device_id, channel_id und haelt min/max/avg/anzahl vor.
-- Der zaehlergewichtete Durchschnitt (sum(avg*n)/sum(n)) ist exakt;
-- avg(avg) waere falsch.
-- Tages- und Stundengrenzen liegen in UTC.
-- ---------------------------------------------------------------------------
CREATE MATERIALIZED VIEW IF NOT EXISTS measurements_1min
WITH (timescaledb.continuous) AS
SELECT
    time_bucket(INTERVAL '1 minute', time) AS bucket,
    site_id, device_id, channel_id,
    avg(value)   AS wert_avg,
    min(value)   AS wert_min,
    max(value)   AS wert_max,
    count(value) AS anzahl
FROM measurements
GROUP BY 1, 2, 3, 4
WITH NO DATA;

CREATE MATERIALIZED VIEW IF NOT EXISTS measurements_1h
WITH (timescaledb.continuous) AS
SELECT
    time_bucket(INTERVAL '1 hour', bucket) AS bucket,
    site_id, device_id, channel_id,
    min(wert_min)                       AS wert_min,
    max(wert_max)                       AS wert_max,
    sum(wert_avg * anzahl) / sum(anzahl) AS wert_avg,
    sum(anzahl)                         AS anzahl
FROM measurements_1min
GROUP BY 1, 2, 3, 4
WITH NO DATA;

CREATE MATERIALIZED VIEW IF NOT EXISTS measurements_1day
WITH (timescaledb.continuous) AS
SELECT
    time_bucket(INTERVAL '1 day', bucket) AS bucket,
    site_id, device_id, channel_id,
    min(wert_min)                       AS wert_min,
    max(wert_max)                       AS wert_max,
    sum(wert_avg * anzahl) / sum(anzahl) AS wert_avg,
    sum(anzahl)                         AS anzahl
FROM measurements_1h
GROUP BY 1, 2, 3, 4
WITH NO DATA;

-- ---------------------------------------------------------------------------
-- 3) Refresh-Policies
--
-- Der weit gefasste start_offset ist fuer dieses System wesentlich: Bei
-- Netzausfall puffern die lokalen Broker Stunden- bis tagelang alte
-- Zeitstempel nach. Der Refresh verarbeitet nur invalidierte Bereiche, der
-- weite Anlauf kostet also nichts. Muss die maximale Pufferzeit (hier 7
-- Tage) erhoeht werden, start_offset der Minute-Stufe entsprechend anpassen
-- und einmal CALL refresh_continuous_aggregate(...) ohne Bereichsgrenze
-- ausfuehren (vor dem ersten Loeschen durch die Aufbewahrungsrichtlinie).
-- ---------------------------------------------------------------------------
SELECT add_continuous_aggregate_policy('measurements_1min',
    start_offset      => INTERVAL '7 days',
    end_offset        => INTERVAL '5 minutes',
    schedule_interval => INTERVAL '5 minutes',
    if_not_exists     => TRUE);

SELECT add_continuous_aggregate_policy('measurements_1h',
    start_offset      => INTERVAL '8 days',
    end_offset        => INTERVAL '1 hour',
    schedule_interval => INTERVAL '1 hour',
    if_not_exists     => TRUE);

SELECT add_continuous_aggregate_policy('measurements_1day',
    start_offset      => INTERVAL '10 days',
    end_offset        => INTERVAL '1 day',
    schedule_interval => INTERVAL '1 day',
    if_not_exists     => TRUE);

-- ---------------------------------------------------------------------------
-- 4) Erstabfuellung
--
-- Nur einmalig ausfuehren; bei einer frischen Installation ohne Historie ist
-- der Aufruf ohne Wirkung. Bei grosser vorhandener Historie dauert der
-- Aufruf entsprechend lange. Reihenfolge: von fein nach grob.
-- Wichtig: Die Erstabfuellung darf NUR vor dem ersten Loeschen durch die
-- Aufbewahrungsrichtlinie (Abschnitt 5) ausgefuehrt werden; danach wuerde
-- ein unbegrenzter Refresh bereits geloeschte Zeitraeume als leer neu
-- berechnen und die materialisierten Aggregate historisch veraendern.
-- ---------------------------------------------------------------------------
CALL refresh_continuous_aggregate('measurements_1min', NULL, now());
CALL refresh_continuous_aggregate('measurements_1h',   NULL, now());
CALL refresh_continuous_aggregate('measurements_1day', NULL, now());

-- ---------------------------------------------------------------------------
-- 5) Aufbewahrung: Rohdaten nach 5 Jahren loeschen
--
-- Die Rohdaten-Chunks werden nach 5 Jahren entfernt; die Aggregate
-- (Minute/Stunde/Tag) bleiben unberuehrt, sie liegen in eigenen Tabellen.
-- Nach Beginn der Loeschungen manuelle Refreshes nur noch mit explizitem,
-- noch nicht geloeschtem Zeitfenster ausfuehren (Beispiel):
--   CALL refresh_continuous_aggregate('measurements_1min',
--       now() - INTERVAL '7 days', now());
-- ---------------------------------------------------------------------------
SELECT add_retention_policy('measurements', INTERVAL '5 years',
                            if_not_exists => TRUE);

-- ---------------------------------------------------------------------------
-- 6) Optional: Lesezugriff auf die Aggregate fuer Auswertungen
-- ---------------------------------------------------------------------------
-- GRANT SELECT ON measurements_1min, measurements_1h, measurements_1day TO writer;
