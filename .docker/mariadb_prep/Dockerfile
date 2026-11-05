# Use the official Alpine Linux base image
FROM alpine:latest

# Update the package list and install the required packages
RUN apk update && apk add --no-cache openssl base64 bash

# Optional: Set a working directory
WORKDIR /install

# Database schema from the epp-server submodule
COPY ./epp-server/sql/registry.sql /install/registry.sql

# Start Apache in the foreground
COPY ./.docker/mariadb_prep/docker_entrypoint.sh /entrypoint.sh
COPY ./.docker/mariadb_prep/create_registrar.sql /install/create_registrar.sql
RUN chmod +x /entrypoint.sh
CMD ["/entrypoint.sh"]