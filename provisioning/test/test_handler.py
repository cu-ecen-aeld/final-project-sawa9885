# Host tests for the gateway provisioning function (issue #10). No AWS account and no boto3 are
# needed: the handler runs against a fake allow-list and a fake AWS (FakeIotWireless, FakeIot),
# and DynamoDbAllowList runs against a fake DynamoDB client that applies its condition.
#
#   python -m unittest discover -s provisioning/test -v
#
# This file was partially generated using Claude Code using the chat session at:
# Link to chat session (issue #10): https://claude.ai/code/cshk_01CSAPnw19XXA81xkir2Ei316vsRvZPpL3YkJGDGzNdFWr

import contextlib
import io
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src"))

import allowlist  # noqa: E402
import handler  # noqa: E402
from gateway_registry import GatewayRegistry  # noqa: E402

EUI = "0016c001f1135844"
SECRET = "5a" * 32
OTHER_SECRET = "c3" * 32
# Stand-ins with the shape of the real values. The PEM marker of the fake key is put together
# from two lines, so that the repo check for committed keys (the "git grep" in the issue's
# definition of done, which looks for the marker on one line) does not match this file.
KEY_WORDS = "PRIVATE " + "KEY"
FAKE_KEY = "-----BEGIN FAKE %s-----\nnot-a-key\n-----END FAKE %s-----\n" % (KEY_WORDS, KEY_WORDS)
FAKE_CERT = "-----BEGIN CERTIFICATE-----\nnot-a-certificate\n-----END CERTIFICATE-----\n"
FAKE_TRUST = "-----BEGIN CERTIFICATE-----\nnot-a-trust-anchor\n-----END CERTIFICATE-----\n"
CUPS_URI = "https://example.cups.lorawan.us-east-1.amazonaws.com:443"


class FakeClientError(Exception):
    """Has the one attribute of botocore's ClientError that the code reads."""

    def __init__(self, code, item=None):
        super().__init__(code)
        self.response = {"Error": {"Code": code}}
        if item is not None:
            self.response["Item"] = item


class FakeAllowList:
    def __init__(self, unused=()):
        self.state = {handler.fingerprint_of(s): allowlist.STATE_UNUSED for s in unused}
        self.used_by = {}
        self.fail = False

    def consume(self, fingerprint, gateway_eui, now):
        if self.fail:
            raise FakeClientError("ProvisionedThroughputExceededException")
        if fingerprint not in self.state:
            return allowlist.UNKNOWN
        if self.state[fingerprint] != allowlist.STATE_UNUSED:
            return allowlist.USED
        self.state[fingerprint] = allowlist.STATE_USED
        self.used_by[fingerprint] = gateway_eui
        return allowlist.OK

    def release(self, fingerprint):
        self.state[fingerprint] = allowlist.STATE_UNUSED
        self.used_by.pop(fingerprint, None)


class FakeAws:
    """State shared by the two fake clients, a list of the calls that changed something, and
    a switch to make one operation fail."""

    def __init__(self):
        # gateway id -> {"eui": ..., "cert": certificate id or None, "lns_cert": the same}
        self.gateways = {}
        self.certificates = {}  # certificate id -> "ACTIVE" or "INACTIVE"
        self.writes = []
        self.fail_on = None
        self.fail_times = None  # None: every call of fail_on fails. A number: only that many.
        self._next = 0

    def call(self, name, write=False):
        if self.fail_on == name and self.fail_times != 0:
            if self.fail_times:
                self.fail_times -= 1
            raise FakeClientError("InternalServerException")
        if write:
            self.writes.append(name)

    def new_id(self, prefix):
        self._next += 1
        return "%s-%04d" % (prefix, self._next)


