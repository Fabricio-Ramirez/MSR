#!/bin/sh
set -eu

# ---------- Zabbix agent 2 con TLS-PSK ----------
install -o zabbix -g zabbix -m 640 /secrets/web01.psk /etc/zabbix/web01.psk
mkdir -p /run/zabbix /var/log/zabbix
chown zabbix:zabbix /run/zabbix /var/log/zabbix

CONF=/etc/zabbix/zabbix_agent2.conf
# UserParameter también se borra antes de agregarlo: este bloque corre en cada
# arranque, y una clave repetida hace que el agente 2 no arranque.
sed -i -E '/^(Server|ServerActive|Hostname|TLSConnect|TLSAccept|TLSPSKIdentity|TLSPSKFile|UserParameter)=/d' "$CONF"
cat >> "$CONF" <<'EOF'
Server=192.168.56.20
ServerActive=192.168.56.20
Hostname=web01
TLSConnect=psk
TLSAccept=psk
TLSPSKIdentity=PSK-web01
TLSPSKFile=/etc/zabbix/web01.psk
# Métricas del contenedor (cgroup v2), no de la VM. Ver contenedor-metricas.sh y
# el template zabbix/template-contenedor-web01.yaml.
UserParameter=contenedor[*],/usr/local/bin/contenedor-metricas.sh "$1"
EOF

# ---------- SNMPv3 authPriv, sin comunidades v1/v2c ----------
# El usuario se crea UNA sola vez: queda guardado en /var/lib/snmp/snmpd.conf,
# que es la base persistente de USM y sobrevive a los reinicios.
if [ ! -f /var/lib/snmp/.usuario-creado ]; then
  net-snmp-create-v3-user -ro -a SHA -A "$SNMP_AUTH" -x AES -X "$SNMP_PRIV" zbxv3
  touch /var/lib/snmp/.usuario-creado
fi
chown -R Debian-snmp:Debian-snmp /var/lib/snmp

# El archivo se escribe DESPUÉS de crear el usuario, y no es casualidad.
# net-snmp-create-v3-user agrega por su cuenta un "rouser zbxv3" a este mismo
# archivo, pero sin nivel, con lo que alcanzaría con authNoPriv. Reescribirlo
# acá deja una sola regla, la nuestra, que exige authPriv.
#
# Al revés —que era como estaba— el contenedor funciona la primera vez y se
# rompe en el segundo arranque: el usuario ya existe, así que el bloque de
# arriba no corre, pero este cat borra igual la línea rouser y snmpd contesta
# "authorizationError" aunque la autenticación sea correcta.
cat > /etc/snmp/snmpd.conf <<'EOF'
agentaddress udp:192.168.56.10:161
rouser zbxv3 priv
sysLocation Laboratorio MSR - Tienda online
sysContact soporte@tienda.local
EOF

# ---------- /datos: disco propio de web01 ----------
# /datos es un filesystem aparte (scripts/disco-web01.sh) montado desde la VM. Ahí
# escriben las pruebas de disco, así que llenarlo no llena el disco de la VM ni
# afecta a Zabbix. El panel de la tienda corre como www-data y necesita escribir.
mkdir -p /datos/relleno
chown www-data:www-data /datos/relleno

# ---------- Grafana Alloy ----------
mkdir -p /var/lib/alloy/data
chown -R alloy:alloy /var/lib/alloy

# ---------- fcgiwrap: endpoint de las pruebas de carga ----------
# /run es de root, así que el socket va en un subdirectorio propio de www-data.
mkdir -p /run/fcgiwrap
# En Docker /run NO es tmpfs: el socket del arranque anterior sigue ahí después
# de un "docker start" o de reiniciar la VM, y fcgiwrap no puede volver a
# escuchar sobre un archivo que ya existe. Se cae al instante, supervisord lo
# marca FATAL y /api/carga deja de responder. Hay que borrarlo antes.
rm -f /run/fcgiwrap/fcgiwrap.sock
chown www-data:www-data /run/fcgiwrap

nginx -t

exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
