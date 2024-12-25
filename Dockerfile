FROM bitnami/nginx:1.26-debian-12

MAINTAINER Deon Thomas "Deon.Thomas.GY@gmail.com"

### Change user to perform privileged actions
USER 0

### Install 'curl'
RUN install_packages curl

# Extend server_names_hash_bucket_size to 128;
RUN sed -i 's/server_tokens off;/&\n    server_names_hash_bucket_size 128;/' /opt/bitnami/nginx/conf/nginx.conf

EXPOSE 8080 8443

WORKDIR /app

### Revert to the original non-root user
USER 1001
ENTRYPOINT [ "/opt/bitnami/scripts/nginx/entrypoint.sh" ]
CMD [ "/opt/bitnami/scripts/nginx/run.sh" ]
