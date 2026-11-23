# Configuración de Zabbix: monitoreo por contenedor y monitoreo del monitoreo

Esta carpeta tiene dos templates para importar y el paso a paso de lo que se configura
desde el frontend. Complementa la configuración base de `web01` (apartado 5 del
`README.md` principal): no la reemplaza.

| Archivo | Qué es |
|---|---|
| `template-contenedor-web01.yaml` | Template **Contenedor web01 (cgroup v2)**: CPU, RAM, E/S y disco del contenedor `web01`, no de la VM |
| `template-heartbeat-healthchecks.yaml` | Template **Heartbeat Healthchecks.io**: Zabbix avisa a un servicio externo que sigue vivo |

> Los dos YAML siguen el formato de exportación de Zabbix 7.0 y pasan un parser YAML,
> pero **no se probaron importándolos** al escribir este documento. Si la importación
> da un error, el mensaje dice qué campo rechaza.

Se importan en **Data collection › Templates › Import**, con las opciones por defecto.

## El problema que resuelve

Dentro de un contenedor, `/proc/stat` y `/proc/meminfo` no están aislados: muestran la VM
entera. El agente de `web01` usa esos archivos, así que los templates de Linux miden **la
VM y no el servidor web**. En `/` pasa lo mismo, porque es un `overlay` sobre el disco de la VM.
Una alerta de "CPU alta en web01" no decía qué contenedor consumía, y la prueba de disco
llenaba el disco donde están PostgreSQL y Zabbix.

Se ataca por cuatro lados, de lo más simple a lo más invasivo:

| Mecanismo | Dónde | Qué aporta |
|---|---|---|
| Métricas del **cgroup** de `web01` | `web01/zabbix/contenedor-metricas.sh` + UserParameter `contenedor[*]` | CPU y RAM del contenedor, sin tocar el socket de Docker |
| **Límites** de CPU y RAM | `compose.yaml` (`cpus`, `mem_limit`), valores en `.env` | Le dan al % un denominador; una prueba en `web01` ya no ahoga a Zabbix |
| **Disco propio** `/datos` | `scripts/disco-web01.sh` | La prueba de disco llena el disco de `web01`, no el de la VM |
| **Template Docker** desde `mon-agent` | contenedor `mon-agent` con el socket de Docker | Ve los siete contenedores y detecta si alguno se cae |

Los templates de Linux siguen vinculados a `web01` y **siguen midiendo la VM**. Eso no es
un error: ahora hay dos niveles, la VM y el servidor web, y se pueden comparar.

> **Cambio de comportamiento en las pruebas.** Con los límites, `pruebas.sh p1` y `p2`
> llevan a `web01` al tope **de su cuota**, no a la VM. Dispararán los triggers
> **"web01: CPU del contenedor alta"** y **"web01: memoria del contenedor alta"**. Los
> triggers de la VM ("High CPU utilization", "High memory utilization") **probablemente
> ya no** se disparen, porque la VM conserva el margen que se reservó para el resto del
> laboratorio. Las capturas del informe hechas antes de este cambio muestran los triggers
> de la VM: hay que repetirlas.
>
> Si querés volver a cargar la VM entera, subí `WEB01_CPUS` y `WEB01_MEM` en `.env` a lo
> que tenga la VM y hacé `docker compose up -d web01`.

## 1. Host `web01`: template del contenedor

1. Importar `template-contenedor-web01.yaml`.
2. **Data collection › Hosts › web01 › Templates**: agregar **Contenedor web01 (cgroup v2)**.
   Los templates que ya tenía (Linux, ICMP Ping, Nginx) quedan como están.
3. Las macros `{$VFS.FS.*}` del host **no cambian**: `{$VFS.FS.FSNAME.MATCHES}` sigue en
   `^/$` para el disco de la VM. `/datos` lo mide este template con ítems propios, así que no
   hace falta que lo descubra el de Linux.

Ítems que agrega (los umbrales están en macros `{$CONTENEDOR.*}`):

