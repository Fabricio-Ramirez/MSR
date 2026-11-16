# Qué falta hacer a mano y qué capturar

Revisión completa de `Obligatorio_MSR_2026_Propuesta_Solucion_Reducida.docx` (714 párrafos,
11 recuadros `[EVIDENCIA]`) cruzada con lo que el proyecto `obligatorio-docker` ya
automatiza. Hecho el 4/11/2026.

**Cómo leer esto.** Lo que el despliegue deja hecho no necesita trabajo, pero **igual hay
que capturarlo**: la evidencia la pide la letra, no el script. Lo que cambia respecto de la
propuesta es porque este laboratorio usa contenedores y no tiene TLS.

## Direcciones, que es donde más se confunde

| Desde dónde | Qué dirección |
|---|---|
| Tu navegador en Windows | `http://localhost:8444` (tienda), `:8443` (Zabbix), `:3000` (Grafana) |
| Dentro de la VM y entre contenedores | `192.168.56.10` web01, `.20` server, `.21` frontend, `.22` base, `.23` Grafana, `.24` Loki |
| Por el host-only | `http://192.168.57.10` y `:8080`, `:3000` |
| Por las IP de la documentación, desde Windows | las mismas `192.168.56.x`, **después del paso 7** |

Las seis IP internas son fijas y están declaradas en `compose.yaml`; `verificar.sh` las
comprueba una por una contra esta tabla.

`192.168.56.0/24` vive dentro de la VM, así que **recién instalado no es alcanzable desde
Windows**. El paso 7 de `PUESTA-EN-MARCHA.md` lo arregla con dos piezas: dos reglas en la
cadena `DOCKER-USER` dentro de la VM (`sudo scripts/acceso-lan.sh`) y una ruta persistente
en Windows hacia `192.168.57.10` (`scripts/ruta-windows.ps1`). **Conviene hacerlo antes de
sacar las capturas**: así las pantallas muestran las direcciones que figuran en la
propuesta. Aunque no lo hagas, la fuente de datos de Grafana funciona igual, porque la
resuelve el backend de Grafana desde dentro de la red.

---

# Los 11 recuadros [EVIDENCIA]

## §4.1 — Sincronización horaria

> Salida de `chronyc tracking` en ambos equipos mostrando "Leap status: Normal".

**Estado: a verificar.** `chrony` está instalado y activo en la VM, pero en la última
revisión aparecía **sin fuente de referencia** (`Stratum 0`, `Reference ID 00000000`),
aunque el reloj coincidía con Windows al segundo. Si capturás eso, se ve mal.

```bash
chronyc tracking      # "Leap status: Normal" y un Stratum distinto de 0
chronyc sources -v    # tiene que listar al menos una fuente con ^*
```

**Adaptación:** no hay "ambos equipos". `chrony` corre solo en la VM y los contenedores
usan su reloj; se comprueba con `docker exec web01 date` y `docker exec zabbix-server date`.
Documentalo así, ya está anotado en las diferencias del README.

## §4.2 — Servidor web Nginx

> Navegador mostrando `https://192.168.56.10`, salida de `nginx -t`, `ss -tlnp` y `curl`.

**Estado: listo, falta capturar.** Tres cambios:

```bash
# Con el paso 7 hecho, el navegador abre http://192.168.56.10 igual que pide el recuadro.
# Sin el paso 7, va a http://localhost:8444 y hay que aclararlo en el pie de la captura.
docker exec web01 nginx -t
docker exec web01 ss -tlnp          # ojo: iproute2 está, ss también
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.56.10/
```

**Es `http://`, no `https://`.** Si el docente pregunta, la respuesta está en la tabla de
diferencias del README: la letra pide cifrar "siempre que sea posible" y el cifrado lo
aportan SNMPv3 authPriv y la TLS-PSK del agente.

Aprovechá la captura del navegador: ahora la tienda es un catálogo de verdad, no un `<h1>`.

## §4.3 — Zabbix funcionando

> "System information" con "Zabbix server is running: Yes" y versión 7.0.x.

**Estado: listo, falta capturar.** Verificado: la API responde **7.0.32**.
`http://localhost:8443` → Reports › System information.

## §4.4 — Agente con TLS-PSK

> Ícono ZBX en verde y pestaña Encryption configurada, **ocultando el valor de la PSK**.

**Estado: el agente está listo; el host hay que crearlo.** Verificado por API: con el host
creado, la interfaz de agente queda `available=1` y `system.cpu.util` recibe datos.

Datos para el alta: interfaz `192.168.56.10:10050`, identidad `PSK-web01`, valor con
`cat secrets/web01.psk`. **Tapá el valor en la captura.**

## §4.5 — SNMPv3 authPriv

> `snmpwalk` v3 exitoso y v2c fallido; `tcpdump -i any udp port 161 -A` mostrando que el
> payload v3 no es legible.

**Estado: funciona, pero la captura de tcpdump necesita un ajuste.** `verificar.sh` ya
prueba las dos mitades (v3 responde, v2c rechazado). El problema es que **saqué `tcpdump`
de los contenedores** en la limpieza, por innecesario.

