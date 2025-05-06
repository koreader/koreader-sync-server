[![Build Status][travis-badge]][travis-link]
[![AGPL Licence][licence-badge]](COPYING)
Koreader Sync Server
========

Koreader sync server is built on top of the [Gin](http://gin.io) JSON-API
framework which runs on [OpenResty](http://openresty.org/) and is entirely
written in [Lua](http://www.lua.org/).

Users of koreader devices can register their devices to the synchronization
server and use the sync service to keep all reading progress synchronized
between devices.

This project is licenced under Affero GPL v3, see the [COPYING](COPYING) file.

Setup your own server
======================
Using docker, you can spin up your own server in two commands:

```bash
# for quick test
docker run -d -p 7200:7200 --name=kosync koreader/kosync:latest

# for production, we mount redis data volume to persist state
mkdir -p ./logs/{redis,app} ./data/redis
docker run -d -p 7200:7200 \
    -v `pwd`/logs/app:/app/koreader-sync-server/logs \
    -v `pwd`/logs/redis:/var/log/redis \
    -v `pwd`/data/redis:/var/lib/redis \
    --name=kosync koreader/kosync:latest
```

The above command will spin up a sync server in a docker container.

To build your own docker image from scratch:

```bash
docker build --rm=true --tag=koreader/kosync .
```

Alternatively, if you'd rather use docker compose:

```bash
docker compose up -d --build
```

To setup the server manually, please refer to the commands used in
[Dockerfile][dockerfile] and [travis config file][travis-conf].

You can use the following command to verify that the sync server is ready to serve traffic:

```bash
curl -k -v -H "Accept: application/vnd.koreader.v1+json" https://localhost:7200/healthcheck
# should return {"state":"OK"}
```

As you can see, the server responds over HTTPS using a self-signed certificate. If you'd like to run the server behind a reverse proxy and let the proxy handle TLS termination, run the server on port `17200` instead of `7200`. As an example, your Traefik V3 configuration could look like this:

```bash
  kosync:
    # ...
    labels:
      - traefik.enable=true
      - 'traefik.http.routers.kosync.rule=Host(`kosync.example.com`)'
      - 'traefik.http.services.kosync.loadbalancer.server.port=17200'
```

Privacy and security
========

Koreader sync server does not store file name or file content in the database.
For each user it uses a unique string of 32 digits (MD5 hash) to identify the
same document from multiple koreader devices and keeps a record of the furthest
reading progress for that document. Sample progress data entries stored in the
sync server are like these:
```
"user:chrox:document:0b229176d4e8db7f6d2b5a4952368d7a:percentage"  --> "0.31879884821061"
"user:chrox:document:0b229176d4e8db7f6d2b5a4952368d7a:progress"    --> "/body/DocFragment[20]/body/p[22]/img.0"
"user:chrox:document:0b229176d4e8db7f6d2b5a4952368d7a:device"      --> "PocketBook"
```
And the account authentication information is stored like this:
```
"user:chrox:key"  --> "1c56000eef209217ec0b50354558ab1a"
```
the password is MD5 hashed at client when authorizing with the sync server.

In addition, all data transferred between koreader devices and the sync server
are secured by HTTPS (Hypertext Transfer Protocol Secure) connections.

[travis-badge]:https://travis-ci.org/koreader/koreader-sync-server.svg?branch=master
[travis-link]:https://travis-ci.org/koreader/koreader-sync-server
[travis-conf]:https://github.com/koreader/koreader-sync-server/blob/master/.travis.yml
[licence-badge]:http://img.shields.io/badge/licence-AGPL-brightgreen.svg
[dockerfile]:https://github.com/koreader/koreader-sync-server/blob/master/Dockerfile