| Ítem | Clave | Trigger |
|---|---|---|
| CPU usada, % del límite | `contenedor[cpu.uso]` | > 90 % durante 5 min (Warning) |
| Memoria usada, % del límite | `contenedor[mem.pct]` | > 90 % durante 5 min (Average) |
| Procesos matados por OOM | `contenedor[mem.oom]` | cualquier aumento (High) |
| Disco `/datos`, % usado | `vfs.fs.size[/datos,pused]` | > 80 % Warning, > 90 % High |
| Límites, memoria en bytes, CPU frenada, E/S, procesos | `contenedor[...]` | — |

Prueba rápida desde la VM:

```bash
docker exec web01 zabbix_agent2 -t 'contenedor[cpu.uso]'
docker exec web01 zabbix_agent2 -t 'contenedor[mem.pct]'
docker exec web01 zabbix_agent2 -t 'vfs.fs.size[/datos,pused]'
```

**Dependencias** (pestaña *Dependencies* de cada trigger), siguiendo el criterio del informe:
los triggers del contenedor dependen del de ping de `web01`.

## 2. Host `mon-agent`: template Docker y PostgreSQL

1. **Data collection › Host groups › Create host group**: `Infraestructura de monitoreo`.
2. **Data collection › Hosts › Create host**:

| Campo | Valor |
|---|---|
| Host name | `mon-agent` (igual a `ZBX_HOSTNAME` de `compose.yaml`) |
| Visible name | `VM Docker (contenedores)` |
| Host groups | `Infraestructura de monitoreo` |
| Templates | `Docker by Zabbix agent 2`, `PostgreSQL by Zabbix agent 2` |
| Interfaz Agent | `192.168.56.25`, puerto `10050` |
| Encryption | Connections to host = PSK; from host = PSK; PSK identity = `PSK-mon-agent`; PSK = la que muestra `sh scripts/credenciales.sh` |

3. Macros del host (los valores los muestra `sh scripts/credenciales.sh`):

| Macro | Valor |
|---|---|
| `{$PG.CONNSTRING.AGENT2}` | `tcp://192.168.56.22:5432` |
| `{$PG.USER}` | `zbx_monitor` |
| `{$PG.PASSWORD}` | `PG_MONITOR_PASSWORD` de `.env`, como **Secret text** |
| `{$PG.DATABASE}` | `zabbix` |

El usuario `zbx_monitor` lo crea `scripts/iniciar.sh` con el rol `pg_monitor`, que lee
estadísticas sin acceso a los datos de Zabbix.

4. El descubrimiento de contenedores corre cada 15 minutos. Para no esperar, usá *Execute now*
   en **Discovery rules**. Aparecen ítems como `Container /web01: CPU percent usage`
   (Docker antepone `/` al nombre).

