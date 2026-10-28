#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=setup.sh
source ./setup.sh

valid() (
    DOMAIN=$1 EMAIL=$2 SSH_PORT=$3
    validate_inputs
)

invalid() {
    if valid "$@" >/dev/null 2>&1; then
        printf 'FAIL: accepted invalid input: %s\n' "$*" >&2
        exit 1
    fi
}

valid shop.example.com admin+oro@example.com 22
valid shop-2.example.com admin@example.com 65535
DOMAIN=shop.example.com EMAIL=admin@example.com SSH_PORT=0022
validate_inputs
[[ $SSH_PORT == 22 ]]
# shellcheck disable=SC2016
for domain in '' localhost 127.0.0.1 '*.example.com' '-shop.example.com' \
    'shop-.example.com' '.shop.example.com' 'shop.example.com.' \
    'shop..example.com' 'shop_example.com' 'SHOP.example.com' \
    'shop.example.com;id' '$(id).example.com' $'shop.example.com\nserver' \
    "$(printf 'a%.0s' {1..64}).example.com"; do
    invalid "$domain" admin@example.com 22
done
for email in '' admin admin@example $'admin@example.com\n' 'a;id@example.com'; do
    invalid shop.example.com "$email" 22
done
for port in '' 0 65536 99999999999 -1 '22/tcp' '22;id'; do
    invalid shop.example.com admin@example.com "$port"
done

bash setup.sh --help | grep -q 'Usage:'
for option in --domain --email --ssh-port --unknown; do
    if bash setup.sh "$option" >/dev/null 2>&1; then
        printf 'FAIL: accepted missing or unknown argument: %s\n' "$option" >&2
        exit 1
    fi
done

# Verify the overwrite guard using isolated command stubs; no server files are changed.
# shellcheck disable=SC2329
(
    id() { return 0; }
    getent() { return 1; }
    if (check_fresh_server) >/dev/null 2>&1; then
        printf 'FAIL: accepted existing deployment user\n' >&2
        exit 1
    fi
)
# shellcheck disable=SC2329
(
    id() { return 1; }
    getent() { return 0; }
    if (check_fresh_server) >/dev/null 2>&1; then
        printf 'FAIL: accepted existing deployment group\n' >&2
        exit 1
    fi
)
printf 'Setup validation tests passed.\n'
