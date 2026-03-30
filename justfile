# === Project: cranium-v2 ===
#
# Justfile conventions (see exocortex/scripts/justfile.template):
#
#   Universal:  develop, test, build, check, fmt, ship
#   Optional:   dev, clean
#
#   `ship` commits, pushes, and lets CI handle deployment.
#   `build` is the fast iterative check ("does the compiler love this?").
#   Deployment is a CI concern — see .forgejo/workflows/deploy.yml.

default:
    @just --list

# --- Environment ---

# Enter nix development shell
develop:
    nix develop

# --- Quality ---

# Run tests
test:
    mix local.hex --force --if-missing
    mix local.rebar --force --if-missing
    mix deps.get
    MIX_ENV=test mix test

# Format code
fmt:
    mix format

# Run dialyzer
dialyzer:
    mix dialyzer

# Run all quality checks (format + compile warnings + tests + dialyzer)
check: fmt build test dialyzer

# --- Build ---

# Build the project (iterative/dev build — "does the compiler love this?")
build:
    mix compile --warnings-as-errors

# --- Development ---

# Start interactive shell
dev:
    iex -S mix

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

# --- Shipping ---

# Commit and push. CI handles deployment.
ship message="ship":
    #!/usr/bin/env bash
    set -euo pipefail
    if ! git diff --quiet HEAD 2>/dev/null \
        || ! git diff --cached --quiet 2>/dev/null \
        || [ -n "$(git ls-files --others --exclude-standard)" ]; then
        git add -A
        git commit -m "{{message}}"
    fi
    git push
