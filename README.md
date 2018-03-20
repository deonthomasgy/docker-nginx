# NGINX from Ubuntu 16.04

Nginx-extras from Ubuntu 16.04

# Installation
The following command will pull the latest nginx build.
```sh
$ docker pull princeamd/nginx:latest
```
```sh
docker run --name thomas-nginx -v /etc/localtime:/etc/localtime:ro -d princeamd/nginx:latest
```
License
---
MIT
