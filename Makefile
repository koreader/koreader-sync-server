VERSION=2.1
CONTAINER_NAME=kosync
HOST_PORT=7200

build:
	docker build --rm=true --tag=koreader/kosync:$(VERSION) .
	docker tag koreader/kosync:$(VERSION) koreader/kosync:latest

start: build
	mkdir -p logs/app logs/redis data/redis
	-docker rm -f $(CONTAINER_NAME)
	docker run -d -p $(HOST_PORT):7200 \
		-v $$(pwd)/logs/app:/app/koreader-sync-server/logs \
		-v $$(pwd)/logs/redis:/var/log/redis \
		-v $$(pwd)/data/redis:/var/lib/redis \
		--name=$(CONTAINER_NAME) koreader/kosync:$(VERSION)

stop:
	-docker rm -f $(CONTAINER_NAME)

push:
	docker push koreader/kosync:$(VERSION)
	docker push koreader/kosync:latest

.PHONY: build start stop push test
test:
	docker run --rm koreader/kosync:$(VERSION) /app/koreader-sync-server/scripts/run_tests.sh

