"""Operator registry for the calc library's dispatch table."""

OPERATIONS = {}


def register_operation(name, fn):
    """Register fn under name in the calc library's dispatch table."""
    OPERATIONS[name] = fn
