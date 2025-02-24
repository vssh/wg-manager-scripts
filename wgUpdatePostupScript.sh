#! /bin/bash

SCRIPT_PATH=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
ENV_PATH="${SCRIPT_PATH}/.env"
source $ENV_PATH
UTILS_PATH="${SCRIPT_PATH}/utils"
CIDR_ENDING="\/32"

UTIL_GET_IP_FROM_SUBNET="${UTILS_PATH}/getIpFromSubnet.sh"

if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

CLIENTS_FILE_PATH="${WG_PATH}/${CONFIGS_DIR}/${CLIENTS_FILE}"

FULL_ACCESS_IPS=""
INTRANET_ACCESS_IPS=""
INTERNET_ACCESS_IPS=""
CUSTOM_ACCESS_IPS=""
FULL_ACCESS_NUM=0
INTRANET_ACCESS_NUM=0
INTERNET_ACCESS_NUM=0
CUSTOM_ACCESS_NUM=0

FULL_ACCESS_VAR="FULL_ACCESS_IPS"
INTRANET_ACCESS_VAR="INTRANET_ACCESS_IPS"
INTERNET_ACCESS_VAR="INTERNET_ACCESS_IPS"
CUSTOM_ACCESS_VAR="CUSTOM_ACCESS_IPS"

