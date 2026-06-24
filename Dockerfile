## nginx on Ubuntu 24.04 (noble), installed from the official nginx.org apt repo.
## NGINX_VERSION is the upstream stable release; NGINX_DEB_REL/NJS_VERSION are
## the matching nginx.org package revisions for noble.
ARG NGINX_VERSION=1.30.3
ARG NGINX_DEB_REL=1~noble
ARG NJS_VERSION=1.30.3+1.0.0-1~noble

FROM ubuntu:24.04
## Redeclare build args for use inside this stage
ARG NGINX_VERSION
ARG NGINX_DEB_REL
ARG NJS_VERSION
USER root

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

## Install nginx plus the njs and perl dynamic modules from nginx.org, and gosu.
## The nginx-module-perl package installs nginx.pm into the system Perl path, so
## no manual Perl module wiring is required.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    nginx=${NGINX_VERSION}-${NGINX_DEB_REL} \
    nginx-module-njs=${NJS_VERSION} \
    nginx-module-perl=${NGINX_VERSION}-${NGINX_DEB_REL} \
    gosu && \
    rm -rf /var/lib/apt/lists/*

## Enable modules.
## Note: the perl module is commented out by default due to initialization issues.
## Uncomment the perl module line if you need to use perl directives in your config.
RUN { \
    echo "# load_module /usr/lib/nginx/modules/ngx_http_perl_module.so;"; \
    echo "load_module /usr/lib/nginx/modules/ngx_http_js_module.so;"; \
    echo ""; \
    cat /etc/nginx/nginx.conf; \
    } > /tmp/nginx.conf && \
    cp /tmp/nginx.conf /etc/nginx/nginx.conf

# Increase hash sizes to avoid warnings
# Add hash size directives at the beginning of the http block (before any includes)
RUN awk '/^http {/ { print; print "    variables_hash_max_size 2048;"; print "    variables_hash_bucket_size 128;"; print "    server_names_hash_max_size 2048;"; print "    server_names_hash_bucket_size 256;"; next }1' /etc/nginx/nginx.conf > /tmp/nginx.conf && \
    mv /tmp/nginx.conf /etc/nginx/nginx.conf

# Update nginx.conf to use /dev/stderr and /dev/stdout directly instead of log files
# This avoids permission issues with symlinks when running as non-root user
RUN sed -i 's|error_log.*/var/log/nginx/error.log.*|error_log /dev/stderr notice;|' /etc/nginx/nginx.conf && \
    sed -i 's|access_log.*/var/log/nginx/access.log.*|access_log /dev/stdout main;|' /etc/nginx/nginx.conf

# Fix log/cache directory permissions for the nginx user
RUN chown -R nginx:nginx /var/log/nginx /var/cache/nginx && \
    chmod -R 755 /var/log/nginx /var/cache/nginx

# Create entrypoint script to set up SSL symlink at runtime
# This allows configs to use /etc/ssl/nsgi/ while the actual mount is /etc/ssl/nginx/
# Run nginx as root - the 'user' directive in nginx.conf will drop privileges for workers
RUN echo '#!/bin/sh\n\
set -e\n\
# Ensure cache and run directories exist\n\
mkdir -p /var/cache/nginx /var/run\n\
# Create SSL symlink for compatibility with configs that reference /etc/ssl/nsgi/\n\
if [ -d /etc/ssl/nginx ] && [ ! -e /etc/ssl/nsgi ]; then\n\
    ln -sf /etc/ssl/nginx /etc/ssl/nsgi\n\
fi\n\
# Test nginx config\n\
nginx -t || exit 1\n\
# Run nginx (as root, but workers will run as user specified in nginx.conf)\n\
exec nginx -g "daemon off;"' > /docker-entrypoint.sh && \
    chmod +x /docker-entrypoint.sh

## Run as root - nginx.conf has 'user' directive to drop privileges for workers
USER root

ENTRYPOINT ["/docker-entrypoint.sh"]
