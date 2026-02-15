#!/bin/sh
curl -sf -k -H "Accept: application/vnd.koreader.v1+json" https://127.0.0.1:7200/healthcheck | grep -q '"state":"OK"'
