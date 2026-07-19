"""Lightweight call tracing for src/'s public surface."""

import functools


def trace_call(fn):
    """Wrap fn so each call is traced (no-op placeholder for now)."""

    @functools.wraps(fn)
    def wrapper(*args, **kwargs):
        return fn(*args, **kwargs)

    return wrapper
