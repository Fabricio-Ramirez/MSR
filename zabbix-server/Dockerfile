FROM zabbix/zabbix-server-pgsql:alpine-7.0-latest

USER root
RUN apk add --no-cache curl net-snmp-tools su-exec tini
COPY arranque.sh /usr/local/bin/arranque.sh
RUN chmod +x /usr/local/bin/arranque.sh

# La imagen base arranca como root; arranque.sh baja privilegios al usuario zabbix.
ENTRYPOINT ["/usr/local/bin/arranque.sh"]
CMD ["/usr/sbin/zabbix_server", "--foreground", "-c", "/etc/zabbix/zabbix_server.conf"]
