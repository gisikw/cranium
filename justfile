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

# Seed a handoff for a conversation from a file
seed-handoff conversation_id file:
    mix seed_handoff {{conversation_id}} {{file}}

# Delete all messages, epochs, and handoffs for a conversation
nuke-conversation conversation_id:
    psql -U postgres cranium_dev -c "DELETE FROM messages WHERE conversation_id = '{{conversation_id}}';"
    psql -U postgres cranium_dev -c "DELETE FROM epochs WHERE conversation_id = '{{conversation_id}}';"
    psql -U postgres cranium_dev -c "DELETE FROM handoffs WHERE conversation_id = '{{conversation_id}}';"
    psql -U postgres cranium_dev -c "DELETE FROM summaries WHERE conversation_id = '{{conversation_id}}';"

# Restart the cranium-v2 systemd service
restart:
    fort ratched systemd '{"unit":"cranium-v2","action":"restart"}'
