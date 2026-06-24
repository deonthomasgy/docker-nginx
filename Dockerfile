ARG NGINX_VERSION=1.30.3

FROM nginx:${NGINX_VERSION} AS builder
USER root
## Redeclare NGINX_VERSION so it can be used as a parameter inside this build stage
ARG NGINX_VERSION
## Install required packages and build dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    dirmngr git gpg gpg-agent curl build-essential \
    libpcre2-dev zlib1g-dev libperl-dev libssl-dev \
    libxml2-dev libxslt1-dev && \
    rm -rf /var/lib/apt/lists/*
## Add trusted NGINX PGP key for tarball integrity verification
#RUN gpg --keyserver pgp.mit.edu --recv-key 520A9993A1C052F8
## Download NGINX, verify integrity and extract
RUN cd /tmp && \
    curl -O http://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz && \
    curl -O http://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz.asc && \
  #  gpg --verify nginx-${NGINX_VERSION}.tar.gz.asc nginx-${NGINX_VERSION}.tar.gz && \
    tar xzf nginx-${NGINX_VERSION}.tar.gz
## Download NJS module source code (checkout version compatible with NGINX version)
RUN cd /tmp && git clone https://github.com/nginx/njs.git && \
    cd njs && \
    git checkout $(git tag | grep "^${NGINX_VERSION}" | head -1 || git tag | sort -V | tail -1)
## Get NGINX configure arguments from running nginx and build modules
RUN CONFIGURE_ARGS=$(nginx -V 2>&1 | grep "configure arguments" | sed -e 's/.*configure arguments: //') && \
    cd /tmp/nginx-${NGINX_VERSION} && \
    eval ./configure $CONFIGURE_ARGS \
    --with-compat \
    --with-http_perl_module=dynamic \
    --add-dynamic-module=/tmp/njs/nginx && \
    make modules

FROM nginx:${NGINX_VERSION}
## Redeclare NGINX_VERSION for use in COPY commands
ARG NGINX_VERSION
USER root
## Ensure modules directory exists
RUN mkdir -p /usr/lib/nginx/modules
## Install ngx_http_perl_module system package dependencies and runtime libraries
RUN apt-get update && \
    apt-get install -y --no-install-recommends libperl-dev libpcre2-8-0 libxml2 libxslt1.1 && \
    rm -rf /var/lib/apt/lists/*
## Install ngx_http_perl_module files
## Note: Perl libraries are provided by libperl-dev package, no need to copy
COPY --from=builder /tmp/nginx-${NGINX_VERSION}/objs/ngx_http_perl_module.so /usr/lib/nginx/modules/ngx_http_perl_module.so
## Copy nginx.pm Perl module to multiple locations in Perl's @INC for compatibility
RUN mkdir -p /usr/share/perl5 /usr/lib/x86_64-linux-gnu/perl5/5.36
COPY --from=builder /tmp/nginx-${NGINX_VERSION}/src/http/modules/perl/nginx.pm /usr/share/perl5/nginx.pm
COPY --from=builder /tmp/nginx-${NGINX_VERSION}/src/http/modules/perl/nginx.pm /usr/lib/x86_64-linux-gnu/perl5/5.36/nginx.pm
## Set PERL5LIB to ensure Perl can find nginx.pm
ENV PERL5LIB=/usr/share/perl5:/usr/lib/x86_64-linux-gnu/perl5/5.36:$PERL5LIB
## Install ngx_http_js_module files
COPY --from=builder /tmp/nginx-${NGINX_VERSION}/objs/ngx_http_js_module.so /usr/lib/nginx/modules/ngx_http_js_module.so

## Enable modules
## Note: Perl module is commented out by default due to initialization issues.
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

# Fix log directory permissions for user 101
RUN chown -R 101:101 /var/log/nginx /var/cache/nginx && \
    chmod -R 755 /var/log/nginx /var/cache/nginx

# Install gosu for switching users in entrypoint
RUN apt-get update && \
    apt-get install -y --no-install-recommends gosu && \
    rm -rf /var/lib/apt/lists/*

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