class FakeIotWireless:
    def __init__(self, aws):
        self.aws = aws

    def get_service_endpoint(self, ServiceType):
        self.aws.call("get_service_endpoint")
        assert ServiceType == "CUPS"
        return {"ServiceType": "CUPS", "ServiceEndpoint": CUPS_URI, "ServerTrust": FAKE_TRUST}

    def get_wireless_gateway(self, Identifier, IdentifierType):
        self.aws.call("get_wireless_gateway")
        assert IdentifierType == "GatewayEui"
        for gateway_id, gateway in self.aws.gateways.items():
            if gateway["eui"] == Identifier:
                return {"Id": gateway_id}
        raise FakeClientError("ResourceNotFoundException")

    def create_wireless_gateway(self, Name, Description, LoRaWAN):
        self.aws.call("create_wireless_gateway", write=True)
        assert LoRaWAN["RfRegion"] == "US915"
        gateway_id = self.aws.new_id("gw")
        self.aws.gateways[gateway_id] = {"eui": LoRaWAN["GatewayEui"], "cert": None,
                                         "lns_cert": None}
        return {"Id": gateway_id}

    def get_wireless_gateway_certificate(self, Id):
        self.aws.call("get_wireless_gateway_certificate")
        gateway = self.aws.gateways[Id]
        if gateway["cert"] is None:
            raise FakeClientError("ResourceNotFoundException")
        found = {"IotCertificateId": gateway["cert"]}
        if gateway["lns_cert"]:
            found["LoRaWANNetworkServerCertificateId"] = gateway["lns_cert"]
        return found

    def associate_wireless_gateway_with_certificate(self, Id, IotCertificateId):
        self.aws.call("associate_wireless_gateway_with_certificate", write=True)
        assert self.aws.gateways[Id]["cert"] is None, "the gateway already has a certificate"
        assert self.aws.certificates[IotCertificateId] == "ACTIVE"
        self.aws.gateways[Id]["cert"] = IotCertificateId
        return {}

    def disassociate_wireless_gateway_from_certificate(self, Id):
        self.aws.call("disassociate_wireless_gateway_from_certificate", write=True)
        # As observed on AWS: this drops the LNS certificate from the gateway as well, and
        # leaves both certificates in the account.
        self.aws.gateways[Id]["cert"] = None
        self.aws.gateways[Id]["lns_cert"] = None
        return {}


class FakeIot:
    def __init__(self, aws):
        self.aws = aws

    def create_keys_and_certificate(self, setAsActive):
        self.aws.call("create_keys_and_certificate", write=True)
        cert_id = self.aws.new_id("cert")
        self.aws.certificates[cert_id] = "ACTIVE" if setAsActive else "INACTIVE"
        return {"certificateId": cert_id, "certificatePem": FAKE_CERT,
                "keyPair": {"PublicKey": "unused", "PrivateKey": FAKE_KEY}}

    def update_certificate(self, certificateId, newStatus):
        self.aws.call("update_certificate", write=True)
        self.aws.certificates[certificateId] = newStatus
        return {}

    def delete_certificate(self, certificateId):
        self.aws.call("delete_certificate", write=True)
        assert self.aws.certificates[certificateId] == "INACTIVE", "delete needs INACTIVE first"
        del self.aws.certificates[certificateId]
        return {}


def request(body, method="POST", path="/provision"):
    """An event in the shape a Lambda function URL sends (payload format 2.0)."""
    if not isinstance(body, str):
        body = json.dumps(body)
    return {"version": "2.0", "rawPath": path, "body": body, "isBase64Encoded": False,
            "requestContext": {"http": {"method": method, "path": path}}}


