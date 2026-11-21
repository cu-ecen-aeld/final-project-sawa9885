#!/bin/bash
# Create (or delete) the AWS IoT identity gwmon publishes its health report with (issue #13).
#
#   scripts/create-health-thing.sh create <gateway EUI> <output directory>
#   scripts/create-health-thing.sh delete <gateway EUI>
#
# "create" makes, in the AWS CLI's current account and region:
#   - one IoT thing        aesd-gateway-<eui>-health
#   - one IoT policy       aesd-gateway-<eui>-health, which allows two things only:
#                          iot:Connect as client ID aesd-gateway-<eui>-health, and
#                          iot:Publish and iot:RetainPublish to the topic aesd/gateway/<eui>/health
#   - one certificate with its key pair, active, with the policy and the thing attached
# and writes three files into the output directory, with the names S35provision looks for on
# the gateway's boot partition:
#   health.endpoint   the account's AWS IoT data endpoint (host name)
#   health.crt        the certificate
#   health.key        the private key (AWS does not keep a copy)
# Copy the three files to the boot partition of the SD card. The gateway moves them to
# /etc/gwmon-health at its next boot. Keep the output directory out of any repository.
#
# "delete" removes the certificate(s) of the thing, the policy and the thing.
#
# The script prints names only: no key, no certificate, no account number and no endpoint.
#
# This file was partially generated using Claude Code using the chat session at:
# Link to chat session (issue #13): https://claude.ai/code/cshk_01CSAPnymCy5ytzpd5YbDkk7GDXruVUH4TTxff71FBWGSW

set -euo pipefail

usage() {
	sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'
	exit 2
}

[ $# -ge 2 ] || usage
action=$1
eui=$(echo "$2" | tr 'A-F' 'a-f')
[[ $eui =~ ^[0-9a-f]{16}$ ]] || { echo "the gateway EUI must be 16 hex digits" >&2; exit 2; }
name="aesd-gateway-$eui-health"

case "$action" in
create)
	[ $# -eq 3 ] || usage
	out=$3
	umask 077
	mkdir -p "$out"
	for f in health.endpoint health.crt health.key; do
		[ ! -e "$out/$f" ] || { echo "$out/$f exists already, not overwriting it" >&2; exit 1; }
	done

	account=$(aws sts get-caller-identity --query Account --output text)
	region=$(aws configure get region)
	policy=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": "iot:Connect",
      "Resource": "arn:aws:iot:$region:$account:client/$name" },
    { "Effect": "Allow", "Action": [ "iot:Publish", "iot:RetainPublish" ],
      "Resource": "arn:aws:iot:$region:$account:topic/aesd/gateway/$eui/health" }
  ]
}
EOF
	)

	aws iot create-thing --thing-name "$name" >/dev/null
	echo "thing $name created"
	aws iot create-policy --policy-name "$name" --policy-document "$policy" >/dev/null
	echo "policy $name created (connect as $name, publish and retain on aesd/gateway/$eui/health)"
	cert_arn=$(aws iot create-keys-and-certificate --set-as-active \
		--certificate-pem-outfile "$out/health.crt" --private-key-outfile "$out/health.key" \
		--query certificateArn --output text)
	cert_id=${cert_arn##*/}
	echo "certificate ${cert_id:0:8} created and active"
	aws iot attach-policy --policy-name "$name" --target "$cert_arn"
	aws iot attach-thing-principal --thing-name "$name" --principal "$cert_arn"
	echo "policy and thing attached to the certificate"
	aws iot describe-endpoint --endpoint-type iot:Data-ATS --query endpointAddress --output text \
		>"$out/health.endpoint"
	echo "wrote health.endpoint, health.crt and health.key to $out"
	;;
delete)
	for arn in $(aws iot list-thing-principals --thing-name "$name" --query 'principals[]' --output text); do
		id=${arn##*/}
		aws iot detach-thing-principal --thing-name "$name" --principal "$arn"
		aws iot detach-policy --policy-name "$name" --target "$arn"
		aws iot update-certificate --certificate-id "$id" --new-status INACTIVE
		aws iot delete-certificate --certificate-id "$id"
		echo "certificate ${id:0:8} deleted"
	done
	aws iot delete-policy --policy-name "$name"
	echo "policy $name deleted"
	aws iot delete-thing --thing-name "$name"
	echo "thing $name deleted"
	;;
*)
	usage
	;;
esac
