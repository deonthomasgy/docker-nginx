FROM ubuntu:18.04

MAINTAINER Deon Thomas "Deon.Thomas.GY@gmail.com"

RUN apt-get update && apt-get install -y nginx-extras \
    && ln -sf /dev/stdout /var/log/nginx/access.log \
    && ln -sf /dev/stderr /var/log/nginx/error.log \

CMD ["nginx", "-g", "daemon off;"]