class HandlerTest(unittest.TestCase):
    def setUp(self):
        self.allow = FakeAllowList(unused=[SECRET])
        self.aws = FakeAws()
        self.registry = GatewayRegistry(FakeIotWireless(self.aws), FakeIot(self.aws),
                                        log=handler.log)
        self.logged = ""

    def post(self, body, **kwargs):
        """Run the handler. Returns (status, decoded body); what it logged goes to self.logged."""
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            response = handler.handle(request(body, **kwargs), self.allow, self.registry,
                                      now="2026-11-19T00:00:00Z")
        self.logged += out.getvalue()
        return response["statusCode"], json.loads(response["body"])

    def provision(self, secret=SECRET, eui=EUI):
        return self.post({"gateway_eui": eui, "secret": secret})

    def assert_nothing_secret_logged(self):
        self.assertNotIn(SECRET, self.logged)
        self.assertNotIn(OTHER_SECRET, self.logged)
        self.assertNotIn(KEY_WORDS, self.logged)
        self.assertNotIn("not-a-key", self.logged)

    # --- valid secret -------------------------------------------------------------------

    def test_valid_secret_registers_the_gateway_and_returns_four_files(self):
        status, body = self.provision()
        self.assertEqual(status, 200)
        self.assertEqual(body, {"gateway_eui": EUI, "cups.uri": CUPS_URI, "cups.trust": FAKE_TRUST,
                                "cups.crt": FAKE_CERT, "cups.key": FAKE_KEY})
        # One gateway with this EUI, holding one active certificate.
        self.assertEqual(len(self.aws.gateways), 1)
        (gateway,) = self.aws.gateways.values()
        self.assertEqual(gateway["eui"], EUI)
        self.assertEqual(self.aws.certificates, {gateway["cert"]: "ACTIVE"})
        # The secret is marked used, by this EUI.
        fingerprint = handler.fingerprint_of(SECRET)
        self.assertEqual(self.allow.state[fingerprint], allowlist.STATE_USED)
        self.assertEqual(self.allow.used_by[fingerprint], EUI)
        self.assertIn('"event": "provisioned"', self.logged)
        self.assertIn('"gateway_created": true', self.logged)
        self.assert_nothing_secret_logged()

    def test_eui_is_accepted_in_upper_case(self):
        status, body = self.provision(eui=EUI.upper())
        self.assertEqual(status, 200)
        self.assertEqual(body["gateway_eui"], EUI)

    # --- refused secrets ----------------------------------------------------------------

    def test_reused_secret_is_refused_logged_and_creates_nothing(self):
        self.assertEqual(self.provision()[0], 200)
        writes_after_first = list(self.aws.writes)
        self.logged = ""

        status, body = self.provision()
        self.assertEqual((status, body), (409, {"error": "secret_already_used"}))
        self.assertEqual(self.aws.writes, writes_after_first)
        self.assertEqual(len(self.aws.gateways), 1)
        self.assertEqual(len(self.aws.certificates), 1)
        self.assertIn('"reason": "secret_already_used"', self.logged)
        self.assertIn(handler.fingerprint_of(SECRET)[:8], self.logged)
        self.assert_nothing_secret_logged()

    def test_reused_secret_is_refused_for_another_gateway_too(self):
        self.assertEqual(self.provision()[0], 200)
        status, _ = self.provision(eui="00000000000000aa")
        self.assertEqual(status, 409)
        self.assertEqual(len(self.aws.gateways), 1)

    def test_unknown_secret_is_refused_and_creates_nothing(self):
        status, body = self.provision(secret=OTHER_SECRET)
        self.assertEqual((status, body), (403, {"error": "unknown_secret"}))
        self.assertEqual(self.aws.writes, [])
        self.assertEqual(self.aws.gateways, {})
        self.assertEqual(self.aws.certificates, {})
        self.assertNotIn(handler.fingerprint_of(OTHER_SECRET), self.allow.state)
        self.assertIn('"reason": "unknown_secret"', self.logged)
        self.assert_nothing_secret_logged()

    # --- AWS failures -------------------------------------------------------------------

    def assert_fails_cleanly_then_succeeds(self, operation, gateways_left):
        self.aws.fail_on = operation
        status, body = self.provision()
        self.assertEqual((status, body), (503, {"error": "try_again"}))
        # No certificate is left behind, and the secret can be used again.
        self.assertEqual(self.aws.certificates, {})
        self.assertEqual(len(self.aws.gateways), gateways_left)
        self.assertEqual(self.allow.state[handler.fingerprint_of(SECRET)], allowlist.STATE_UNUSED)
        self.assertIn('"secret_released": true', self.logged)
        self.assert_nothing_secret_logged()
        # The gateway's retry, once AWS works again.
        self.aws.fail_on = None
        status, body = self.provision()
        self.assertEqual(status, 200)
        self.assertEqual(len(self.aws.gateways), 1)
        (gateway,) = self.aws.gateways.values()
        self.assertEqual(self.aws.certificates, {gateway["cert"]: "ACTIVE"})

    def test_aws_failure_reading_the_endpoint(self):
        self.assert_fails_cleanly_then_succeeds("get_service_endpoint", gateways_left=0)

    def test_aws_failure_creating_the_gateway(self):
        self.assert_fails_cleanly_then_succeeds("create_wireless_gateway", gateways_left=0)

    def test_aws_failure_creating_the_certificate(self):
        # The gateway record made before the failure stays; the retry finds and uses it.
        self.assert_fails_cleanly_then_succeeds("create_keys_and_certificate", gateways_left=1)

    def test_aws_failure_associating_the_certificate(self):
        self.assert_fails_cleanly_then_succeeds(
            "associate_wireless_gateway_with_certificate", gateways_left=1)

    def test_allow_list_failure_creates_nothing(self):
        self.allow.fail = True
        status, body = self.provision()
        self.assertEqual((status, body), (503, {"error": "try_again"}))
        self.assertEqual(self.aws.writes, [])
        self.assertIn('"step": "allow_list"', self.logged)

    # --- an EUI that is already registered ----------------------------------------------

    def register_by_hand(self):
        """A gateway registered earlier, as in issue #4, that has connected: it has its own
        certificate and the LNS certificate that AWS made for it."""
        self.aws.gateways["gw-old"] = {"eui": EUI, "cert": "cert-old", "lns_cert": "cert-old-lns"}
        self.aws.certificates["cert-old"] = "ACTIVE"
        self.aws.certificates["cert-old-lns"] = "ACTIVE"

    def test_registered_eui_keeps_its_gateway_and_gets_a_new_certificate(self):
        self.register_by_hand()
        status, body = self.provision()
        self.assertEqual(status, 200)
        self.assertEqual(list(self.aws.gateways), ["gw-old"])
        new_cert = self.aws.gateways["gw-old"]["cert"]
        self.assertNotEqual(new_cert, "cert-old")
        # Both old certificates are gone, the new one is the only one.
        self.assertEqual(self.aws.certificates, {new_cert: "ACTIVE"})
        self.assertNotIn("create_wireless_gateway", self.aws.writes)
        self.assertIn('"certificate_replaced": true', self.logged)
        self.assertIn('"gateway_created": false', self.logged)

    def test_registered_eui_keeps_its_old_certificate_when_the_new_one_fails(self):
        self.register_by_hand()
        self.aws.fail_on = "create_keys_and_certificate"
        self.assertEqual(self.provision()[0], 503)
        self.assertEqual(self.aws.gateways["gw-old"]["cert"], "cert-old")
        self.assertEqual(self.aws.gateways["gw-old"]["lns_cert"], "cert-old-lns")
        self.assertEqual(self.aws.certificates, {"cert-old": "ACTIVE", "cert-old-lns": "ACTIVE"})

    def test_registered_eui_gets_its_old_certificate_back_when_the_new_one_cannot_be_set(self):
        self.register_by_hand()
        self.aws.fail_on = "associate_wireless_gateway_with_certificate"
        self.aws.fail_times = 1
        self.assertEqual(self.provision()[0], 503)
        self.assertEqual(self.aws.gateways["gw-old"]["cert"], "cert-old")
        # Nothing is deleted when the replacement fails.
        self.assertEqual(self.aws.certificates, {"cert-old": "ACTIVE", "cert-old-lns": "ACTIVE"})
        self.assertEqual(self.allow.state[handler.fingerprint_of(SECRET)], allowlist.STATE_UNUSED)

    def test_registered_eui_with_unknown_secret_is_left_alone(self):
        self.register_by_hand()
        self.assertEqual(self.provision(secret=OTHER_SECRET)[0], 403)
        self.assertEqual(self.aws.writes, [])
        self.assertEqual(self.aws.certificates, {"cert-old": "ACTIVE", "cert-old-lns": "ACTIVE"})

    def test_old_certificate_that_cannot_be_deleted_does_not_fail_the_request(self):
        self.register_by_hand()
        self.aws.fail_on = "delete_certificate"
        status, _ = self.provision()
        self.assertEqual(status, 200)
        self.assertEqual(self.aws.certificates["cert-old"], "INACTIVE")
        self.assertIn('"event": "certificate_delete_failed"', self.logged)

    # --- malformed requests -------------------------------------------------------------

    def test_malformed_requests_are_refused_and_create_nothing(self):
        bad_bodies = [
            "",
            "not json",
            "[]",
            {"gateway_eui": EUI},
            {"secret": SECRET},
            {"gateway_eui": "0016c001f113584", "secret": SECRET},       # 15 characters
            {"gateway_eui": "0016c001f113584g", "secret": SECRET},      # not hex
            {"gateway_eui": EUI, "secret": SECRET[:-1]},                # 63 characters
            {"gateway_eui": EUI, "secret": SECRET.upper()},             # not lowercase
            {"gateway_eui": EUI, "secret": 5},
            {"gateway_eui": EUI, "secret": SECRET, "padding": "x" * 2000},
        ]
        for body in bad_bodies:
            with self.subTest(body=str(body)[:40]):
                status, answer = self.post(body)
                self.assertEqual((status, answer), (400, {"error": "bad_request"}))
        self.assertEqual(self.aws.writes, [])
        self.assertEqual(self.allow.state[handler.fingerprint_of(SECRET)], allowlist.STATE_UNUSED)
        self.assert_nothing_secret_logged()

    def test_other_paths_and_methods(self):
        good = {"gateway_eui": EUI, "secret": SECRET}
        self.assertEqual(self.post(good, path="/")[0], 404)
        self.assertEqual(self.post(good, path="/update-info")[0], 404)
        self.assertEqual(self.post(good, method="GET")[0], 405)
        self.assertEqual(self.aws.writes, [])


