# princeamd/nginx

nginx from the official nginx.org packages on Ubuntu 24.04, with the njs and
perl modules, plus **ModSecurity v3** and the **OWASP Core Rule Set** ready to
switch on. This image runs our proxy (`thomas-nginx` on mintage-nginx-proxy-1).

| Component | Version |
|---|---|
| nginx (nginx.org) | 1.30.5 |
| ModSecurity (libmodsecurity, built from source) | 3.0.17 |
| ModSecurity-nginx connector (dynamic module) | 1.0.4 |
| OWASP Core Rule Set | 4.30.0 |

Versions and SHA-256 checksums of every download are pinned as `ARG`s at the top
of the `Dockerfile`.

## Build and publish

```sh
docker build -t princeamd/nginx:1.30.5 .
docker tag princeamd/nginx:1.30.5 princeamd/nginx:latest
docker push princeamd/nginx:1.30.5 && docker push princeamd/nginx:latest
```

To update: bump `NGINX_VERSION`/`NJS_VERSION` (the nginx.org noble package
versions), `MODSECURITY_*` or `CRS_*`, and replace each `*_SHA256` with the
checksum the project publishes for the new release.

## Paths

The image keeps the paths of the earlier Bitnami-based `princeamd/nginx:*-debian-*`
images, so configs and mounts written for them work unchanged:

| Path | What |
|---|---|
| `/opt/bitnami/nginx/conf/nginx.conf` | main config (`/etc/nginx/nginx.conf` is the same file, so `nginx -t` and `nginx -s reload` need no `-c`) |
| `/opt/bitnami/nginx/conf/server_blocks/`, `includes/`, `bitnami/` | the usual mount points |
| `/opt/bitnami/nginx/logs/access.log`, `error.log` | the container's stdout and stderr |
| `/opt/bitnami/nginx/tmp/` | pid and temp files |
| `/etc/nginx/modsec/` | ModSecurity engine settings, `main.conf`, and the Core Rule Set |

The master process runs as root and the workers as `nginx`. `/etc/ssl/nginx` is
linked to `/etc/ssl/nsgi` when only the former is mounted.

## Web application firewall

Nothing is loaded until a config asks for it. To inspect a server's requests:

```nginx
load_module /usr/lib/nginx/modules/ngx_http_modsecurity_module.so;   # top of nginx.conf

http {
    modsecurity_rules_file /etc/nginx/modsec/main.conf;   # load the rules once, at http level
    server {
        modsecurity on;                                    # in each server to protect
    }
}
```

- `modsecurity.conf` starts in **DetectionOnly**: rules run and flagged requests
  are logged, nothing is blocked. Override with `SecRuleEngine On` after tuning.
- Flagged requests are written as one JSON audit record per request to stdout
  (`{"transaction": …}`), with the client, request line, status and rule
  messages only. Request and response headers and bodies (cookies, tokens, user
  data) are never logged.
- Request bodies up to 100 MB pass; bodies past the inspection limits are
  inspected in part, never rejected for their size.
- `main.conf` loads the engine settings and the Core Rule Set at paranoia level 1.
  For local settings and exceptions, copy it next to your config and add
  `Include` lines before and after the rules (see the proxy's
  `includes/modsec/main.conf`).

Load the rules once at `http` level: a `modsecurity_rules_file` in every
`server` block parses the Core Rule Set once per server.

## Run

```sh
docker run --name thomas-nginx -p 443:443 \
  -v /etc/localtime:/etc/localtime:ro \
  -v "$PWD/nginx.conf:/opt/bitnami/nginx/conf/nginx.conf:ro" \
  -v "$PWD/server_blocks:/opt/bitnami/nginx/conf/server_blocks:ro" \
  -d princeamd/nginx:latest
```

On the proxy, `~/nginx-proxy/run-nginx.sh` starts it. Roll back with
`NGINX_IMAGE=princeamd/nginx:1.26-debian-12 ./run-nginx.sh`, after removing the
ModSecurity `load_module` and `modsecurity` lines (the old image has no such module).

License
---
MIT. The Core Rule Set is Apache-2.0 (`/etc/nginx/modsec/crs/LICENSE`);
ModSecurity is Apache-2.0.
