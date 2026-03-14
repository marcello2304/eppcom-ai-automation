-- Leads-Tabelle für Chatbot-Anfragen
CREATE TABLE IF NOT EXISTS leads (
    id          SERIAL PRIMARY KEY,
    name        TEXT,
    email       TEXT NOT NULL,
    telefon     TEXT,
    nachricht   TEXT,
    quelle      TEXT DEFAULT 'Unbekannt',
    erstellt_am TIMESTAMPTZ DEFAULT NOW(),
    status      TEXT DEFAULT 'neu',        -- neu | kontaktiert | abgeschlossen
    notizen     TEXT
);

-- Unique auf E-Mail (upsert im Workflow)
CREATE UNIQUE INDEX IF NOT EXISTS leads_email_idx ON leads(email);

-- Index für Sortierung nach Datum
CREATE INDEX IF NOT EXISTS leads_erstellt_am_idx ON leads(erstellt_am DESC);

-- Kommentare
COMMENT ON TABLE leads IS 'Leads aus Typebot-Chatbot und anderen Quellen';
COMMENT ON COLUMN leads.status IS 'neu | kontaktiert | abgeschlossen';
