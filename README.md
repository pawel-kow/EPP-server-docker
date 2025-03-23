
## Generate certificate for apache
```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout ./etc/pki/tls/epp.localhost.key -out ./etc/pki/tls/epp.localhost.crt -subj "/C=DE/CN=epp.localhost"
```
