VERSION=1.0.1.2

build:
	docker build --rm=true --tag=koreader/kosync:$(VERSION) .
	docker tag koreader/kosync:$(VERSION) koreader/kosync:latest

push:
	docker push koreader/kosync:$(VERSION)
	docker push koreader/kosync:latest
