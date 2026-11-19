# The gateway provisioning function (issue #10): an AWS Lambda function behind a public HTTPS
# address (a Lambda function URL). A freshly flashed gateway calls it once, at first boot.
#
#   POST /provision
#   {"gateway_eui": "0016c001f1135844", "secret": "<64 hex characters, from the card>"}
#
#   200  {"gateway_eui": ..., "cups.uri": ..., "cups.trust": ..., "cups.crt": ..., "cups.key": ...}
#        The four Basics Station files. The secret is now used.
#   400  {"error": "bad_request"}          not JSON, or a field is missing or malformed
#   403  {"error": "unknown_secret"}       the secret's fingerprint is not in the allow-list
#   409  {"error": "secret_already_used"}  the secret was used before
#   503  {"error": "try_again"}            the allow-list or AWS IoT failed; the secret is
#                                          still unused, so the gateway retries
#   404, 405                                another path or method
#
# 400, 403 and 409 create nothing in AWS: the allow-list is asked before anything else.
#
# What is logged (CloudWatch): one JSON line per request with the outcome, the gateway EUI and
# the first 8 characters of the fingerprint. The request body, the secret and the private key
# are never logged, and the function does not log the event it is called with.
#
# This file was partially generated using Claude Code using the chat session at:
# Link to chat session (issue #10): ISSUE10_SESSION_LINK

import base64
import datetime
import hashlib
import json
import os
import re

import allowlist
from gateway_registry import GatewayRegistry, RegistrationError

MAX_BODY_BYTES = 1024
EUI_RE = re.compile(r"^[0-9a-f]{16}$")
SECRET_RE = re.compile(r"^[0-9a-f]{64}$")
CREDENTIAL_FILES = ("cups.uri", "cups.trust", "cups.crt", "cups.key")


def fingerprint_of(secret):
    """The allow-list key: SHA-256 of the secret's 64 ASCII characters, as lowercase hex."""
    return hashlib.sha256(secret.encode("ascii")).hexdigest()


def log(event, **fields):
    print(json.dumps({"event": event, **fields}, sort_keys=True))


def _response(status, body):
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json", "cache-control": "no-store"},
        "body": json.dumps(body),
    }


def _parse(event):
    """Returns (gateway_eui, secret), or None if the request body is not what we expect."""
    body = event.get("body") or ""
    try:
        if event.get("isBase64Encoded"):
            body = base64.b64decode(body).decode("utf-8")
        if len(body) > MAX_BODY_BYTES:
            return None
        data = json.loads(body)
    except (ValueError, UnicodeDecodeError):
        return None
    if not isinstance(data, dict):
        return None
    eui = data.get("gateway_eui")
    secret = data.get("secret")
    if not isinstance(eui, str) or not isinstance(secret, str):
        return None
    eui = eui.lower()
    if not EUI_RE.match(eui) or not SECRET_RE.match(secret):
        return None
    return eui, secret


def handle(event, allow_list, registry, now=None):
    """The whole function, with its two dependencies passed in so that tests can fake them."""
    http = (event.get("requestContext") or {}).get("http") or {}
    if (event.get("rawPath") or "").rstrip("/") != "/provision":
        return _response(404, {"error": "not_found"})
    if http.get("method") != "POST":
        return _response(405, {"error": "method_not_allowed"})

    parsed = _parse(event)
    if parsed is None:
        log("refused", reason="bad_request")
        return _response(400, {"error": "bad_request"})
    eui, secret = parsed
    fingerprint = fingerprint_of(secret)
    del secret, parsed
    short = fingerprint[:8]
    now = now or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    try:
        answer = allow_list.consume(fingerprint, eui, now)
    except Exception as exc:
        log("failed", step="allow_list", gateway_eui=eui, fingerprint=short,
            error=type(exc).__name__)
        return _response(503, {"error": "try_again"})
    if answer == allowlist.UNKNOWN:
        log("refused", reason="unknown_secret", gateway_eui=eui, fingerprint=short)
        return _response(403, {"error": "unknown_secret"})
    if answer != allowlist.OK:
        log("refused", reason="secret_already_used", gateway_eui=eui, fingerprint=short)
        return _response(409, {"error": "secret_already_used"})

    try:
        result = registry.register(eui)
    except Exception as exc:
        # Hand the secret back, so that the gateway's next try is not refused as "used".
        released = True
        try:
            allow_list.release(fingerprint)
        except Exception:
            released = False
        detail = str(exc) if isinstance(exc, RegistrationError) else type(exc).__name__
        log("failed", step="registration", gateway_eui=eui, fingerprint=short,
            error=detail, secret_released=released)
        return _response(503, {"error": "try_again"})

    log("provisioned", gateway_eui=eui, fingerprint=short, gateway_id=result["gateway_id"],
        gateway_created=result["gateway_created"],
        certificate_replaced=result["certificate_replaced"])
    body = {"gateway_eui": eui}
    body.update({name: result[name] for name in CREDENTIAL_FILES})
    return _response(200, body)


_deps = None


def _default_deps():
    """The real allow-list and registry. boto3 is imported here, not at the top, so the host
    tests run without it."""
    import boto3

    allow_list = allowlist.DynamoDbAllowList(boto3.client("dynamodb"), os.environ["TABLE_NAME"])
    registry = GatewayRegistry(boto3.client("iotwireless"), boto3.client("iot"),
                               rf_region=os.environ.get("RF_REGION", "US915"), log=log)
    return allow_list, registry


def lambda_handler(event, context):
    global _deps
    if _deps is None:
        _deps = _default_deps()
    try:
        return handle(event, *_deps)
    except Exception as exc:
        # Log the exception's class only. Its message could quote data from the request.
        log("failed", step="internal", error=type(exc).__name__)
        return _response(500, {"error": "internal"})
