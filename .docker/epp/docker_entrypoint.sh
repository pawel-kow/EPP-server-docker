#!/bin/bash

# Replace MySQL username and password in registry.conf
sed -i "s/<MYSQL_USER>/$MYSQL_USER/g" /etc/registry/registry.conf
sed -i "s/<MYSQL_PASSWORD>/$MYSQL_PASSWORD/g" /etc/registry/registry.conf
sed -i "s/<MYSQL_HOST>/${MYSQL_HOST:-mariadb}/g" /etc/registry/registry.conf
sed -i "s/<EPP_SERVER_REPOSITORY>/${EPP_SERVER_REPOSITORY:-NIC}/g" /etc/registry/registry.conf
sed -i "s/<EPP_SERVER_ID>/${EPP_SERVER_ID:-NIC Server}/g" /etc/registry/registry.conf

# Start Apache in the foreground
exec /usr/sbin/httpd -D FOREGROUND