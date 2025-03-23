FROM fedora:26

# Install required packages
RUN dnf -y update && \
    dnf -y install bind bind-utils bind-sdb httpd httpd-devel mod_perl php php-mcrypt php-mbstring perl-CPAN lynx perl-ExtUtils-Embed perl-XML-LibXML perl-CGI perl-YAML wget apr-util-mysql mod_ssl openssl-devel redhat-rpm-config pbzip2 perl-Test-Pod perl-File-Type perl-HTML-Template perl-MIME-Lite perl-Net-DNS perl-Net-SSLeay perl-XML-LibXML perl-XML-Parser perl-XML-Writer perl-XML-XPath perl-Authen-SASL perl-XML-Writer-String perl-MIME-Base64 perl-Email-Valid perl-CGI-Session perl-DBD-mysql gcc net-tools git

# mariadb-client

# Install Perl modules from CPAN
RUN perl -MCPAN -e 'install Test' && \
    perl -MCPAN -e 'install Net::EPP' && \
    perl -MCPAN -e 'install Net::XWhois'

# Create EPP user and group
RUN groupadd -g 7000 -r epp && \
    useradd -c "EPP" -d "/var/www/cgi-bin/epp" -g 7000 -m -o -p "test" -r epp -u 7000 -s /bin/bash

WORKDIR /install

# download http://sourceforge.net/projects/aepps/ and install mod_epp
# mod_epp was developed by "Otmar Lendl"
RUN wget http://downloads.sourceforge.net/project/aepps/mod_epp/1.10/mod_epp-1.10.tar.gz && \
    tar -zxvf mod_epp-1.10.tar.gz && \
    cd mod_epp-1.10 && \
    apxs -c -i mod_epp.c && \
    cd /install

RUN wget http://downloads.sourceforge.net/project/modwhois/mod_whois/0.1/mod_whois-0.1.tar.gz && \
    tar -zxvf mod_whois-0.1.tar.gz && \
    cd mod_whois && \
    apxs -c -i mod_whois.c && \
    cd /install

RUN wget https://github.com/xpanel/epp/archive/refs/tags/v1.0.15.tar.gz && \
    tar -zxvf v1.0.15.tar.gz && cp -r ./epp-1.0.15/cgi-bin /var/www

#RUN openssl genrsa -out /etc/pki/tls/private/www.xpanel.com.key 2048 && \
#    openssl req -new -key /etc/pki/tls/private/www.xpanel.com.key -out /etc/pki/tls/private/www.xpanel.com.csr -subj "/C=DE/CN=www.xpanel.com"

#RUN openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /etc/pki/tls/certs/localhost.key -out /etc/pki/tls/certs/localhost.crt -subj "/CN=localhost"

RUN openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /etc/pki/tls/epp.localhost.key -out /etc/pki/tls/epp.localhost.crt -subj "/CN=epp.localhost"


# Configure Apache
RUN mkdir -p /etc/httpd/conf.d
COPY ./etc/httpd/conf.d/* /etc/httpd/conf.d
RUN rm /etc/httpd/conf.d/ssl.conf

# Set permissions for EPP CGI directory
RUN chmod -R 0755 /var/www/cgi-bin/epp

# Create necessary directories
RUN mkdir -p /etc/registry /usr/local/registry && cp ./epp-1.0.15/etc/registry/* /etc/registry
COPY ./etc/registry/* /etc/registry/

# Expose necessary ports
EXPOSE 43 80 443 700 743

# Start Apache in the foreground
COPY ./.docker/epp/docker_entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
CMD ["/entrypoint.sh"]