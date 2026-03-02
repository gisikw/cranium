# Cranium — Matrix-to-agent dispatcher

# List available recipes
default:
    @just --list

# Run the test suite
test:
    go test -tags goolm -v -count=1 ./...

# Build the main binary with version from git
build:
    go build -tags goolm -ldflags "-X main.version=$(git rev-parse --short HEAD)" -o cranium .

# Build companion CLI tools
build-tools:
    go build -o cmd/crn-post-image/crn-post-image ./cmd/crn-post-image/
    go build -o cmd/crn-post-audio/crn-post-audio ./cmd/crn-post-audio/
    go build -o cmd/crn-tts/crn-tts ./cmd/crn-tts/
    go build -o cmd/crn-breadcrumb/crn-breadcrumb ./cmd/crn-breadcrumb/

# Build everything
build-all: build build-tools

# Build + upgrade: drain, swap binary, restart
deploy: build
    ./scripts/upgrade.sh

# Generate a cross-room summary for a room
interview room *args='':
    ./scripts/interview-room.sh {{room}} {{args}}
