# Monica on Railway.
#
# The published image is complete; what it cannot do is the boot-time work a
# one-click deployment needs — provision its own scoped MySQL role, create the
# first account so registration can stay closed from the very first request,
# and normalise Apache for a platform that hands it a port at runtime. That is
# all this wrapper adds. The application itself is upstream's, untouched.
FROM monica:apache

COPY railway-entrypoint.sh apache-boot.sh provision-db.php /usr/local/bin/
COPY railway-hardening.conf /etc/apache2/conf-available/railway-hardening.conf

RUN set -ex; \
    chmod +x /usr/local/bin/railway-entrypoint.sh /usr/local/bin/apache-boot.sh; \
    a2enconf railway-hardening

ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
