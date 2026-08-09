# Chat with the bot in your terminal against the bundled sample knowledge
# base (a duck's personal notes). Requires only ANTHROPIC_API_KEY.
demo:
    @test -n "${ANTHROPIC_API_KEY:-}" || { echo "Set ANTHROPIC_API_KEY first"; exit 1; }
    mix deps.get
    CONSOLE_MODE=true REPO_PATH=sample_kb AUTO_COMMIT=false LOCALE=en TIMEZONE=Etc/UTC mix run --no-halt

# Run the test suite
test:
    mix test

# Format + compile with warnings as errors + test (what CI runs)
check:
    mix format --check-formatted
    mix compile --warnings-as-errors
    mix test
