FROM kong

USER root

COPY plugins/jti-blacklist-checker /usr/local/share/lua/5.1/kong/plugins/jti-blacklist-checker

RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential git unzip wget && \
    luarocks install lua-resty-redis && \
    luarocks install pgmoon && \
    apt-get purge -y build-essential git unzip wget && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

ENV KONG_PLUGINS=bundled,jti-blacklist-checker

USER kong

EXPOSE 8000 8001 8443 8444

STOPSIGNAL SIGQUIT

HEALTHCHECK --interval=10s --timeout=10s --retries=10 CMD kong health

CMD ["kong", "docker-start"]

