from shared.db import connect

SCHEMA = [
    """
    CREATE TABLE IF NOT EXISTS users (
        id         UUID PRIMARY KEY,
        email      TEXT NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS tutorials (
        id          SERIAL PRIMARY KEY,
        title       VARCHAR(200) NOT NULL,
        url         TEXT NOT NULL,
        description TEXT NOT NULL CHECK (length(trim(description)) > 0),
        author_id   UUID NOT NULL REFERENCES users(id),
        created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS ratings (
        tutorial_id INTEGER NOT NULL REFERENCES tutorials(id) ON DELETE CASCADE,
        user_id     UUID NOT NULL REFERENCES users(id),
        stars       SMALLINT NOT NULL CHECK (stars BETWEEN 1 AND 5),
        created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
        PRIMARY KEY (tutorial_id, user_id)
    )
    """,
]

LIST_TABLES = """
    SELECT table_name
    FROM information_schema.tables
    WHERE table_schema = 'public'
    ORDER BY table_name
"""


def lambda_handler(event, context):
    conn = connect()
    try:
        for statement in SCHEMA:
            conn.run(statement)
        rows = conn.run(LIST_TABLES)
    finally:
        conn.close()
    return {"tables": [row[0] for row in rows]}
