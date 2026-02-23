# Callosum — Matrix-to-agent dispatcher

# List available recipes
default:
    @just --list

# Run the test suite
test:
    go test -tags goolm -v -count=1 ./...

# Build the binary with version from git
build:
    go build -tags goolm -ldflags "-X main.version=$(git rev-parse --short HEAD)" -o callosum .

# Build + upgrade: drain, swap binary, restart
deploy:
    @echo "TODO: upgrade script not yet wired"
