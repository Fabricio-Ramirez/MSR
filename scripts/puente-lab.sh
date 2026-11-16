#!/bin/sh
# Mete el adaptador host-only dedicado al laboratorio dentro del puente br-lab,
# para que las IP fijas de la documentacion se abran desde Windows tal cual.
#
# La idea: en vez de enrutar desde Windows hacia la red de Docker, se pone a
# Windows DENTRO de esa red. El adaptador host-only #2 de VirtualBox pasa a ser
# un puerto mas del puente br-lab, igual que los veth de los contenedores, asi
# que Windows (192.168.56.1) queda en el mismo segmento de capa 2 que web01
# (.10), zabbix-server (.20), zabbix-web (.21), zabbix-db (.22), grafana (.23)
# y loki (.24). No hay enrutamiento, no hay NAT y no hacen falta reglas nuevas
# de iptables: el trafico puenteado ni siquiera llega a netfilter mientras el
# modulo br_netfilter no este cargado, y en esta VM no lo esta.
#
# De paso, Windows pasa a ser el "PC de usuarios" que la propuesta pone en
# 192.168.56.1, con lo que desaparece una de las diferencias documentadas.
#
# Requisitos previos, del lado de VirtualBox (ver README.md, apartado 4):
#   - adaptador 3 de la VM en host-only, sobre un adaptador de Windows
#     configurado en 192.168.56.1/24 y con el DHCP de VirtualBox deshabilitado
#   - modo promiscuo "allow-all" en ese adaptador, si no VirtualBox descarta
#     las tramas que llevan las MAC de los contenedores
#
#   sudo scripts/puente-lab.sh            instala
#   sudo scripts/puente-lab.sh enp0s9     idem, forzando la interfaz
#   scripts/puente-lab.sh --estado        diagnostico, no necesita root
#   sudo scripts/puente-lab.sh --quitar   desinstala
set -eu

BRIDGE=br-lab
AYUDANTE=/usr/local/sbin/puente-lab-aplicar.sh
UNIDAD=/etc/systemd/system/puente-lab.service
TIMER=/etc/systemd/system/puente-lab.timer

