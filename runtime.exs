import Config

# runtime.exs is executed at boot time inside the release, after compilation.
# All secrets must arrive as environment variables — nothing is baked into the image.

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "DATABASE_URL environment variable is missing."

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE environment variable is missing."

  config :demo, Demo.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    ssl: System.get_env("DATABASE_SSL", "true") == "true",
    socket_options: []

  # PHX_HOST is required for WebSocket URL generation — must match the Ingress host.
  host = System.get_env("PHX_HOST") || raise "PHX_HOST environment variable is missing."

  config :demo, DemoWeb.Endpoint,
    # server: true is required to start the HTTP server inside an OTP release.
    server: true,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: String.to_integer(System.get_env("PORT") || "4000"),
      # Ranch/Cowboy drain timeout: wait up to 60 s for existing connections to
      # finish before the listener terminates. Pairs with terminationGracePeriodSeconds
      # and the preStop sleep in the Deployment manifest.
      transport_options: [
        shutdown_timeout: 60_000
      ]
    ],
    secret_key_base: secret_key_base
end
