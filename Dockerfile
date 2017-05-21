FROM phusion/baseimage:latest

RUN apt-get update

# install openresty
RUN apt-get install -y libreadline-dev libncurses5-dev libpcre3-dev libssl-dev \
        build-essential git openssl \
        luarocks redis-server

ARG OPENRESTY_VER=1.7.10.1

WORKDIR /app
RUN wget "http://openresty.org/download/ngx_openresty-${OPENRESTY_VER}.tar.gz"
RUN tar zxvf ngx_openresty-${OPENRESTY_VER}.tar.gz
RUN cd ngx_openresty-${OPENRESTY_VER} && ./configure --prefix=/opt/openresty \
                            && make && make install
ENV PATH /opt/openresty/nginx/sbin:$PATH
RUN mkdir -p /etc/nginx/ssl
RUN openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/nginx/ssl/nginx.key -out /etc/nginx/ssl/nginx.crt -subj "/"
RUN rm -rf ngx_openresty-${OPENRESTY_VER}.tar.gz ngx_openresty-${OPENRESTY_VER}

# add source code
ADD ./ koreader-sync-server

# libssl.* are in /usr/lib/x86_64-linux-gnu on Travis Ubuntu precise
RUN luarocks install luasec OPENSSL_LIBDIR=/usr/lib/x86_64-linux-gnu
RUN git clone https://github.com/ostinelli/gin
# patch gin for https support
RUN cd gin && patch -N -p1 < ../koreader-sync-server/gin.patch
RUN cd gin && luarocks make
RUN luarocks install redis-lua
RUN luarocks install busted
RUN rm -rf gin

# create daemons
RUN mkdir /etc/service/redis-server
RUN echo -n "#!/bin/sh\nexec redis-server" > \
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


# Clean up APT when done.
RUN apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

CMD ["/sbin/my_init"]
EXPOSE 7200
