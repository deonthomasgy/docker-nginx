FROM ubuntu:18.04

MAINTAINER Deon Thomas "Deon.Thomas.GY@gmail.com"

RUN apt-get update && apt-get install -y nginx-extras \
    && ln -sf /dev/stdout /var/log/nginx/access.log \
    && ln -sf /dev/stderr /var/log/nginx/error.log 

COPY ./server_names_hash_bucket_size.conf /etc/nginx/conf.d/

CMD ["nginx", "-g", "daemon off;"]
