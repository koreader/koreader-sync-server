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

The protocol
------------

The API is described in the third-party [kosync-conformance](https://github.com/pid1/kosync-conformance),
together with a verifier that checks an implementation against it in one command.
The description is observational rather than normative: it documents what this
server does, and it notes where implementations in the wild disagree. The spec
text is CC0, so anything in it may be copied here or anywhere else without
attribution.

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
the [Dockerfile][dockerfile].

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

Deleting an account
===================

`DELETE /users/me` uses the `x-auth-user` and `x-auth-key` headers to delete an
account and all its reading progress. Success returns HTTP 200 with
`{"deleted":true}`. Invalid credentials return HTTP 401 (code 2001).

An absent account returns HTTP 404 (code 2006, `Account not found.`), after
removing any orphaned user data. This specific response confirms deletion after a
lost response; a generic 404 or 401 does not.

No deletion records are retained. Usernames can be registered again immediately
with empty progress. Use a different password when re-registering: a stale deletion
request cannot be distinguished from a new one if both credentials are reused.

Changing a password
===================

`PUT /users/password` uses the current `x-auth-user` and `x-auth-key` headers and a
JSON body of `{"password":"<replacement key>"}`. As with registration, supply a
nonempty client-derived key (KOReader uses the password's MD5 hash).

Success returns HTTP 200 with `{"updated":true}` and preserves reading progress.
Update the saved password on all connected readers. This requires the current key;
it does not provide forgotten-password recovery.

Incorrect credentials and stale retries return HTTP 401. If a response is lost,
confirm the replacement key with `GET /users/auth`. Invalid replacement values
return HTTP 403 (code 2003).

Matching a document across copies (API v2)
=========================================

The API version is chosen by the `Accept` header. `application/vnd.koreader.v1+json`
is unchanged and is what every released KOReader sends.
`application/vnd.koreader.v2+json` serves the same endpoints, and additionally lets
a client offer more than one identifier for a document so that a renamed,
recompressed or repackaged copy can still find its reading position.

A client sends its identifiers in its own order of preference. Each is an opaque
`{ "type": ..., "value": ... }` pair; the server never interprets a type, so the set
of usable identifiers can grow without any server change. The first entry must be
the `document`, i.e. the identifier the client would send if the server took only one.

```bash
curl -k -X PUT https://localhost:7200/syncs/progress \
    -H "Accept: application/vnd.koreader.v2+json" \
    -H "x-auth-user: user" -H "x-auth-key: <md5>" \
    -d '{"document":"<content digest>",
         "identifiers":[{"type":"content","value":"<content digest>"},
                        {"type":"structure","value":"<structure digest>"},
                        {"type":"metadata","value":"<metadata digest>"}],
         "percentage":0.42,"progress":"/body/DocFragment[20]/body/p[22]",
         "device":"my kpw"}'
```

On a read the same list is flattened into one `ids` query parameter, because a GET
has no body and the order matters:

```bash
curl -k -H "Accept: application/vnd.koreader.v2+json" \
    -H "x-auth-user: user" -H "x-auth-key: <md5>" \
    "https://localhost:7200/syncs/progress/<content digest>?ids=content:<d>,structure:<d>,metadata:<d>"
```

The response carries the version 1 fields plus two more:

* `match` — the identifier type that resolved the lookup, or `exact` when the
  request named no types and the digest it asked for is the one the record is
  stored under. `document` is the digest the record is stored under, which is not
  necessarily the one that was asked for.
* `progress_match` — the strongest identifier the reader has in common with the
  client that wrote the current `progress` string, in the reader's own order.
  `none` when they share nothing.

These are different questions and the second is the one that decides whether an
xpointer can be followed. A reader can match a record on its own content digest and
still be handed a position written by a different edition that reached the same
record through a weaker identifier; in that case `match` is `content` and
`progress_match` is `metadata`. The server does not act on either: it reports how
the match was made and the client decides whether to restore the position or to
seek by percentage.

Matching is per account. Identifiers other than the one a record is stored under
become aliases, `user:{user}:alias:{digest}` → `{type}:{canonical digest}`. An
alias is only ever created, never repointed, and never shadows a document that
exists in its own right, so a weak identifier can fail to match but cannot move a
reading position onto the wrong record. Deleting an account removes its aliases
with the rest of its data. At most 8 identifiers are accepted per request.

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

The v2 identifiers keep this property. They are digests computed on the device and
the server stores them exactly as it stores the document digest: it never receives
a title, an author or a filename, and it cannot tell a content digest from a
metadata digest, because the type is a label it stores and echoes without
interpreting.

In addition, all data transferred between koreader devices and the sync server
are secured by HTTPS (Hypertext Transfer Protocol Secure) connections.

[licence-badge]:http://img.shields.io/badge/licence-AGPL-brightgreen.svg
[dockerfile]:https://github.com/koreader/koreader-sync-server/blob/master/Dockerfile
