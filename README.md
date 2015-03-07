[![Build Status][travis-badge]][travis-link]
[![AGPL Licence][licence-badge]](COPYING)
Koreader Sync Server
========

Koreader sync server is built on top of the [Gin](http://gin.io) JSON-API
framework which runs on [OpenResty](http://openresty.org/) and is entirely
written in [Lua](http://www.lua.org/).

Users of koreader devices can register their devices to the synchronization
server and use the sync service to keep all reading progress synchronized between
devices.

This project is licenced under Affero GPL v3, see the [COPYING](COPYING) file.

Setup your own server
========

You may need to checkout the [travis config file][travis-conf] to setup up your
own sync server.

[travis-badge]:https://travis-ci.org/koreader/koreader-sync-server.svg?branch=master
[travis-link]:https://travis-ci.org/koreader/koreader-sync-server
[travis-conf]:https://github.com/koreader/koreader-sync-server/blob/master/.travis.yml
[licence-badge]:http://img.shields.io/badge/licence-AGPL-brightgreen.svg

