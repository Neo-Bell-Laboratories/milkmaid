.PHONY: all build run clean

all: build

build:
	./scripts/build-app.sh

run: build
	open ./build/milkmaid.app

clean:
	rm -rf ./build/milkmaid.app
