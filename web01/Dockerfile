FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl fcgiwrap gnupg iproute2 nginx snmp snmpd stress-ng \
      supervisor wget \
 && wget -q -O /tmp/zabbix-release.deb \
      https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_7.0+ubuntu24.04_all.deb \
 && dpkg -i /tmp/zabbix-release.deb \
 && mkdir -p /etc/apt/keyrings \
 && wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor > /etc/apt/keyrings/grafana.gpg \
 && echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
      > /etc/apt/sources.list.d/grafana.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends zabbix-agent2 alloy \
 && usermod -aG adm zabbix \
 && usermod -aG adm alloy \
 && rm -rf /tmp/zabbix-release.deb /var/lib/apt/lists/* \
 && rm -f /etc/nginx/sites-enabled/default

COPY www/ /var/www/tienda/
COPY cgi-bin/carga.sh /usr/lib/cgi-bin/carga.sh
# Métricas del propio contenedor desde su cgroup (UserParameter contenedor[*]).
COPY zabbix/contenedor-metricas.sh /usr/local/bin/contenedor-metricas.sh
RUN chmod +x /usr/lib/cgi-bin/carga.sh /usr/local/bin/contenedor-metricas.sh

COPY nginx/logformat.conf /etc/nginx/conf.d/logformat.conf
COPY nginx/tienda.conf /etc/nginx/sites-enabled/tienda
COPY alloy/config.alloy /etc/alloy/config.alloy
COPY supervisord.conf /etc/supervisor/supervisord.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
