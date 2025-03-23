# Use the official Alpine Linux base image
FROM alpine:latest

# Update the package list and install the required packages
RUN apk update && apk add --no-cache openssl wget tar base64 bash

# Optional: Set a working directory
WORKDIR /install

RUN wget https://github.com/xpanel/epp/archive/refs/tags/v1.0.15.tar.gz && \
    tar -zxvf v1.0.15.tar.gz

# Start Apache in the foreground
COPY ./docker_entrypoint.sh /entrypoint.sh
COPY ./create_registrar.sql /install/create_registrar.sql
RUN chmod +x /entrypoint.sh
CMD ["/entrypoint.sh"]