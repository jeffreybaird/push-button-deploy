# Acceptance tests must use test-only dependencies and configuration.
unless Mix.env() == :test do
  raise "Run acceptance tests in MIX_ENV=test"
end