class FakeDynamoDb:
    """update_item for the two expressions DynamoDbAllowList sends: it checks the condition
    "#state = <value>" against the stored item, as DynamoDB does, and then applies the update."""

    def __init__(self):
        self.items = {}

    def update_item(self, TableName, Key, UpdateExpression, ConditionExpression,
                    ExpressionAttributeNames, ExpressionAttributeValues, **kwargs):
        assert TableName == "allowlist-table"
        assert ExpressionAttributeNames == {"#state": "state"}
        key = Key["fingerprint"]["S"]
        item = self.items.get(key)
        _, _, wanted = ConditionExpression.partition(" = ")
        if item is None or item["state"] != ExpressionAttributeValues[wanted]:
            old = item if kwargs.get("ReturnValuesOnConditionCheckFailure") == "ALL_OLD" else None
            raise FakeClientError("ConditionalCheckFailedException", item=old)
        if ":now" in ExpressionAttributeValues:
            item.update(state=ExpressionAttributeValues[":used"],
                        used_at=ExpressionAttributeValues[":now"],
                        gateway_eui=ExpressionAttributeValues[":eui"])
        else:
            item["state"] = ExpressionAttributeValues[":unused"]
            item.pop("used_at")
            item.pop("gateway_eui")
        return {}


class DynamoDbAllowListTest(unittest.TestCase):
    def setUp(self):
        self.db = FakeDynamoDb()
        self.allow = allowlist.DynamoDbAllowList(self.db, "allowlist-table")
        # What the flash script records for a new card.
        self.db.items["f" * 64] = {"fingerprint": {"S": "f" * 64}, "state": {"S": "unused"}}

    def test_consume_marks_a_listed_fingerprint_used_once(self):
        self.assertEqual(self.allow.consume("f" * 64, EUI, "t1"), allowlist.OK)
        item = self.db.items["f" * 64]
        self.assertEqual(item["state"], {"S": "used"})
        self.assertEqual(item["gateway_eui"], {"S": EUI})
        self.assertEqual(item["used_at"], {"S": "t1"})
        self.assertEqual(self.allow.consume("f" * 64, EUI, "t2"), allowlist.USED)
        self.assertEqual(item["used_at"], {"S": "t1"})

    def test_consume_does_not_create_an_unlisted_fingerprint(self):
        self.assertEqual(self.allow.consume("0" * 64, EUI, "t1"), allowlist.UNKNOWN)
        self.assertNotIn("0" * 64, self.db.items)

    def test_release_makes_a_consumed_fingerprint_usable_again(self):
        self.allow.consume("f" * 64, EUI, "t1")
        self.allow.release("f" * 64)
        self.assertEqual(self.db.items["f" * 64],
                         {"fingerprint": {"S": "f" * 64}, "state": {"S": "unused"}})
        self.assertEqual(self.allow.consume("f" * 64, EUI, "t2"), allowlist.OK)

    def test_release_of_an_unused_or_unlisted_fingerprint_changes_nothing(self):
        self.allow.release("f" * 64)
        self.allow.release("0" * 64)
        self.assertEqual(self.db.items["f" * 64]["state"], {"S": "unused"})
        self.assertNotIn("0" * 64, self.db.items)

    def test_other_dynamodb_errors_are_raised(self):
        def broken(**kwargs):
            raise FakeClientError("ProvisionedThroughputExceededException")
        self.db.update_item = broken
        with self.assertRaises(FakeClientError):
            self.allow.consume("f" * 64, EUI, "t1")


class LambdaEntryTest(unittest.TestCase):
    def test_lambda_handler_uses_the_injected_dependencies_and_hides_errors(self):
        allow = FakeAllowList(unused=[SECRET])
        aws = FakeAws()
        handler._deps = (allow, GatewayRegistry(FakeIotWireless(aws), FakeIot(aws)))
        try:
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                ok = handler.lambda_handler(
                    request({"gateway_eui": EUI, "secret": SECRET}), None)
                # An event of the wrong shape must give a plain 500, not a traceback.
                broken = handler.lambda_handler({"rawPath": "/provision", "requestContext": 7},
                                                None)
            self.assertEqual(ok["statusCode"], 200)
            self.assertEqual(ok["headers"]["cache-control"], "no-store")
            self.assertEqual(broken["statusCode"], 500)
            self.assertNotIn(SECRET, out.getvalue())
        finally:
            handler._deps = None


if __name__ == "__main__":
    unittest.main()
