FROM phusion/baseimage:0.9.22

# install openresty
RUN apt-get update \
    && apt-get install --no-install-recommends -y \
        libreadline-dev libncurses5-dev libpcre3-dev libssl-dev \
        build-essential git openssl \
        luarocks unzip redis-server \
    && apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

ARG OPENRESTY_VER=1.7.10.1
ENV PATH /opt/openresty/nginx/sbin:$PATH

WORKDIR /app
RUN wget "http://openresty.org/download/ngx_openresty-${OPENRESTY_VER}.tar.gz" \
        && tar zxvf ngx_openresty-${OPENRESTY_VER}.tar.gz \
        && cd ngx_openresty-${OPENRESTY_VER} \
            && ./configure --prefix=/opt/openresty \
            && make && make install \
        && cd .. \
            && rm -rf ngx_openresty-${OPENRESTY_VER} ngx_openresty-${OPENRESTY_VER}.tar.gz /tmp/*

RUN mkdir -p /etc/nginx/ssl
RUN openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/nginx/ssl/nginx.key -out /etc/nginx/ssl/nginx.crt -subj "/"

# libssl.* are in /usr/lib/x86_64-linux-gnu on Travis Ubuntu precise
RUN luarocks install --verbose luasocket \
    && luarocks install luasec OPENSSL_LIBDIR=/usr/lib/x86_64-linux-gnu \
    && luarocks install redis-lua \
    && luarocks install busted \
    && rm -rf /tmp/*

# add app source code
COPY ./ koreader-sync-server

# patch gin for https support
RUN git clone https://github.com/ostinelli/gin \
    && cd gin && patch -N -p1 < ../koreader-sync-server/gin.patch \
    && luarocks make \
    && rm -rf gin /tmp/*

# create daemons
RUN mkdir /etc/service/redis-server
RUN echo -n "#!/bin/sh\nexec redis-server /app/koreader-sync-server/config/redis.conf" > \
        /etc/service/redis-server/run
RUN chmod +x /etc/service/redis-server/run


# run gin in production mode
ENV GIN_ENV production
# run gin in foreground
RUN echo "daemon off;" >> koreader-sync-server/config/nginx.conf
RUN mkdir /etc/service/koreader-sync-server
RUN echo -n "#!/bin/sh\ncd /app/koreader-sync-server\nexec gin start" > \
        /etc/service/koreader-sync-server/run
RUN chmod +x /etc/service/koreader-sync-server/run

VOLUME ["/var/log/redis", "/var/lib/redis"]

CMD ["/sbin/my_init"]
EXPOSE 7200