while read line; do
    if [[ $line != \#* ]]; then
        id=$(awk -F ';' '{print $2}' <<< "$line")
        ip=$("${UTIL_GET_IP_FROM_SUBNET}" "$VPN_SUBNET" "$id")
        access=$(awk -F ';' '{print $3}' <<< "$line")
        if [[ $access == $CLIENT_ACCESS_FULL ]]; then
            FULL_ACCESS_IPS="${FULL_ACCESS_IPS}${ip},"
            FULL_ACCESS_NUM=$(($FULL_ACCESS_NUM+1))
        elif [[ $access == $CLIENT_ACCESS_INTRANET ]]; then
            INTRANET_ACCESS_IPS="${INTRANET_ACCESS_IPS}${ip},"
            INTRANET_ACCESS_NUM=$(($INTRANET_ACCESS_NUM+1))
        elif [[ $access == $CLIENT_ACCESS_INTERNET ]]; then
            INTERNET_ACCESS_IPS="${INTERNET_ACCESS_IPS}${ip},"
            INTERNET_ACCESS_NUM=$(($INTERNET_ACCESS_NUM+1))
        elif [[ $access == $CLIENT_ACCESS_CUSTOM ]]; then
            CUSTOM_ACCESS_IPS="${CUSTOM_ACCESS_IPS}${ip},"
            CUSTOM_ACCESS_NUM=$(($CUSTOM_ACCESS_NUM+1))
        fi
    fi
done < $CLIENTS_FILE_PATH

FULL_ACCESS_IPS=$(sed 's/,$//' <<< $FULL_ACCESS_IPS)
INTRANET_ACCESS_IPS=$(sed 's/,$//' <<< $INTRANET_ACCESS_IPS)
INTERNET_ACCESS_IPS=$(sed 's/,$//' <<< $INTERNET_ACCESS_IPS)
CUSTOM_ACCESS_IPS=$(sed 's/,$//' <<< $CUSTOM_ACCESS_IPS)

RULES=""
VARS=""
IPTABLES_CHAIN="iptables -A \$CHAIN_NAME -i \$WIREGUARD_INTERFACE"
WIREGUARD_LAN_VAR="\$WIREGUARD_LAN"
SERVER_LOCAL_CIDR_VAR="\$SERVER_LOCAL_CIDR"
function appendToRules() {
    RULES="${RULES}\n$1"
}

function appendToVars() {
    VARS="${VARS}\n$1"
}

appendToVars "WIREGUARD_INTERFACE=${INTERFACE_NAME}"
appendToVars "WIREGUARD_LAN=${VPN_SUBNET}/24"
appendToVars "MASQUERADE_INTERFACE=${NETWORK_INTERFACE}"
appendToVars "CHAIN_NAME=WIREGUARD_${INTERFACE_NAME}"

appendToVars "SERVER_LOCAL_CIDR_VAR=$SERVER_LOCAL_CIDR"
appendToVars ""

if [[ $INTERNET_ACCESS_NUM > 0 ]]; then
    appendToRules "# Deny server intranet access to internet-only clients"
    appendToRules "${IPTABLES_CHAIN} -s \$$INTERNET_ACCESS_VAR -d $SERVER_LOCAL_CIDR_VAR -j DROP"
fi

if [[ $(($FULL_ACCESS_NUM+$INTERNET_ACCESS_NUM)) > 0 ]]; then
    appendToRules ""

    if [[ $(($CUSTOM_ACCESS_NUM+$INTRANET_ACCESS_NUM)) == 0 ]]; then
        appendToRules "# Allow full access to all clients"
        appendToRules "${IPTABLES_CHAIN} -s $WIREGUARD_LAN_VAR -j ACCEPT"
    else
        if [[ $FULL_ACCESS_NUM > 0 ]]; then
            appendToVars "$FULL_ACCESS_VAR=$FULL_ACCESS_IPS"

            appendToRules "# Allow full access to clients with full access level"
            appendToRules "${IPTABLES_CHAIN} -s \$$FULL_ACCESS_VAR -j ACCEPT"
        fi
        if [[ $INTERNET_ACCESS_NUM > 0 ]]; then
            appendToVars "$INTERNET_ACCESS_VAR=$INTERNET_ACCESS_IPS"

            appendToRules "# Allow full access to internet-only clients"
            appendToRules "${IPTABLES_CHAIN} -s \$$INTERNET_ACCESS_VAR -j ACCEPT"
        fi
    fi
fi

if [[ $INTRANET_ACCESS_NUM > 0 ]]; then
    appendToRules ""

    if [[ $CUSTOM_ACCESS_NUM == 0 ]]; then
        appendToRules "# Allow server intranet access to all clients"
        appendToRules "${IPTABLES_CHAIN} -s $WIREGUARD_LAN_VAR -d $SERVER_LOCAL_CIDR_VAR -j ACCEPT"
    else
        appendToVars "$INTRANET_ACCESS_VAR=$INTRANET_ACCESS_IPS"

        appendToRules "# Allow server intranet access to clients with intranet access level"
        appendToRules "${IPTABLES_CHAIN} -s \$$INTRANET_ACCESS_VAR -d $SERVER_LOCAL_CIDR_VAR -j ACCEPT"
    fi
fi

if [[ $CUSTOM_ACCESS_NUM > 0 ]]; then
    appendToVars "$CUSTOM_ACCESS_VAR=$CUSTOM_ACCESS_IPS"
    appendToRules ""
    appendToRules "# Allow custom access to clients with custom access level"
    lines=(${CLIENT_CUSTOM_IP_PORT//;/ })
    for line in "${lines[@]}"; do
        protocol_parts=(${line//|/ })
        protocol="${protocol_parts[1]}"
        parts=(${protocol_parts[0]//#/ })
        ip="${parts[0]}"
        ports="${parts[1]}"
        port_parts=(${ports//,/ })
        ports_num=${#port_parts[@]}
        if [[ $ports_num == 0 ]]; then
            appendToRules "${IPTABLES_CHAIN} -s \$$CUSTOM_ACCESS_VAR -d $ip -j ACCEPT"
        elif [[ $ports_num == 1 ]]; then
            appendToRules "${IPTABLES_CHAIN} -s \$$CUSTOM_ACCESS_VAR -d $ip -p $protocol --dport $ports -j ACCEPT"
        else
            appendToRules "${IPTABLES_CHAIN} -s \$$CUSTOM_ACCESS_VAR -d $ip -p $protocol -m multiport --dport $ports -j ACCEPT"
        fi
    done

fi

WG_LAN_CIDR=$("$UTIL_GET_IP_FROM_SUBNET" "$VPN_SUBNET" "0")
WG_LAN_CIDR="${WG_LAN_CIDR}/24"
POSTUP_CONTENT=$(cat "${SCRIPT_PATH}/${POSTUP_TEMPLATE_FILE}")
POSTUP_CONTENT="${POSTUP_CONTENT/'[[INTERFACE_NAME]]'/${INTERFACE_NAME}}"
POSTUP_CONTENT="${POSTUP_CONTENT/'[[WIREGUARD_LAN]]'/${WG_LAN_CIDR}}"
POSTUP_CONTENT="${POSTUP_CONTENT/'[[NETWORK_INTERFACE]]'/${NETWORK_INTERFACE}}"
POSTUP_CONTENT="${POSTUP_CONTENT/'[[AUTOMATED_VARIABLE_INSERTION]]'/$(echo -e $VARS)}"
POSTUP_CONTENT="${POSTUP_CONTENT/'[[AUTOMATED_RULES_INSERTION]]'/$(echo -e $RULES)}"

POSTUP_PATH="${WG_PATH}/${POSTUP_FILE}"
echo "$POSTUP_CONTENT" > "${WG_PATH}/${POSTUP_FILE}"
chmod 744 "${WG_PATH}/${POSTUP_FILE}"
