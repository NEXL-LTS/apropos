"""Compliance audit logging for the data-access layer."""


def audited_query(conn, sql, params=()):
    """Log sql to the audit trail, then execute it against conn."""
    _log_for_audit(sql, params)
    return conn.execute(sql, params)


def _log_for_audit(sql, params):
    # Placeholder: a real deployment ships this to the audit sink.
    pass
