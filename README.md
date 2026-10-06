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
docker build --label org.opencontainers.image.revision="$(git rev-parse HEAD)" -t princeamd/nginx:1.30.5-1 .
docker tag princeamd/nginx:1.30.5-1 princeamd/nginx:latest
docker push princeamd/nginx:1.30.5-1 && docker push princeamd/nginx:latest
```

To update: bump `NGINX_VERSION`/`NJS_VERSION` (the nginx.org noble package
versions), `MODSECURITY_*` or `CRS_*`, and replace each `*_SHA256` with the
checksum the project publishes for the new release.

A build that keeps the versions but changes the image (rules, config) gets the
next suffix (`1.30.5-1`, then `-2`…), so a host can tell builds apart and go
back to the previous one; `1.30.5` is the build before the 2026-10-06 rule
changes. `docker run` only pulls an image the host lacks: on the proxy,
`docker pull` the new tag, set it as the default `IMAGE` in
`~/nginx-proxy/run-nginx.sh` and run that.

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
- File uploads up to 100 MB pass, and bigger bodies are inspected in part.
  Other bodies (JSON, forms) over 1 MiB fail to parse (rule 200002): logged
  while watching, refused with 400 once blocking is on.
- `main.conf` loads the engine settings and the Core Rule Set at paranoia level 1.
  For local settings and exceptions, copy it next to your config and add
  `Include` lines before and after the rules (see the proxy's
  `includes/modsec/main.conf`).
- `crs/crs-setup.conf` is the Core Rule Set's example with
  `modsec/crs-setup.local.conf` appended: the allowed methods are
  `GET HEAD POST OPTIONS PUT PATCH DELETE`, the writes of the REST APIs behind
  our proxy. Real methods outside the list (PROPFIND, MKCOL…) are still flagged
  (911100); nginx refuses TRACE and CONNECT itself.
- `crs/rules/REQUEST-900-EXCLUSION-RULES-BEFORE-CRS.conf` and
  `RESPONSE-999-EXCLUSION-RULES-AFTER-CRS.conf` (from `modsec/`) hold the
  exceptions for normal traffic of the platforms behind the proxy: on paths
  ending `/biometric/clock` the face photo (`face_image`, base64) leaves the
  rules' targets, and the MCP argument name
  `json.params._meta.claudecode/toolUseId` (it contains `.claude`) leaves rule
  930120. Any config that includes `crs/rules/*.conf` loads them, before and
  after the rules. Exceptions for one platform (its host, or a path on it) stay
  in that config.
- The build fails unless the module loads and the rules parse (`nginx -t`): the
  entrypoint runs the same test and refuses to start otherwise.

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

On the proxy, `~/nginx-proxy/run-nginx.sh` starts it. Roll back to the previous
build with `NGINX_IMAGE=princeamd/nginx:1.30.5 ./run-nginx.sh`, or to the image
without ModSecurity with `NGINX_IMAGE=princeamd/nginx:1.26-debian-12 ./run-nginx.sh`
after removing the ModSecurity `load_module` and `modsecurity` lines.

License
---
MIT. The Core Rule Set is Apache-2.0 (`/etc/nginx/modsec/crs/LICENSE`);
ModSecurity is Apache-2.0.