La solución es mejor que la original: capturá **desde la VM, sobre el puente de Docker**,
que ve todo el tráfico entre contenedores. El puente tiene nombre fijo, `br-lab`, así que
el comando no cambia aunque recrees la red.

```bash
sudo apt install -y tcpdump
sudo tcpdump -i br-lab -n udp port 161 -A
```

Y en otra terminal, las dos pruebas (las claves salen de `.env`):

```bash
docker exec zabbix-server snmpget -v3 -l authPriv -u zbxv3 \
  -a SHA -A "$SNMP_AUTH" -x AES -X "$SNMP_PRIV" 192.168.56.10 1.3.6.1.2.1.1.3.0
docker exec zabbix-server snmpget -v2c -c public 192.168.56.10 1.3.6.1.2.1.1.3.0
```

En el `tcpdump` se ve que el v3 viaja ilegible y que el v2c ni siquiera obtiene respuesta,
porque el `snmpd.conf` que escribe el `entrypoint.sh` **no define ninguna comunidad**.

## §4.6 — Ítems, escenario web y triggers

> Latest data de web01 con todos los ítems recibiendo datos; lista de triggers; pestaña
> Dependencies de "Tienda online no disponible".

**Estado: todo manual. Es el bloque más largo.** Tres correcciones obligatorias:

1. **`vm.memory.utilization` no existe en Zabbix 7.0.** La clave real es **`vm.memory.util`**.
   Aparece mal en la Tabla 4 y en el trigger de RAM de la Tabla 5.
2. **Sacá el template "Website certificate by Zabbix agent 2"** y el "Adicional 4 –
   Certificado TLS" de la Tabla 4: sin HTTPS no hay certificado que vigilar. Te quedan
   igual 5 parámetros adicionales, muy por encima de los 2 que pide la letra.
3. **El escenario web va a `http://192.168.56.10/`** y ya no hay que desmarcar
   "SSL verify peer".

Templates a vincular: `Linux by Zabbix agent`, `ICMP Ping`, `Nginx by Zabbix agent`.

Macros del host:

| Macro | Valor | Para qué |
|---|---|---|
| `{$NGINX.STUB_STATUS.HOST}` | `127.0.0.1` | Ya configurado en `tienda.conf` |
| `{$NGINX.STUB_STATUS.PORT}` | `8080` | Ídem |
| `{$NGINX.STUB_STATUS.PATH}` | `basic_status` | Ídem |
| `{$VFS.FS.FSTYPE.MATCHES}` | el default **con `overlay` agregado** | Sin esto no se descubre `/` |
| `{$VFS.FS.FSNAME.MATCHES}` | `^/$` | Ídem |
| `{$CPU.UTIL.CRIT}` | `90` | Trigger de CPU |
| `{$MEMORY.UTIL.MAX}` | `90` | Trigger de RAM |
| `{$VFS.FS.PUSED.MAX.WARN}` / `.CRIT` | `80` / `90` | Triggers de disco |

Las dos macros de filesystem son el punto más fácil de olvidar: dentro del contenedor `/`
es de tipo `overlay`, que el template excluye, y sin el ajuste **la métrica de
almacenamiento queda vacía** y perdés un requisito de la letra. Ya está verificado que con
el ajuste aparece `vfs.fs.dependent.size[/,pused]`.

El escenario web: paso "Home", `http://192.168.56.10/`, código `200`, timeout 15 s, texto
requerido `Tienda online` — que sigue estando, en el `<title>` de la página.

Los ítems de log (`log[]` y `log.count[]`) son **checks activos**: dependen de que el
agente tenga `ServerActive` y de que el nombre del host en Zabbix sea exactamente `web01`.
Las dos cosas ya están así. La expresión regular de los 5xx de la propuesta funciona con
el `log_format timed` del proyecto.

**No te saltees las dependencias entre triggers.** Es lo que conecta el trabajo con la
metodología de troubleshooting de la unidad 2 y es material casi seguro de defensa.

## §4.7 — Logs

> Grafana › Explore con logs de Nginx filtrados; History del ítem `log[]` en Zabbix.

**Estado: la cadena está lista y verificada; faltan las fuentes de datos de Zabbix.**

La fuente **Loki ya está provisionada** y su health check da OK. Falta crear la de Zabbix:

| Campo | Valor |
|---|---|
| URL | `http://192.168.56.21:8080/api_jsonrpc.php` (la propuesta dice `https://192.168.56.20/`) |
| Autenticación | Token de API, en Users › API tokens |

Las consultas LogQL de la propuesta funcionan tal cual. Ya está verificado que un error
500 recién generado aparece consultando Loki; `verificar.sh` lo comprueba solo.

## §4.8 — Panel de alarmas

> Dashboard con al menos un problema activo y Problems › History después de las pruebas.

**Estado: todo manual.** Dashboard "NOC – Tienda online". Capturalo **después** de correr
las pruebas, cuando haya problemas resueltos en el histórico.

