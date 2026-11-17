-- Tabellenschema für die Messdaten (TimescaleDB).
-- Ausführen mit:  psql -U postgres -d sensordaten -f schema.sql
-- Langformat: eine Zeile pro Messpunkt (Tag), einheitlich für alle 10 Clients.

CREATE TABLE IF NOT EXISTS measurements (
    time        TIMESTAMPTZ      NOT NULL,
    message_id  UUID             NOT NULL,
    tag         TEXT             NOT NULL,
    sensor_id   TEXT             NOT NULL,
    value       DOUBLE PRECISION,
    PRIMARY KEY (time, message_id, tag)
);

SELECT create_hypertable('measurements', 'time',
                         if_not_exists => TRUE,
                         chunk_time_interval => INTERVAL '1 day');

-- Optional: nach 90 Tagen alte Chunks automatisch loeschen
-- SELECT add_retention_policy('measurements', INTERVAL '90 days');
