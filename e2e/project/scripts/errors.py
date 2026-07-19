"""Shared exception types for background jobs."""


class StubNotImplemented(Exception):
    """Raised by a deliberately deferred stub — distinct from a real bug."""

    def __init__(self, feature):
        super().__init__(f"{feature} is not implemented yet")