Triggers que aporta: *Docker: Service is down*, *Container {#NAME}: Container has been
stopped with error code*, *PostgreSQL: Service is down* (base inaccesible), conexiones cerca
del máximo, consultas lentas y deadlocks.

**Opcional, CPU por contenedor para todos:** el template Docker no trae umbrales de CPU.
Para tenerlos: *Full clone* del template como `Docker – Tienda` y, en su regla de
descubrimiento de contenedores, un *Trigger prototype*:

```
min(/Docker – Tienda/docker.container_stats.cpu_pct_usage["{#NAME}"],5m)>80
```

Después se vincula `Docker – Tienda` a `mon-agent` en lugar del original.
`cpu_pct_usage` es relativo a la VM, igual que `docker stats`.

### Riesgo del socket de Docker

Quien puede hablar con `/var/run/docker.sock` controla Docker entero: puede crear un
contenedor `--privileged` que monte `/` de la VM, leer `.env` y las PSK, o borrar volúmenes.
En la práctica **equivale a ser root en la VM**. El `:ro` del montaje **no lo limita**: solo
impide modificar el archivo del socket, no las llamadas a la API que pasan por él.

Mitigaciones aplicadas:
- El socket está en `mon-agent` y no en `web01`, que es el servidor expuesto y tiene un CGI.
- `mon-agent` no publica puertos.
- El agente solo acepta a `192.168.56.20` y con TLS-PSK.
- El agente 2 no permite `system.run`.
- El proceso corre como `zabbix`, al que solo se le suma el grupo del socket (`group_add` con `DOCKER_GID`).

Para endurecerlo más, quedan dos opciones:
- **Un proxy de socket que solo permita lecturas.** El plugin del agente se conecta por socket Unix, así que el proxy también tendría que exponer un socket Unix.
- **Docker en modo rootless.**

## 3. Host `Zabbix server`: salud y heartbeat

Zabbix crea este host con *Zabbix server health* y *Linux by Zabbix agent*. En este
proyecto no hay agente dentro de `zabbix-server`, por eso su ícono ZBX está en rojo.

1. **Templates**: *Unlink and clear* de `Linux by Zabbix agent`. Queda **Zabbix server
   health**, que usa ítems internos y no necesita agente. Se puede borrar la interfaz
   `127.0.0.1`.
2. **Host groups**: agregar `Infraestructura de monitoreo`.
3. **Triggers › Create trigger**, cola de ítems con umbrales para un laboratorio chico
   (el del template dispara recién con 100 ítems demorados):

| Name | Severity | Expression |
|---|---|---|
| Cola de Zabbix con ítems demorados | High | `min(/Zabbix server/zabbix[queue,10m],10m)>20` |
| Cola de Zabbix creciente | Warning | `avg(/Zabbix server/zabbix[queue],5m)>2*avg(/Zabbix server/zabbix[queue],5m:now-5m) and last(/Zabbix server/zabbix[queue])>10` |

4. **Heartbeat**:
   - En [healthchecks.io](https://healthchecks.io), plan gratuito: *Add Check* `zabbix-mon01`.
     - *Period* 1 minuto, *Grace* 3 minutos.
     - En *Integrations*, dejar el mail y sumar Telegram con el bot de Healthchecks. Así el aviso no depende del bot ni del servidor de Zabbix.
     - Copiar la **Ping URL**. Es un secreto: no va al repositorio ni a las capturas.
   - Importar `template-heartbeat-healthchecks.yaml` y vincularlo al host `Zabbix server`.
   - En **Macros** del host, `{$HC.PING.URL}` = la Ping URL, tipo **Secret text**.

El ítem es de tipo *HTTP agent*: lo ejecuta el propio servidor Zabbix. Si el servidor se
detiene, se traba esperando la base o la VM se apaga, los pings dejan de salir y
Healthchecks.io avisa a los ~4 minutos. Un `cron` con `curl` seguiría pingueando aunque
Zabbix no estuviera procesando nada.

## 4. Que las alertas nuevas lleguen a Telegram

La acción **Notificar problemas tienda** filtra por *Host group = Servidores web*:
los problemas de `mon-agent` y `Zabbix server` **no se notificarían**. En **Alerts ›
Actions › Trigger actions**, editarla:

- A: Host group equals `Servidores web`
- B: Host group equals `Infraestructura de monitoreo`
- C: Trigger severity is greater than or equals `Warning`
- *Type of calculation*: Custom expression `(A or B) and C`

## 5. Pruebas de las mejoras

| Prueba | Cómo | Qué se espera |
|---|---|---|
| CPU del contenedor | `scripts/pruebas.sh p1` | Trigger *web01: CPU del contenedor alta*; en `mon-agent`, solo sube `Container /web01` |
| RAM del contenedor | `scripts/pruebas.sh p2` | Trigger *web01: memoria del contenedor alta* |
| Disco de web01 | `scripts/pruebas.sh p3 85`, `p3 92`, `p3-limpiar` | Triggers de `/datos` Warning y High; el disco de la VM (`/`) no se mueve |
| Contenedor caído | `docker kill loki`, después `docker start loki` | *Container /loki: Container has been stopped with error code*. Con `docker stop` no dispara: sale con código 0 y el template lo toma como una parada normal |
| Base caída | `docker compose stop zabbix-db`, 5 min, `start` | Anotar lo que se observe. Si el servidor sigue procesando, dispara *PostgreSQL: Service is down*. Si queda trabado esperando la base, avisa Healthchecks.io |
| Zabbix caído | `docker compose stop zabbix-server`, 5 min, `start` | Healthchecks.io pasa a *Down* y avisa; al volver, *Up*. Zabbix no avisa nada: por eso hace falta el heartbeat |
| Cola | `docker stop web01` durante 12 min | *Cola de Zabbix con ítems demorados* |
