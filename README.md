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
========
Using docker, you can spin up your own server in two commands:

```bash
docker build --rm=true --tag=$USER/kosync .
docker run -d -p 7200:7200 --name=koreader-sync-server $USER/kosync:latest
```

The above command will build and spin up a docker container that runs the sync
server.

To setup the server manually, please refer to the commands used in
[Dockerfile][dockerfile] and [travis config file][travis-conf].

You can use the following command to verify that the sync server is ready to serve traffic:

```bash
curl -k -v -H "Accept: application/vnd.koreader.v1+json" https://localhost:7200/healthcheck
# should return {"state":"OK"}
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
