VERSION_TAG=$(shell git describe --tags --abbrev=0)
GIT_COMMIT=$(shell git rev-parse --short HEAD)

build:
	go build -o ./bin/envdiff -ldflags '-X main.version=$(VERSION_TAG) -X main.gitCommit=$(GIT_COMMIT)' . 
