#!/bin/sh
# Genera las contraseñas y la PSK del agente. No sobrescribe lo que ya existe.
#
# El laboratorio no usa TLS ni certificados: el cifrado que pide la letra
# ("siempre que sea posible, utilice protocolos que cifren la información, ej. SNMPv3")
# lo aportan SNMPv3 authPriv (SHA/AES) y la TLS-PSK del agente Zabbix.
set -eu
cd "$(dirname "$0")/.."
umask 077

mkdir -p secrets

if [ ! -f .env ]; then
  {
    echo "ZABBIX_DB_PASSWORD=$(openssl rand -hex 16)"
    echo "GRAFANA_PASSWORD=$(openssl rand -hex 12)"
    echo "SNMP_AUTH=$(openssl rand -hex 12)"
    echo "SNMP_PRIV=$(openssl rand -hex 12)"
  } > .env
  echo "Creado .env"
fi

if [ ! -f secrets/web01.psk ]; then
  openssl rand -hex 32 > secrets/web01.psk
  echo "Creada PSK de web01"
fi

# El agente corre con el usuario zabbix dentro del contenedor y necesita leer la PSK.
# Aceptable en un laboratorio; .env queda restringido.
chmod 755 secrets
chmod 644 secrets/web01.psk
chmod 600 .env

echo "Listo. Siguiente paso: docker compose up -d --build"
