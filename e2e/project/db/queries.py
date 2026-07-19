"""Data-access helpers. Queries here run against the primary database."""


def get_user(conn, user_id):
    """Fetch a user row by id."""
    return conn.execute("SELECT * FROM users WHERE id = ?", (user_id,)).fetchone()
