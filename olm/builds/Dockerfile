FROM container-registry.oracle.com/olcne/ock:base-image

COPY rpms /tmp/

RUN dnf module enable nginx:1.24 \
    && dnf install -y /tmp/*.rpm nginx \
    && dnf clean all \
    && rm -rf /tmp/*.rpm /var/tmp/* /var/cache/dnf/*

COPY olm/scripts/prepare_plugin.sh .
RUN ./prepare_plugin.sh /opt/charts

COPY olm/scripts/nginx.conf /etc/nginx/nginx.conf

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]

