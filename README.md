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

The version comes from the `Accept` header.
`application/vnd.koreader.v1+json` is unchanged and is what every released
KOReader sends. `application/vnd.koreader.v2+json` serves the same endpoints and
additionally accepts several identifiers for one document, so a renamed or
recompressed copy can still find its reading position.

Identifiers are `{ "type", "value" }` pairs in the client's order of preference,
and the first must equal `document`. A type is an opaque label: the server stores
and echoes it without interpreting it, so new identifiers need no server change.

```bash
# write
curl -X PUT .../syncs/progress -H "Accept: application/vnd.koreader.v2+json" \
    -d '{"document":"<content>",
         "identifiers":[{"type":"content","value":"<content>"},
                        {"type":"structure","value":"<structure>"}],
         "percentage":0.42,"progress":"<xpointer>","device":"my kpw"}'

# read: a GET has no body, so the list is one ordered parameter
curl ".../syncs/progress/<content>?ids=content:<d>,structure:<d>"
```

The response adds two fields. `match` is the identifier type that resolved the
lookup. `progress_match` is the strongest identifier shared with whoever wrote
the current `progress` string, and is the one that says whether an xpointer can
be followed. The server reports both and acts on neither.

Identifiers other than the record's own become aliases, per account, removed
with the account. An alias is only created, never repointed, and never shadows
an existing document, so a weak identifier can fail to match but cannot move a
position onto the wrong record. At most 8 per request.

The server still sees only digests: no title, no author, no filename.

In addition, all data transferred between koreader devices and the sync server
are secured by HTTPS (Hypertext Transfer Protocol Secure) connections.

[licence-badge]:http://img.shields.io/badge/licence-AGPL-brightgreen.svg
[dockerfile]:https://github.com/koreader/koreader-sync-server/blob/master/Dockerfile
