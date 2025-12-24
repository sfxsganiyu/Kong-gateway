FROM kong:3.3.1-alpine

USER root

# Copy custom plugin to Kong's plugin directory
COPY plugins/jti-blacklist-checker /usr/local/share/lua/5.1/kong/plugins/jti-blacklist-checker

# Install Lua dependencies manually (more reliable than LuaRocks)
RUN set -ex && \
    apk add --no-cache --virtual .fetch-deps wget unzip && \
    \
    # Install lua-resty-redis from GitHub
    echo "Installing lua-resty-redis..." && \
    cd /tmp && \
    wget -q https://github.com/openresty/lua-resty-redis/archive/refs/tags/v0.30.tar.gz && \
    tar -xzf v0.30.tar.gz && \
    mkdir -p /usr/local/share/lua/5.1/resty && \
    cp lua-resty-redis-0.30/lib/resty/redis.lua /usr/local/share/lua/5.1/resty/ && \
    \
    # Install pgmoon from GitHub
    echo "Installing pgmoon..." && \
    wget -q https://github.com/leafo/pgmoon/archive/refs/tags/v1.16.0.tar.gz && \
    tar -xzf v1.16.0.tar.gz && \
    mkdir -p /usr/local/share/lua/5.1/pgmoon && \
    cp -r pgmoon-1.16.0/pgmoon/* /usr/local/share/lua/5.1/pgmoon/ && \
    \
    # Verify installations
    echo "Verifying installations..." && \
    test -f /usr/local/share/lua/5.1/resty/redis.lua && \
    test -d /usr/local/share/lua/5.1/pgmoon && \
    echo "✓ Dependencies installed successfully" && \
    \
    # Cleanup
    cd / && \
    rm -rf /tmp/* && \
    apk del .fetch-deps && \
    rm -rf /var/cache/apk/*

# Set plugin environment variable
ENV KONG_PLUGINS=bundled,jti-blacklist-checker

# Switch back to kong user for security
USER kong

# Expose Kong ports
EXPOSE 8000 8001 8443 8444

# Graceful shutdown
STOPSIGNAL SIGQUIT

# Health check
HEALTHCHECK --interval=10s --timeout=10s --retries=10 CMD kong health

# Use Kong's docker-start command
CMD ["kong", "docker-start"]