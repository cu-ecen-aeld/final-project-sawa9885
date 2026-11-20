# Register a gateway in AWS IoT Core for LoRaWAN and create its certificate (issue #10).
#
# This does what docs/aws-iot-core-setup.md does by hand, with the same API calls:
#
#   1. iotwireless GetServiceEndpoint (CUPS)       -> cups.uri and cups.trust
#   2. iotwireless GetWirelessGateway by EUI, or CreateWirelessGateway when there is none
#   3. iot CreateKeysAndCertificate                -> cups.crt and cups.key
#   4. iotwireless AssociateWirelessGatewayWithCertificate
#
# A gateway whose EUI is already registered (a card that was flashed again) keeps its gateway
# record. It gets a new certificate, and the certificates it had are revoked and deleted, so a
# gateway has one working set of credentials at a time: the one on its newest card. "The
# certificates it had" are two: the gateway certificate (cups.crt), and the LNS certificate
# that AWS's CUPS server made for it when it first connected (tc.crt on the gateway).
# Disassociating the first one drops the second from the gateway record too, and AWS makes a
# new LNS certificate when the gateway next asks CUPS.
#
# If a step fails, the certificate made in this call is deleted again and RegistrationError is
# raised. A gateway record made in this call is left in place: it holds no secret, and the next
# try finds it in step 2. That is why the function's role needs no permission to delete gateways.
#
# The private key exists only in the value this returns. Nothing here logs it.
#
# This file was partially generated using Claude Code using the chat session at:
# Link to chat session (issue #10): https://claude.ai/code/cshk_01CSAPnw19XXA81xkir2Ei316vsRvZPpL3YkJGDGzNdFWr


class RegistrationError(Exception):
    """AWS could not register the gateway. The caller may try again later."""


def _error_code(exc):
    response = getattr(exc, "response", None)
    if isinstance(response, dict):
        return response.get("Error", {}).get("Code")
    return None


def _describe(exc):
    """An exception as one log-safe word: the AWS error code, or the exception's class name."""
    return _error_code(exc) or type(exc).__name__


class GatewayRegistry:
    def __init__(self, iotwireless_client, iot_client, rf_region="US915", log=None):
        self._wireless = iotwireless_client
        self._iot = iot_client
        self._rf_region = rf_region
        self._log = log or (lambda event, **fields: None)

    def register(self, gateway_eui):
        """Returns a dict with cups.uri, cups.trust, cups.crt, cups.key and, for the log,
        gateway_id, gateway_created and certificate_replaced."""
        new_cert_id = None
        try:
            endpoint = self._wireless.get_service_endpoint(ServiceType="CUPS")
            gateway_id, created = self._find_or_create(gateway_eui)
            old_cert_ids = [] if created else self._current_certificates(gateway_id)

            cert = self._iot.create_keys_and_certificate(setAsActive=True)
            new_cert_id = cert["certificateId"]

            if old_cert_ids:
                self._wireless.disassociate_wireless_gateway_from_certificate(Id=gateway_id)
            try:
                self._wireless.associate_wireless_gateway_with_certificate(
                    Id=gateway_id, IotCertificateId=new_cert_id)
            except Exception:
                if old_cert_ids:
                    self._restore(gateway_id, old_cert_ids[0])
                raise
        except Exception as exc:
            if new_cert_id:
                self._delete_certificate(new_cert_id, "new")
            raise RegistrationError(_describe(exc)) from exc

        # From here on the gateway works with its new certificate, so nothing below may fail
        # the request.
        for cert_id in old_cert_ids:
            self._delete_certificate(cert_id, "replaced")

        uri = endpoint["ServiceEndpoint"]
        if "://" not in uri:
            uri = "https://" + uri
        return {
            "cups.uri": uri,
            "cups.trust": endpoint["ServerTrust"],
            "cups.crt": cert["certificatePem"],
            "cups.key": cert["keyPair"]["PrivateKey"],
            "gateway_id": gateway_id,
            "gateway_created": created,
            "certificate_replaced": bool(old_cert_ids),
        }

    def _find_or_create(self, gateway_eui):
        try:
            found = self._wireless.get_wireless_gateway(
                Identifier=gateway_eui, IdentifierType="GatewayEui")
            return found["Id"], False
        except Exception as exc:
            if _error_code(exc) != "ResourceNotFoundException":
                raise
        made = self._wireless.create_wireless_gateway(
            Name="gateway-" + gateway_eui,
            Description="Registered by the gateway provisioning function",
            LoRaWAN={"GatewayEui": gateway_eui, "RfRegion": self._rf_region},
        )
        return made["Id"], True

    def _current_certificates(self, gateway_id):
        """The gateway's certificate and, after it, its LNS certificate. Empty if it has none."""
        try:
            found = self._wireless.get_wireless_gateway_certificate(Id=gateway_id)
        except Exception as exc:
            if _error_code(exc) != "ResourceNotFoundException":
                raise
            return []
        if not found.get("IotCertificateId"):
            return []
        ids = [found["IotCertificateId"]]
        if found.get("LoRaWANNetworkServerCertificateId"):
            ids.append(found["LoRaWANNetworkServerCertificateId"])
        return ids

    def _restore(self, gateway_id, old_cert_id):
        """Give the gateway its old certificate back after the new one could not be associated."""
        try:
            self._wireless.associate_wireless_gateway_with_certificate(
                Id=gateway_id, IotCertificateId=old_cert_id)
        except Exception as exc:
            self._log("certificate_restore_failed", gateway_id=gateway_id, error=_describe(exc))

    def _delete_certificate(self, cert_id, which):
        """Revoke and delete a certificate. Failure is logged, not raised."""
        try:
            self._iot.update_certificate(certificateId=cert_id, newStatus="INACTIVE")
            self._iot.delete_certificate(certificateId=cert_id)
        except Exception as exc:
            self._log("certificate_delete_failed", which=which,
                      certificate=cert_id[:8], error=_describe(exc))
