#!/bin/sh
# Endpoint CGI de las pruebas de carga, para dispararlas desde el panel oculto de la
# tienda durante la defensa. Equivale a scripts/pruebas.sh p1, p2 y p3.
#
# Seguridad: las acciones son fijas y se eligen con un `case`. Nada de lo que manda el
# navegador llega nunca a un comando, así que no hay forma de inyectar órdenes. Corre
# como www-data, nunca como root.
set -u

ESTADO=/tmp/carga.estado
RELLENO=/var/tmp/carga-web.img
# 10 minutos, igual que P1 y P2 de la propuesta. No bajar de esto: los triggers de CPU
# y RAM usan min(...,5m), o sea que exigen 5 minutos sostenidos por encima del umbral;
# con una carga de 5 minutos justos el trigger dispara al borde o no dispara.
DURACION=600
OBJETIVO_DISCO=85     # porcentaje

responder() {
  printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n%s\n' "$1"
}

corriendo() {
  pgrep -u "$(id -u)" -x stress-ng >/dev/null 2>&1
}

lanzar() { # etiqueta comando...
  etiqueta=$1; shift
  printf '%s %s\n' "$etiqueta" "$(date +%s)" > "$ESTADO"
  setsid nohup "$@" >/dev/null 2>&1 &
}

uso_disco() {
  df --output=pcent / | tail -1 | tr -dc '0-9'
}

case "${QUERY_STRING:-}" in

  a=cpu)
    if corriendo; then
      responder '{"ok":false,"error":"Ya hay una prueba corriendo"}'
    else
      lanzar cpu stress-ng --cpu 0 --cpu-load 95 --timeout "${DURACION}s"
      responder '{"ok":true,"msg":"CPU al 95% durante 10 minutos"}'
    fi
    ;;

  a=ram)
    if corriendo; then
      responder '{"ok":false,"error":"Ya hay una prueba corriendo"}'
    else
      lanzar ram stress-ng --vm 1 --vm-bytes 92% --vm-keep --timeout "${DURACION}s"
      responder '{"ok":true,"msg":"RAM al 92% durante 10 minutos"}'
    fi
    ;;

  a=disco)
    if [ -f "$RELLENO" ]; then
      responder '{"ok":false,"error":"El relleno ya existe: usá Limpiar disco"}'
    else
      total=$(df -B1 --output=size / | tail -1 | tr -dc '0-9')
      usado=$(df -B1 --output=used / | tail -1 | tr -dc '0-9')
      falta=$(( total / 100 * OBJETIVO_DISCO - usado ))
      if [ "$falta" -le 0 ]; then
        responder '{"ok":false,"error":"El disco ya supera el 85%"}'
      elif fallocate -l "$falta" "$RELLENO" 2>/dev/null; then
        responder "{\"ok\":true,\"msg\":\"Disco llevado al ${OBJETIVO_DISCO}%\"}"
      else
        responder '{"ok":false,"error":"No se pudo reservar el espacio"}'
      fi
    fi
    ;;

  a=limpiar)
    rm -f "$RELLENO"
    responder '{"ok":true,"msg":"Relleno de disco borrado"}'
    ;;

  a=stop)
    pkill -u "$(id -u)" -x stress-ng 2>/dev/null
    rm -f "$ESTADO"
    responder '{"ok":true,"msg":"Pruebas detenidas"}'
    ;;

  a=estado)
    disco=$(uso_disco)
    if corriendo && [ -f "$ESTADO" ]; then
      read -r etiqueta inicio < "$ESTADO"
      responder "{\"ok\":true,\"corriendo\":true,\"prueba\":\"$etiqueta\",\"segundos\":$(( $(date +%s) - inicio )),\"disco\":$disco}"
    else
      responder "{\"ok\":true,\"corriendo\":false,\"disco\":$disco}"
    fi
    ;;

  *)
    responder '{"ok":false,"error":"Acción desconocida"}'
    ;;

esac
