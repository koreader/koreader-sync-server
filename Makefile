VERSION=2.0

BUILD_COMMAND ?= docker build --rm=true
BUILD_EXTRA_ARGS ?=

build:
	$(BUILD_COMMAND) --tag=koreader/kosync:$(VERSION) $(BUILD_EXTRA_ARGS) .
	docker tag koreader/kosync:$(VERSION) koreader/kosync:latest

push:
	docker push koreader/kosync:$(VERSION)
	docker push koreader/kosync:latest

.PHONY: test
test:
	docker run --rm koreader/kosync:$(VERSION) /app/koreader-sync-server/scripts/run_tests.sh

