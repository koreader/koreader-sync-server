FROM phusion/baseimage:jammy-1.0.4

# install system dependencies
RUN apt-get update \
    && apt-get install --no-install-recommends -y \
        libreadline-dev libncurses5-dev libpcre3-dev libssl-dev \
        build-essential git openssl \
        luarocks unzip redis-server \
        zlib1g-dev \
    && apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

ARG OPENRESTY_VER=1.27.1.2
ENV PATH=/opt/openresty/nginx/sbin:$PATH

WORKDIR /app
RUN wget "https://openresty.org/download/openresty-${OPENRESTY_VER}.tar.gz" \
        && tar zxvf openresty-${OPENRESTY_VER}.tar.gz \
        && cd openresty-${OPENRESTY_VER} \
            && ./configure --prefix=/opt/openresty \
            && make && make install \
        && cd .. \
            && rm -rf openresty-${OPENRESTY_VER} openresty-${OPENRESTY_VER}.tar.gz /tmp/*

RUN mkdir -p /etc/nginx/ssl \
    && openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /etc/nginx/ssl/nginx.key -out /etc/nginx/ssl/nginx.crt -subj "/"

# copy only the patch needed for the gin build step
COPY gin.patch /tmp/gin.patch

# patch gin for https support
RUN git clone https://github.com/ostinelli/gin \
    && cd gin \
    && patch -N -p1 < /tmp/gin.patch \
    && luarocks make --tree=/usr/local \
    && cd .. \
    && rm -rf gin

# install lua dependencies after gin to avoid gin's pinned old versions overwriting them
RUN luarocks remove --force luasocket 3.0rc1-2 \
    && luarocks install luasocket \
    && luarocks install luasec \
    && luarocks install redis-lua \
    && luarocks install busted \
    && rm -rf /tmp/*

# create daemons
RUN mkdir /etc/service/redis-server \
    && echo -n "#!/bin/sh\nexec redis-server /app/koreader-sync-server/config/redis.conf" > \
        /etc/service/redis-server/run \
    && chmod +x /etc/service/redis-server/run

ENV ENABLE_USER_REGISTRATION=true
ENV GIN_ENV=production

# append 'daemon off;' at runtime so tests can still use the config normally
RUN mkdir /etc/service/koreader-sync-server \
    && echo -n "#!/bin/sh\ngrep -q 'daemon off;' /app/koreader-sync-server/config/nginx.conf || echo 'daemon off;' >> /app/koreader-sync-server/config/nginx.conf\ncd /app/koreader-sync-server\nexec gin start" > \
        /etc/service/koreader-sync-server/run \
    && chmod +x /etc/service/koreader-sync-server/run

# add app source code last so app changes don't invalidate dependency layers
COPY ./ koreader-sync-server

VOLUME ["/var/log/redis", "/var/lib/redis"]

EXPOSE 7200

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD /app/koreader-sync-server/scripts/healthcheck.sh

CMD ["/sbin/my_init"]
