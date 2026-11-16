"""Failures that are answered to the client: HTTP status, api-v2 error code, Japanese message."""


class RelayError(Exception):
    """Never carries secrets, tokens, cookies, file contents or tracebacks in its message."""

    def __init__(self, status, code, message, x_code=None, retry_after=None):
        Exception.__init__(self, message)
        self.status = status
        self.code = code
        self.message = message
        self.x_code = x_code
        self.retry_after = retry_after

    def body(self):
        # api-v2.md section 1: all four keys are always present, null when not applicable
        return {"error": {"code": self.code, "message": self.message,
                          "x_code": self.x_code, "retry_after": self.retry_after}}
