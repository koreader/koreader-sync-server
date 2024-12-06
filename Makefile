VERSION=2.0

build:
	docker build --rm=true --tag=koreader/kosync:$(VERSION) .
	docker tag koreader/kosync:$(VERSION) koreader/kosync:latest

push:
	docker push koreader/kosync:$(VERSION)
	docker push koreader/kosync:latest
