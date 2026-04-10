SHELL := /usr/bin/env bash

.PHONY: build clean

build:
	./scripts/build-android-arm64.sh

clean:
	rm -rf build dist
