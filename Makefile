VERSION=1.0.1.2

build:
	docker build --rm=true --tag=koreader/kosync:$(VERSION) .

push:
	docker tag koreader/kosync:$(VERSION) koreader/kosync:latest
	docker push koreader/kosync:$(VERSION)
	docker push koreader/kosync:latest
