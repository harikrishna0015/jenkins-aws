#!/bin/bash
# Update the Jenkins controller security group to your CURRENT public IP.
#
# Run this whenever your Jenkins becomes unreachable — it almost always means
# your home ISP rotated your public IP and the SG is (correctly) blocking you.
#
# Usage: ./scripts/update-my-ip.sh
# Requires: the AWS CLI and a controller SG with existing <OLD_IP>/32 rules on 22+8080.
set -euo pipefail

CONTROLLER_SG="sg-020eea3decad86498"
NEW_IP="$(curl -s https://checkip.amazonaws.com)"
echo "==> Your current public IP: ${NEW_IP}"

# Find the OLD IP/32 rules currently on ports 22 and 8080 (the ones to replace).
# We look for /32 (single-host) rules only, so we never touch the 172.31.0.0/16
# VPC rule that the ECS agents rely on.
replace_rule() {
    local port=$1
    local old_cidr
    # List all /32 cidrs on this port, then pick the first that's not the VPC CIDR.
    old_cidr=$(aws ec2 describe-security-groups --group-ids "${CONTROLLER_SG}" \
        --query "SecurityGroups[0].IpPermissions[?FromPort==\`${port}\`].IpRanges[].CidrIp" \
        --output text 2>/dev/null | tr '\t' '\n' | grep '/32' | grep -v '^172\.31\.' | head -1 || true)

    if [ -z "${old_cidr}" ]; then
        echo "    port ${port}: no existing /32 rule to replace, adding ${NEW_IP}/32"
        aws ec2 authorize-security-group-ingress --group-id "${CONTROLLER_SG}" \
            --protocol tcp --port "${port}" --cidr "${NEW_IP}/32" >/dev/null
        return
    fi

    if [ "${old_cidr}" = "${NEW_IP}/32" ]; then
        echo "    port ${port}: already ${NEW_IP}/32, nothing to do"
        return
    fi

    echo "    port ${port}: ${old_cidr} -> ${NEW_IP}/32"
    aws ec2 revoke-security-group-ingress --group-id "${CONTROLLER_SG}" \
        --protocol tcp --port "${port}" --cidr "${old_cidr}" >/dev/null
    aws ec2 authorize-security-group-ingress --group-id "${CONTROLLER_SG}" \
        --protocol tcp --port "${port}" --cidr "${NEW_IP}/32" >/dev/null
}

echo "==> Updating controller SG ${CONTROLLER_SG}"
replace_rule 22
replace_rule 8080

echo "==> Done. Jenkins should be reachable again:"
echo "    http://34.193.211.17:8080"
