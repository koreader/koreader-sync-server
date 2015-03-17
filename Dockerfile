FROM phusion/baseimage:latest

RUN apt-get update

# install openresty
RUN apt-get install -y libreadline-dev libncurses5-dev libpcre3-dev libssl-dev \
        build-essential git openssl \
        luarocks redis-server

WORKDIR /app
RUN wget "http://openresty.org/download/ngx_openresty-1.7.10.1.tar.gz"
RUN tar zxvf ngx_openresty-1.7.10.1.tar.gz
RUN cd ngx_openresty-1.7.10.1 && ./configure --prefix=/opt/openresty \
                            && make && make install
ENV PATH /opt/openresty/nginx/sbin:$PATH
RUN mkdir -p /etc/nginx/ssl
RUN openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/nginx/ssl/nginx.key -out /etc/nginx/ssl/nginx.crt -subj "/"

# libssl.* are in /usr/lib/x86_64-linux-gnu on Travis Ubuntu precise
RUN luarocks install luasec OPENSSL_LIBDIR=/usr/lib/x86_64-linux-gnu
RUN git clone https://github.com/ostinelli/gin
# patch gin for https support
ADD gin.patch /app/gin.patch
RUN cd gin && patch -N -p1 < ../gin.patch
RUN cd gin && luarocks make
RUN luarocks install redis-lua
RUN luarocks install busted

# create daemons
RUN mkdir /etc/service/redis-server
RUN echo -n "#!/bin/sh\nexec redis-server" > \
        /etc/service/redis-server/run
RUN chmod +x /etc/service/redis-server/run


# run gin in production mode
ENV GIN_ENV production
RUN git clone https://github.com/koreader/koreader-sync-server.git
RUN mkdir /etc/service/koreader-sync-server
RUN echo -n "#!/bin/sh\ncd /app/koreader-sync-server\nexec gin start" > \
        /etc/service/koreader-sync-server/run
RUN chmod +x /etc/service/koreader-sync-server/run


# Clean up APT when done.
RUN apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

CMD ["/sbin/my_init"]
EXPOSE 7200
