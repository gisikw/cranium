# List available recipes
default:
    @just --list

# Run the test suite
test:
    mix test

# Build the project
build:
    mix compile --warnings-as-errors

# Start interactive shell
dev:
    iex -S mix

# Format code
fmt:
    mix format

# Check formatting without changing files
fmt-check:
    mix format --check-formatted

# Run all checks (format + compile warnings + tests)
check: fmt-check build test

# Setup project (deps + database)
setup:
    mix setup

# Reset database
db-reset:
    mix ecto.reset

# Create a database migration
migrate name:
    mix ecto.gen.migration {{name}}