## §4.9 — Notificaciones

> Configuración de la acción; mensaje de problema y de recuperación en Telegram y correo;
> Reports › Action log.

**Estado: NO IMPLEMENTADO. Es lo más urgente.** La letra lo exige de forma explícita
("El sistema debe enviar notificaciones por algún medio frente a eventos anormales") y el
proyecto no configura ni Telegram ni SMTP. Lo único que hay es la comprobación de que
`zabbix-server` llega a `api.telegram.org`, que sí funciona.

Es todo frontend: Alerts › Media types, Users › Media, Alerts › Actions. Necesitás un bot
de @BotFather y su chat ID. **No pongas credenciales reales en la entrega.**

Hacelo **antes** de las pruebas de carga: la Tabla 7 pide la hora de la notificación de
cada prueba, así que sin esto hay que repetirlas.

## §5.3 — Pruebas de carga

> Por prueba: terminal + gráfica + problema + notificación + recuperación.

**Estado: los comandos están listos, la ejecución es manual.** Son 7 filas (P1, P2, P3, P4,
P5a, P5b, P6) × 5 evidencias = **35 capturas**. Es el bloque más caro en tiempo y vale 12
de los 40 puntos.

```bash
scripts/pruebas.sh p1          # CPU
scripts/pruebas.sh p2          # RAM
scripts/pruebas.sh p3 85       # después p3 92, y al final p3-limpiar
scripts/pruebas.sh p4          # carga HTTP
scripts/pruebas.sh p5a         # detiene Nginx; p5a-subir para restablecer
scripts/pruebas.sh p5b         # corta la red; p5b-subir para restablecer
scripts/pruebas.sh p6          # 50 errores 500
```

Cada prueba imprime hora de inicio y de fin, que es lo que va en la Tabla 7.

Tres adaptaciones ya documentadas en el README: P4 sale **de la VM** y no del host Windows,
P5a usa `supervisorctl` en vez de `systemctl`, y P5b baja `eth0` dentro de `web01` en vez
de desconectar la interfaz de la VM.

**Usá los scripts, no los botones de la página**, para los números de la tabla. Los botones
del panel oculto son para la defensa en vivo; la propuesta documenta los comandos.

Tomá primero los 15 minutos de línea base del §5.1: sin eso, no podés argumentar que los
valores durante la prueba son anómalos.

---

# Correcciones al documento antes de entregar

La implementación cambió y el `.docx` quedó desactualizado en cinco puntos:

| Dónde | Dice | Debe decir |
|---|---|---|
| Tabla 1, protocolos cifrados | "HTTPS en web, Zabbix, Grafana y Loki" | SNMPv3 authPriv y TLS-PSK del agente; el resto en HTTP |
| Tabla 1 y Tabla 4 | "Vencimiento del certificado TLS" como adicional | Eliminarlo; quedan 5 adicionales |
| Tabla 4, RAM | `vm.memory.utilization` | **`vm.memory.util`** |
| Tabla 5, trigger de RAM | `min(/web01/vm.memory.utilization,5m)` | `min(/web01/vm.memory.util,5m)` |
| §7.5 | "El escenario web falla con el certificado autofirmado" | Ya no puede pasar. Reemplazalo por un problema real: el README tiene 9 documentados |

La §7 pide **al menos 2 problemas que hayan enfrentado de verdad**. Los dos más sólidos
son los puntos **7 y 8** del README, encontrados el 16/11/2026 al reiniciar la VM:
`fcgiwrap` que queda FATAL porque en Docker `/run` no es `tmpfs` y le sobrevive el socket
viejo, y SNMPv3 que pasa a devolver `authorizationError` porque el `entrypoint.sh`
reescribía `snmpd.conf` y borraba la línea `rouser` que sólo se agregaba en el primer
arranque.

Los dos tienen causa raíz demostrable, síntoma reproducible con
`docker stop web01 && docker start web01`, y arreglo verificado. Y comparten una lección
que se defiende sola: **algo que funciona en el primer despliegue no está probado hasta que
sobrevive a un reinicio.** Como respaldo quedan el bucle de reinicios de `zabbix-server`
por el `tini` ausente y el descubrimiento de filesystems que no ve `/` por el tipo
`overlay`.

# Orden sugerido

1. **Levantar el stack**, correr `verificar.sh` (34 comprobaciones) y hacer el paso 7 de
   `PUESTA-EN-MARCHA.md`, para que las capturas muestren las IP de la documentación.
2. **Notificaciones (§4.9)** — primero, porque las pruebas las necesitan.
3. **Host, templates, macros, escenario web y triggers (§4.6)** con las dependencias.
4. **Fuente de datos Zabbix en Grafana (§4.7)** y el dashboard (§4.8).
5. **Línea base de 15 minutos.**
6. **Pruebas P1 a P6** con sus 35 capturas.
7. **Capturas de infraestructura (§4.1 a §4.5)**, que se pueden tomar en cualquier momento.
8. **Corregir el `.docx`** con la tabla de arriba.
