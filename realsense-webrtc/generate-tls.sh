#!/usr/bin/env bash
set -Eeuo pipefail

TLS_DIR="${TLS_DIR:-/etc/mediamtx/tls}"
MEDIAMTX_GROUP="${MEDIAMTX_GROUP:-mediamtx}"
TLS_EXTRA_NAMES="${TLS_EXTRA_NAMES:-}"
FORCE=0

usage() {
    cat <<'EOF'
Usage: sudo ./generate-tls.sh [--force]

Creates a private CA and a MediaMTX server certificate. Hostnames and current
non-loopback IP addresses are added as subjectAltName entries. Add comma-
separated names or addresses with TLS_EXTRA_NAMES.

Environment:
  TLS_DIR=/etc/mediamtx/tls
  MEDIAMTX_GROUP=mediamtx
  TLS_EXTRA_NAMES=robot.example.test,10.0.0.20
EOF
}

case "${1:-}" in
    "") ;;
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

[[ "$EUID" -eq 0 ]] || {
    echo "Run this script as root." >&2
    exit 1
}

for command in openssl hostname ip; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "Missing command: $command" >&2
        exit 1
    }
done

getent group "$MEDIAMTX_GROUP" >/dev/null 2>&1 || {
    echo "Group does not exist: $MEDIAMTX_GROUP" >&2
    exit 1
}

# The directory is traversable so an unprivileged operator can copy ca.crt.
# Private material remains protected by file modes (ca.key 0600, server.key 0640).
install -d -m 0755 -o root -g root "$TLS_DIR"

if [[ -e "$TLS_DIR/server.crt" || -e "$TLS_DIR/server.key" ]]; then
    if [[ "$FORCE" -ne 1 ]]; then
        if [[ -s "$TLS_DIR/server.crt" && -s "$TLS_DIR/server.key" ]]; then
            echo "Keeping existing TLS certificate and key in $TLS_DIR"
            exit 0
        fi
        echo "Only one of server.crt/server.key exists. Repair it or rerun with --force." >&2
        exit 1
    fi
    backup="$TLS_DIR/backup-$(date -u +%Y%m%dT%H%M%SZ)"
    install -d -m 0700 -o root -g root "$backup"
    for file in ca.crt ca.key ca.srl server.crt server.csr server.key; do
        [[ -e "$TLS_DIR/$file" ]] && mv "$TLS_DIR/$file" "$backup/"
    done
    echo "Moved the previous TLS material to $backup"
fi

declare -a dns_names=()
declare -a ip_addresses=()
declare -A seen_dns=()
declare -A seen_ip=()

add_dns() {
    local name="$1"
    [[ -n "$name" ]] || return 0
    [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || {
        echo "Invalid DNS name: $name" >&2
        exit 1
    }
    [[ -n "${seen_dns[$name]:-}" ]] && return 0
    seen_dns["$name"]=1
    dns_names+=("$name")
}

add_ip() {
    local address="${1%%%*}"
    [[ -n "$address" ]] || return 0
    [[ "$address" =~ ^[0-9A-Fa-f:.]+$ ]] || {
        echo "Invalid IP address: $address" >&2
        exit 1
    }
    [[ -n "${seen_ip[$address]:-}" ]] && return 0
    seen_ip["$address"]=1
    ip_addresses+=("$address")
}

short_hostname="$(hostname -s)"
fqdn="$(hostname -f 2>/dev/null || hostname)"
add_dns "$short_hostname"
add_dns "$fqdn"
add_dns "${short_hostname}.local"
add_dns localhost
add_ip 127.0.0.1
add_ip ::1

while IFS= read -r address; do
    add_ip "$address"
done < <(ip -o -4 address show scope global | awk '{sub(/\/.*/, "", $4); print $4}')

while IFS= read -r address; do
    add_ip "$address"
done < <(ip -o -6 address show scope global | awk '{sub(/\/.*/, "", $4); print $4}')

if [[ -n "$TLS_EXTRA_NAMES" ]]; then
    IFS=',' read -r -a extra_names <<<"$TLS_EXTRA_NAMES"
    for name in "${extra_names[@]}"; do
        name="${name//[[:space:]]/}"
        if [[ "$name" == *:* || "$name" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            add_ip "$name"
        else
            add_dns "$name"
        fi
    done
fi

openssl_config="$(mktemp)"
trap 'rm -f "$openssl_config"' EXIT

cat >"$openssl_config" <<EOF
[req]
distinguished_name = subject
prompt = no

[subject]
CN = ${fqdn}

[server_ext]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
EOF

index=1
for name in "${dns_names[@]}"; do
    printf 'DNS.%d = %s\n' "$index" "$name" >>"$openssl_config"
    ((index += 1))
done

index=1
for address in "${ip_addresses[@]}"; do
    printf 'IP.%d = %s\n' "$index" "$address" >>"$openssl_config"
    ((index += 1))
done

umask 077
openssl genrsa -out "$TLS_DIR/ca.key" 3072
openssl req -x509 -new -sha256 \
    -key "$TLS_DIR/ca.key" \
    -days 3650 \
    -subj "/CN=Teleimager Local CA" \
    -out "$TLS_DIR/ca.crt"

openssl genrsa -out "$TLS_DIR/server.key" 2048
openssl req -new -sha256 \
    -key "$TLS_DIR/server.key" \
    -config "$openssl_config" \
    -out "$TLS_DIR/server.csr"
openssl x509 -req -sha256 \
    -in "$TLS_DIR/server.csr" \
    -CA "$TLS_DIR/ca.crt" \
    -CAkey "$TLS_DIR/ca.key" \
    -CAcreateserial \
    -days 397 \
    -extfile "$openssl_config" \
    -extensions server_ext \
    -out "$TLS_DIR/server.crt"

rm -f "$TLS_DIR/server.csr"
chown root:root "$TLS_DIR/ca.key" "$TLS_DIR/ca.crt"
chown root:"$MEDIAMTX_GROUP" "$TLS_DIR/server.key" "$TLS_DIR/server.crt"
chmod 0600 "$TLS_DIR/ca.key"
chmod 0644 "$TLS_DIR/ca.crt" "$TLS_DIR/server.crt"
chmod 0640 "$TLS_DIR/server.key"

echo "Created $TLS_DIR/server.crt with these subjectAltName values:"
openssl x509 -in "$TLS_DIR/server.crt" -noout -ext subjectAltName
echo "Trust this CA on client machines: $TLS_DIR/ca.crt"
