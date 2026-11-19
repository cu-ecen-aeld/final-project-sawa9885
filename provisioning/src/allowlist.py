# The allow-list of gateway secrets, as the provisioning function sees it (issue #10).
#
# The flash script gives every card a random secret and records only the secret's SHA-256
# fingerprint (64 lowercase hex characters). The function never stores or compares secrets: it
# hashes what the gateway sent and asks the allow-list about the fingerprint.
#
# An allow-list is any object with these two methods:
#
#   consume(fingerprint, gateway_eui, now) -> OK | UNKNOWN | USED
#       One atomic step: if the fingerprint is listed and unused, mark it used (by this EUI, at
#       this time) and return OK. Two requests with the same secret can never both get OK.
#   release(fingerprint) -> None
#       Undo a consume() whose registration then failed in AWS, so the gateway's retry can
#       succeed. Only the function calls it, and only right after its own consume().
#
# A third operation, "record a new fingerprint as unused", belongs to the flash script
# (scripts/flash-gateway.ps1, Add-AllowListFingerprint), not to the function. The function's
# role has no permission to add fingerprints.
#
# DynamoDbAllowList is the stand-in used until the SoilData API has these endpoints. An HTTP
# implementation with the same two methods replaces it in handler.py, _default_deps().
#
# This file was partially generated using Claude Code using the chat session at:
# Link to chat session (issue #10): ISSUE10_SESSION_LINK

OK = "ok"
UNKNOWN = "unknown"
USED = "used"

STATE_UNUSED = "unused"
STATE_USED = "used"


def _error_code(exc):
    """The AWS error code of a botocore ClientError, or None for any other exception."""
    response = getattr(exc, "response", None)
    if isinstance(response, dict):
        return response.get("Error", {}).get("Code")
    return None


class DynamoDbAllowList:
    """Allow-list in one DynamoDB table.

    Item: fingerprint (partition key), state ("unused" or "used"), created_at and label (written
    by the flash script), used_at and gateway_eui (written here).
    """

    def __init__(self, dynamodb_client, table_name):
        self._db = dynamodb_client
        self._table = table_name

    def consume(self, fingerprint, gateway_eui, now):
        try:
            self._db.update_item(
                TableName=self._table,
                Key={"fingerprint": {"S": fingerprint}},
                UpdateExpression="SET #state = :used, used_at = :now, gateway_eui = :eui",
                # False for a missing item too, so this never creates one.
                ConditionExpression="#state = :unused",
                ExpressionAttributeNames={"#state": "state"},
                ExpressionAttributeValues={
                    ":used": {"S": STATE_USED},
                    ":unused": {"S": STATE_UNUSED},
                    ":now": {"S": now},
                    ":eui": {"S": gateway_eui},
                },
                # On a failed condition DynamoDB returns the item as it is, if there is one.
                # That tells "already used" from "never listed" without a second request.
                ReturnValuesOnConditionCheckFailure="ALL_OLD",
            )
            return OK
        except Exception as exc:
            if _error_code(exc) != "ConditionalCheckFailedException":
                raise
            return USED if exc.response.get("Item") else UNKNOWN

    def release(self, fingerprint):
        try:
            self._db.update_item(
                TableName=self._table,
                Key={"fingerprint": {"S": fingerprint}},
                UpdateExpression="SET #state = :unused REMOVE used_at, gateway_eui",
                ConditionExpression="#state = :used",
                ExpressionAttributeNames={"#state": "state"},
                ExpressionAttributeValues={
                    ":used": {"S": STATE_USED},
                    ":unused": {"S": STATE_UNUSED},
                },
            )
        except Exception as exc:
            if _error_code(exc) != "ConditionalCheckFailedException":
                raise
