#!/bin/sh
# Le da a web01 un disco propio, separado del de la VM.
#
#   sudo sh scripts/disco-web01.sh            crea y monta el disco (4 GB por defecto)
#   sudo sh scripts/disco-web01.sh 8G         con otro tamaño (solo al crearlo)
#   sh scripts/disco-web01.sh --estado        diagnóstico, no necesita root
#   sudo sh scripts/disco-web01.sh --quitar   lo desmonta y lo borra
#
# Por qué: dentro del contenedor, "/" es un overlay que vive en el disco de la VM.
# Medir "/" desde web01 es medir la VM, y la prueba de disco llenaba el mismo disco
# donde están PostgreSQL, Loki y Zabbix. Con esto web01 escribe sus datos de prueba en
# /datos, un ext4 propio montado desde un archivo imagen, y Zabbix mide ese disco.
#
# Es un paso manual, como puente-lab.sh: necesita sudo y toca /etc/fstab de la VM, así
# que no lo hace iniciar.sh. Sin él el laboratorio anda igual, pero /datos queda como
# una carpeta común en el disco de la VM, y verificar.sh lo marca como fallo.
set -eu

IMAGEN=/var/lib/msr/web01-datos.img
PUNTO=/srv/msr/web01-datos
TAMANO=4G

estado() {
  if [ -f "$IMAGEN" ]; then echo "imagen:  $IMAGEN ($(du -h --apparent-size "$IMAGEN" | cut -f1))"
  else echo "imagen:  no existe"; fi
  if mountpoint -q "$PUNTO" 2>/dev/null; then
    echo "montaje: $PUNTO montado"
    df -h "$PUNTO" | tail -1
  else
    echo "montaje: $PUNTO NO está montado"
  fi
  if grep -q "^$IMAGEN " /etc/fstab 2>/dev/null; then echo "fstab:   entrada presente"
  else echo "fstab:   sin entrada"; fi
  if command -v docker >/dev/null 2>&1 && docker inspect web01 >/dev/null 2>&1; then
    # No alcanza con "mountpoint /datos" adentro: todo bind mount lo es. Se compara el
    # tamaño del filesystem que ve web01 con el del disco montado en la VM.
    if mountpoint -q "$PUNTO" 2>/dev/null &&
       [ "$(docker exec web01 stat -f -c %b /datos 2>/dev/null)" = "$(stat -f -c %b "$PUNTO")" ]; then
      echo "web01:   /datos es un montaje propio"
    else
      echo "web01:   /datos NO es un montaje propio (reiniciá web01 después de montar)"
    fi
  fi
}

reiniciar_web01() {
  # Un montaje hecho después de arrancar el contenedor no se ve adentro: el bind de
  # Docker apunta a la carpeta que había en ese momento. Hay que reiniciarlo.
  if command -v docker >/dev/null 2>&1 && docker inspect web01 >/dev/null 2>&1; then
    echo "Reiniciando web01 para que vea el disco nuevo"
    docker restart web01 >/dev/null
  fi
}

case "${1:-}" in
  --estado)
    estado
    exit 0
    ;;
  --quitar)
    [ "$(id -u)" -eq 0 ] || { echo "Necesita sudo" >&2; exit 1; }
    umount "$PUNTO" 2>/dev/null || true
    sed -i "\|^$IMAGEN |d" /etc/fstab
    rm -f "$IMAGEN"
    echo "Disco de web01 quitado. /datos vuelve a ser una carpeta del disco de la VM."
    reiniciar_web01
    exit 0
    ;;
  ''|*[0-9][GgMm])
    TAMANO=${1:-$TAMANO}
    ;;
  *)
    echo "Uso: sudo sh scripts/disco-web01.sh [tamaño, ej. 4G] | --estado | --quitar" >&2
    exit 1
    ;;
esac

[ "$(id -u)" -eq 0 ] || { echo "Necesita sudo: sudo sh scripts/disco-web01.sh" >&2; exit 1; }

mkdir -p "$(dirname "$IMAGEN")" "$PUNTO"

if [ ! -f "$IMAGEN" ]; then
  fallocate -l "$TAMANO" "$IMAGEN"
  # -m 0: sin bloques reservados para root. Así el % que ve df coincide con el
  # que calcula Zabbix y la prueba P3 llega exactamente al umbral.
  mkfs.ext4 -q -F -m 0 -L web01-datos "$IMAGEN"
  echo "Creada la imagen $IMAGEN de $TAMANO"
fi

# nofail: si la imagen faltara, la VM arranca igual en vez de quedar en modo emergencia.
# x-systemd.before=docker.service: con nofail, systemd no espera este montaje para
# seguir arrancando, y Docker podría levantar web01 antes; web01 quedaría apuntando a
# la carpeta vacía de abajo y mediría otra vez el disco de la VM sin que nada avise.
if ! grep -q "^$IMAGEN " /etc/fstab; then
  echo "$IMAGEN $PUNTO ext4 loop,defaults,nofail,x-systemd.before=docker.service 0 2" >> /etc/fstab
  echo "Agregada la entrada en /etc/fstab"
fi

if ! mountpoint -q "$PUNTO"; then
  mount "$PUNTO"
fi

reiniciar_web01
estado
