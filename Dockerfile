## nginx on Ubuntu 24.04 (noble), installed from the official nginx.org apt repo,
## plus ModSecurity v3 (built from source) and the OWASP Core Rule Set, ready to
## switch on per server. See README.md.
##
## NGINX_VERSION is the upstream stable release; NGINX_DEB_REL/NJS_VERSION are
## the matching nginx.org package revisions for noble. Every downloaded source
## is pinned by SHA-256 (matching the projects' published checksums; the nginx
## tarball was also checked against its PGP signature).
ARG NGINX_VERSION=1.30.5
ARG NGINX_DEB_REL=1~noble
ARG NJS_VERSION=1.30.5+1.0.1-1~noble
ARG NGINX_SRC_SHA256=6c20565aa2325cb82216ae804f4a4ff1875179014759a381c42ddc8e11c4906d
ARG MODSECURITY_VERSION=3.0.17
ARG MODSECURITY_SHA256=f283b33d5c21130fd3a15c84a93a1abe12bd1949edaf44288b12af571b671a50
ARG MODSECURITY_NGINX_VERSION=1.0.4
ARG MODSECURITY_NGINX_SHA256=6bdc7570911be884c1e43aaf85046137f9fde0cfa0dd4a55b853c81c45a13313
ARG CRS_VERSION=4.30.0
ARG CRS_SHA256=a4bb3688ef6205b64471a9ccbf0d7b024eb8edf39b97c6f6c0006e7a948f8550

## ---------------------------------------------------------------------------
## Build libmodsecurity, the nginx connector (a dynamic module for exactly this
## nginx version) and unpack the Core Rule Set.
FROM ubuntu:24.04 AS modsecurity
ARG NGINX_VERSION
ARG NGINX_SRC_SHA256
ARG MODSECURITY_VERSION
ARG MODSECURITY_SHA256
ARG MODSECURITY_NGINX_VERSION
ARG MODSECURITY_NGINX_SHA256
ARG CRS_VERSION
ARG CRS_SHA256

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl pkg-config \
    libpcre2-dev libxml2-dev libyajl-dev zlib1g-dev libssl-dev && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN curl -fsSL -o modsecurity.tar.gz \
      "https://github.com/owasp-modsecurity/ModSecurity/releases/download/v${MODSECURITY_VERSION}/modsecurity-v${MODSECURITY_VERSION}.tar.gz" && \
    echo "${MODSECURITY_SHA256}  modsecurity.tar.gz" | sha256sum -c - && \
    curl -fsSL -o connector.tar.gz \
      "https://github.com/owasp-modsecurity/ModSecurity-nginx/releases/download/v${MODSECURITY_NGINX_VERSION}/ModSecurity-nginx-v${MODSECURITY_NGINX_VERSION}.tar.gz" && \
    echo "${MODSECURITY_NGINX_SHA256}  connector.tar.gz" | sha256sum -c - && \
    curl -fsSL -o nginx.tar.gz "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" && \
    echo "${NGINX_SRC_SHA256}  nginx.tar.gz" | sha256sum -c - && \
    curl -fsSL -o crs.tar.gz "https://github.com/coreruleset/coreruleset/archive/refs/tags/v${CRS_VERSION}.tar.gz" && \
    echo "${CRS_SHA256}  crs.tar.gz" | sha256sum -c - && \
    tar xzf modsecurity.tar.gz && tar xzf connector.tar.gz && tar xzf nginx.tar.gz && tar xzf crs.tar.gz

## libmodsecurity with PCRE2, libxml2 (XML bodies) and YAJL (JSON bodies and
## the JSON audit log). Lua, GeoIP, LMDB, ssdeep and curl stay out: the Core
## Rule Set needs none of them.
RUN cd "modsecurity-v${MODSECURITY_VERSION}" && \
    ./configure --prefix=/usr/local/modsecurity --with-pcre2 --disable-examples \
      --without-lua --without-geoip --without-maxmind --without-lmdb --without-ssdeep --without-curl && \
    make -j"$(nproc)" && make install && \
    strip --strip-unneeded /usr/local/modsecurity/lib/libmodsecurity.so.3.*

