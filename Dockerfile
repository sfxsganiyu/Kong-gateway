FROM kong:3.9.1-ubuntu

USER root

# 1. Install system dependencies using apt-get (Ubuntu)
RUN apt-get update && apt-get install -y \
    wget \
    unzip \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# 2. Install lua-resty-redis
# We place it in /usr/local/share/lua/5.1/resty so it can be 'require "resty.redis"'
RUN echo "Installing lua-resty-redis..." && \
    mkdir -p /tmp/redis && cd /tmp/redis && \
    wget -q https://github.com/openresty/lua-resty-redis/archive/refs/tags/v0.30.tar.gz && \
    tar -xzf v0.30.tar.gz && \
    mkdir -p /usr/local/share/lua/5.1/resty && \
    cp lua-resty-redis-0.30/lib/resty/redis.lua /usr/local/share/lua/5.1/resty/ && \
    rm -rf /tmp/redis

# 3. Install pgmoon
# We place it in /usr/local/share/lua/5.1/pgmoon so it can be 'require "pgmoon"'
RUN echo "Installing pgmoon..." && \
    mkdir -p /tmp/pgmoon && cd /tmp/pgmoon && \
    wget -q https://github.com/leafo/pgmoon/archive/refs/tags/v1.16.0.tar.gz && \
    tar -xzf v1.16.0.tar.gz && \
    mkdir -p /usr/local/share/lua/5.1/pgmoon && \
    cp -r pgmoon-1.16.0/pgmoon/* /usr/local/share/lua/5.1/pgmoon/ && \
    rm -rf /tmp/pgmoon

# 4. Copy your custom plugin
# Ensure your local folder structure is plugins/jti-blacklist-checker/
COPY plugins/jti-blacklist-checker /usr/local/share/lua/5.1/kong/plugins/jti-blacklist-checker

# 5. Set Kong configuration
# KONG_PLUGINS tells Kong to load your custom plugin along with default ones
ENV KONG_PLUGINS=bundled,jti-blacklist-checker
# Optional: Set log level to notice to see your [JTI-LOG] prints
ENV KONG_LOG_LEVEL=notice

# Switch back to the non-root kong user
USER kong

# Standard Kong Ports
EXPOSE 8000 8443 8001 8444 8002 8445

STOPSIGNAL SIGQUIT

HEALTHCHECK --interval=10s --timeout=10s --retries=10 CMD kong health

CMD ["kong", "docker-start"]