# Una NIC fisica sin direccion IPv4 es la del laboratorio: el NAT y el host-only
# de administracion siempre tienen una, y los veth y los puentes no son fisicos.
detectar() {
  for ruta in /sys/class/net/*; do
    n=$(basename "$ruta")
    [ -e "$ruta/device" ] || continue
    if ip -4 -o addr show dev "$n" 2>/dev/null | grep -q .; then continue; fi
    echo "$n"
    return 0
  done
  return 1
}

maestro_de() { # interfaz -> nombre del puente, o cadena vacia si no tiene
  # Ojo: "readlink -f" sobre una ruta inexistente devuelve la ruta igual, asi que
  # hay que comprobar antes que el enlace exista; si no, todo parece tener un
  # puente llamado "master".
  [ -e "/sys/class/net/$1/master" ] || return 0
  basename "$(readlink -f "/sys/class/net/$1/master")"
}

estado() {
  echo "Puente $BRIDGE:"
  if [ -d "/sys/class/net/$BRIDGE" ]; then
    echo "  existe, con direccion $(ip -4 -o addr show dev "$BRIDGE" | awk '{print $4}')"
    echo "  puertos: $(ls "/sys/class/net/$BRIDGE/brif/" | tr '\n' ' ')"
  else
    echo "  NO existe. Levanta el stack primero: docker compose up -d"
  fi

  echo "NIC fisicas:"
  for ruta in /sys/class/net/*; do
    n=$(basename "$ruta")
    [ -e "$ruta/device" ] || continue
    ipv4=$(ip -4 -o addr show dev "$n" 2>/dev/null | awk '{print $4}' | tr '\n' ' ')
    m=$(maestro_de "$n")
    printf '  %-10s ipv4=%-18s puente=%s\n' "$n" "${ipv4:--}" "${m:--}"
  done

  if iface=$(detectar); then
    m=$(maestro_de "$iface")
    if [ "$m" = "$BRIDGE" ]; then
      echo "LISTO: $iface es puerto de $BRIDGE."
    else
      echo "PENDIENTE: $iface existe y esta libre, falta meterla en $BRIDGE."
      echo "           sudo scripts/puente-lab.sh"
    fi
  else
    echo "PENDIENTE: no hay ninguna NIC sin IPv4."
    echo "           Falta agregarle a la VM el adaptador 3 en host-only."
    echo "           Hay que apagarla: el chipset PIIX3 no admite NIC en caliente."
  fi

  echo "Modulo br_netfilter: $(lsmod | grep -cE '^br_netfilter ') (0 = el trafico puenteado no pasa por iptables, que es lo que queremos)"
}

case "${1:-}" in
  --estado|-e) estado; exit 0 ;;
esac

if [ "$(id -u)" != 0 ]; then
  echo "Hay que ejecutarlo con sudo: sudo $0 $*" >&2
  echo "Para ver el diagnostico sin root: $0 --estado" >&2
  exit 1
fi

if [ "${1:-}" = "--quitar" ]; then
  systemctl disable --now puente-lab.timer puente-lab.service >/dev/null 2>&1 || true
  if iface=$(detectar); then
    [ "$(maestro_de "$iface")" = "$BRIDGE" ] && ip link set "$iface" nomaster || true
  fi
  rm -f "$UNIDAD" "$TIMER" "$AYUDANTE"
  systemctl daemon-reload
  echo "Puente deshecho. El adaptador host-only queda suelto."
  echo "Para sacarlo del todo, apaga la VM y quitale el adaptador 3."
  exit 0
fi

# ---------- elegir la interfaz ----------

IFACE=${1:-}
if [ -z "$IFACE" ]; then
  if ! IFACE=$(detectar); then
    echo "FALLO: no encontre ninguna NIC fisica sin direccion IPv4." >&2
    echo "Falta agregarle a la VM el adaptador 3 en host-only, con la VM apagada." >&2
    echo "Diagnostico completo: $0 --estado" >&2
    exit 1
  fi
fi

if [ ! -d "/sys/class/net/$IFACE" ]; then
  echo "FALLO: la interfaz $IFACE no existe." >&2
  exit 1
fi

if ip -4 -o addr show dev "$IFACE" | grep -q .; then
  echo "FALLO: $IFACE tiene direccion IPv4. No es la del laboratorio." >&2
  echo "Si le metes una interfaz con IP a un puente, perdes esa IP y te podes" >&2
  echo "quedar sin acceso a la VM. Reviso y me planto." >&2
  exit 1
fi

if [ ! -d "/sys/class/net/$BRIDGE" ]; then
  echo "FALLO: el puente $BRIDGE no existe todavia." >&2
  echo "Levanta el stack primero: docker compose up -d" >&2
  exit 1
fi

echo "Interfaz del laboratorio: $IFACE"

# ---------- ayudante idempotente ----------

cat > "$AYUDANTE" <<EOF
#!/bin/sh
# Generado por scripts/puente-lab.sh del obligatorio de MSR.
# Vuelve a meter $IFACE en $BRIDGE cuando haga falta. Es idempotente y silencioso:
# lo dispara un timer, porque "docker compose down" borra el puente y "up" lo
# crea de nuevo, y en ese momento la interfaz queda suelta.
set -eu
[ -d /sys/class/net/$BRIDGE ] || exit 0
[ -d /sys/class/net/$IFACE ] || exit 0
ip link set $IFACE up
if [ -e /sys/class/net/$IFACE/master ]; then
  [ "\$(basename "\$(readlink -f /sys/class/net/$IFACE/master)")" = "$BRIDGE" ] && exit 0
fi
ip link set $IFACE master $BRIDGE
EOF
chmod 755 "$AYUDANTE"
"$AYUDANTE"

# ---------- unidades ----------

cat > "$UNIDAD" <<EOF
[Unit]
Description=Mete el host-only del laboratorio en el puente $BRIDGE
After=docker.service

[Service]
Type=oneshot
ExecStart=$AYUDANTE

[Install]
WantedBy=multi-user.target
EOF

cat > "$TIMER" <<'EOF'
[Unit]
Description=Reengancha el host-only al puente br-lab si Docker recreo la red

[Timer]
OnBootSec=30s
OnUnitActiveSec=1min
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now puente-lab.service >/dev/null
systemctl enable --now puente-lab.timer >/dev/null

# ---------- resumen ----------

echo
if [ "$(maestro_de "$IFACE")" = "$BRIDGE" ]; then
  echo "LISTO: $IFACE es puerto de $BRIDGE."
  echo "  puertos del puente: $(ls "/sys/class/net/$BRIDGE/brif/" | tr '\n' ' ')"
else
  echo "FALLO: $IFACE no quedo enganchada a $BRIDGE." >&2
  exit 1
fi
echo "  puente-lab.service y puente-lab.timer quedan activos: si corres"
echo "  'docker compose down', el timer la vuelve a enganchar en menos de un minuto."
echo
echo "Desde Windows ya se abren, sin agregar ninguna ruta:"
echo "  http://192.168.56.10        tienda"
echo "  http://192.168.56.21:8080   Zabbix"
echo "  http://192.168.56.23:3000   Grafana"