## --with-compat builds a module that loads into the nginx.org binary of the
## same version.
RUN cd "nginx-${NGINX_VERSION}" && \
    MODSECURITY_INC=/usr/local/modsecurity/include MODSECURITY_LIB=/usr/local/modsecurity/lib \
    ./configure --with-compat --add-dynamic-module="../ModSecurity-nginx-v${MODSECURITY_NGINX_VERSION}" && \
    make modules && \
    cp objs/ngx_http_modsecurity_module.so /src/

## The Core Rule Set. crs-setup.conf is the project's example with our settings
## (modsec/crs-setup.local.conf) appended.
COPY modsec/crs-setup.local.conf /src/
RUN mkdir -p /out/modsec/crs && \
    cp "modsecurity-v${MODSECURITY_VERSION}/unicode.mapping" /out/modsec/ && \
    cp -r "coreruleset-${CRS_VERSION}/rules" /out/modsec/crs/ && \
    cat "coreruleset-${CRS_VERSION}/crs-setup.conf.example" crs-setup.local.conf > /out/modsec/crs/crs-setup.conf && \
    cp "coreruleset-${CRS_VERSION}/LICENSE" /out/modsec/crs/LICENSE && \
    rm -f /out/modsec/crs/rules/*.example

## ---------------------------------------------------------------------------
FROM ubuntu:24.04
## Redeclare build args for use inside this stage
ARG NGINX_VERSION
ARG NGINX_DEB_REL
ARG NJS_VERSION
ARG MODSECURITY_VERSION
ARG CRS_VERSION
USER root

LABEL org.opencontainers.image.title="nginx" \
      org.opencontainers.image.description="nginx ${NGINX_VERSION} (nginx.org, Ubuntu 24.04) with ModSecurity ${MODSECURITY_VERSION} and OWASP CRS ${CRS_VERSION}" \
      org.opencontainers.image.source="https://github.com/deonthomasgy/docker-nginx"

## Install prerequisites needed to add the nginx.org apt repository
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg && \
    rm -rf /var/lib/apt/lists/*

## Add the official nginx.org signing key and the stable Ubuntu (noble) repository
RUN curl -fsSL https://nginx.org/keys/nginx_signing.key | \
      gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/ubuntu noble nginx" \
      > /etc/apt/sources.list.d/nginx.list

## Install nginx plus the njs and perl dynamic modules from nginx.org, gosu, and
## the shared libraries libmodsecurity needs at run time.
## The nginx-module-perl package installs nginx.pm into the system Perl path, so
## no manual Perl module wiring is required.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    nginx=${NGINX_VERSION}-${NGINX_DEB_REL} \
    nginx-module-njs=${NJS_VERSION} \
    nginx-module-perl=${NGINX_VERSION}-${NGINX_DEB_REL} \
    gosu libpcre2-8-0 libxml2 libyajl2 zlib1g && \
    rm -rf /var/lib/apt/lists/*

## ModSecurity: the library, the nginx module and the rules. Nothing is loaded
## until a config adds load_module and "modsecurity on" (see README.md).
COPY --from=modsecurity /usr/local/modsecurity/lib/libmodsecurity.so.3* /usr/local/lib/
COPY --from=modsecurity /src/ngx_http_modsecurity_module.so /usr/lib/nginx/modules/
COPY --from=modsecurity /out/modsec /etc/nginx/modsec
COPY modsec/modsecurity.conf modsec/main.conf /etc/nginx/modsec/
## Our exceptions, loaded with the rules (crs/rules/*.conf, by name): REQUEST-900
## before them, RESPONSE-999 after.
COPY modsec/REQUEST-900-EXCLUSION-RULES-BEFORE-CRS.conf modsec/RESPONSE-999-EXCLUSION-RULES-AFTER-CRS.conf \
     /etc/nginx/modsec/crs/rules/
## The module must load and the rules parse: the entrypoint's nginx -t refuses
## to start the server otherwise.
RUN ldconfig && nginx -V 2>&1 | grep -q "nginx/${NGINX_VERSION}" && \
    printf '%s\n' 'load_module /usr/lib/nginx/modules/ngx_http_modsecurity_module.so;' 'pid /tmp/modsec-check.pid;' \
      'events {}' 'http { modsecurity_rules_file /etc/nginx/modsec/main.conf; }' > /tmp/modsec-check.conf && \
    nginx -e stderr -t -q -c /tmp/modsec-check.conf && rm -f /tmp/modsec-check.conf /tmp/modsec-check.pid

## Default configuration, used when nothing is mounted over it. The perl and
## ModSecurity modules are commented out there; uncomment to use them.
COPY nginx.conf /opt/bitnami/nginx/conf/nginx.conf

## Paths of the earlier Bitnami-based princeamd/nginx images, so configs and
## mounts written for them work unchanged: /opt/bitnami/nginx/conf (nginx.conf,
## server_blocks/, includes/, bitnami/*.conf), logs/ (access and error logs go
## to the container's stdout and stderr) and tmp/ (pid and temp files).
## /etc/nginx/nginx.conf is the same file, so plain `nginx -t` and
## `nginx -s reload` (deploy jobs, log-tracker-agent) act on the running config.
RUN mkdir -p /opt/bitnami/nginx/conf/server_blocks /opt/bitnami/nginx/conf/includes \
      /opt/bitnami/nginx/conf/bitnami /opt/bitnami/nginx/logs \
      /opt/bitnami/nginx/tmp/client_body /opt/bitnami/nginx/tmp/proxy /opt/bitnami/nginx/tmp/fastcgi \
      /opt/bitnami/nginx/tmp/scgi /opt/bitnami/nginx/tmp/uwsgi && \
    for f in mime.types fastcgi_params scgi_params uwsgi_params koi-utf koi-win win-utf; do \
      ln -s "/etc/nginx/$f" "/opt/bitnami/nginx/conf/$f"; \
    done && \
    printf '%s\n' '# Deny all attempts to access hidden files such as .htaccess or .htpasswd' \
      'location ~ /\. {' '    deny all;' '}' > /opt/bitnami/nginx/conf/bitnami/protect-hidden-files.conf && \
    ln -sf /dev/stdout /opt/bitnami/nginx/logs/access.log && \
    ln -sf /dev/stderr /opt/bitnami/nginx/logs/error.log && \
    ln -sf /opt/bitnami/nginx/conf/nginx.conf /etc/nginx/nginx.conf && \
    chown -R nginx:nginx /opt/bitnami/nginx/tmp /var/log/nginx /var/cache/nginx && \
    chmod -R 755 /var/log/nginx /var/cache/nginx

# Create entrypoint script to set up SSL symlink at runtime
# This allows configs to use /etc/ssl/nsgi/ while the actual mount is /etc/ssl/nginx/
# Run nginx as root - the 'user' directive in nginx.conf will drop privileges for workers
RUN echo '#!/bin/sh\n\
set -e\n\
# Ensure cache and run directories exist\n\
mkdir -p /var/cache/nginx /var/run /opt/bitnami/nginx/tmp\n\
# Create SSL symlink for compatibility with configs that reference /etc/ssl/nsgi/\n\
if [ -d /etc/ssl/nginx ] && [ ! -e /etc/ssl/nsgi ]; then\n\
    ln -sf /etc/ssl/nginx /etc/ssl/nsgi\n\
fi\n\
# Test nginx config\n\
nginx -t || exit 1\n\
# Run nginx (as root, but workers will run as user specified in nginx.conf)\n\
exec nginx -g "daemon off;"' > /docker-entrypoint.sh && \
    chmod +x /docker-entrypoint.sh

## Run as root - workers drop to the nginx user (the 'user' directive, or the
## nginx.org default "nginx" when a config has none)
USER root

## Graceful stop: finish in-flight requests
STOPSIGNAL SIGQUIT
ENTRYPOINT ["/docker-entrypoint.sh"]
