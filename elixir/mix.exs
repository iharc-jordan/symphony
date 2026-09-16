defmodule SymphonyElixir.MixProject do
  use Mix.Project

  def project do
    [
      app: :symphony_elixir,
      version: "0.4.0",
      elixir: "~> 1.19",
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      test_coverage: [
        summary: [
          threshold: 100
        ],
        ignore_modules: [
          SymphonyElixir.Asana.Client,
          SymphonyElixir.Config,
          SymphonyElixir.GitHub.Client,
          SymphonyElixir.GitLab.Client,
          SymphonyElixir.Jira.Client,
          SymphonyElixir.Linear.Client,
          SymphonyElixir.GitHubProjects.Client,
          # These process, filesystem, and native-Job integration boundaries
          # are covered by real crash, native, and packaged lifecycle checks.
          SymphonyElixir.Managed.Checkout,
          SymphonyElixir.Managed.Journal,
          SymphonyElixir.PathSafety,
          SymphonyElixir.RuntimeConfig,
          SymphonyElixir.WindowsWorkerHost,
          SymphonyElixir.SpecsCheck,
          SymphonyElixir.Orchestrator,
          SymphonyElixir.Orchestrator.State,
          SymphonyElixir.AgentRunner,
          SymphonyElixir.Application,
          SymphonyElixir.CLI,
          SymphonyElixir.Codex.AppServer,
          SymphonyElixir.Codex.DynamicTool,
          SymphonyElixir.HttpServer,
          SymphonyElixir.StatusDashboard,
          SymphonyElixir.LogFile,
          SymphonyElixir.Workspace,
          SymphonyElixirWeb.DashboardLive,
          SymphonyElixirWeb.Endpoint,
          SymphonyElixirWeb.ErrorHTML,
          SymphonyElixirWeb.ErrorJSON,
          SymphonyElixirWeb.Layouts,
          SymphonyElixirWeb.ObservabilityApiController,
          SymphonyElixirWeb.Presenter,
          SymphonyElixirWeb.StaticAssetController,
          SymphonyElixirWeb.StaticAssets,
          SymphonyElixirWeb.Router,
          SymphonyElixirWeb.Router.Helpers
        ]
      ],
      test_ignore_filters: [
        "test/support/snapshot_support.exs",
        "test/support/test_support.exs"
      ],
      dialyzer: [
        plt_add_apps: [:mix]
      ],
      escript: escript(),
      releases: releases(),
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {SymphonyElixir.Application, []},
      extra_applications: [:logger, :crypto]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:bandit, "~> 1.12"},
      {:floki, ">= 0.30.0", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix, "~> 1.8.13"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_view, "~> 1.1.33"},
      {:req, "~> 0.7.4"},
      {:jason, "~> 1.4.5"},
      {:yaml_elixir, "~> 2.12"},
      {:toml_elixir, "3.1.0"},
      {:solid, "~> 1.3"},
      {:ecto, "~> 3.14"},
      {:exqlite, "~> 0.40.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      build: ["escript.build"],
      lint: ["specs.check", "credo --strict"]
    ]
  end

  defp escript do
    [
      app: nil,
      main_module: SymphonyElixir.CLI,
      name: "symphony",
      path: "bin/symphony"
    ]
  end

  defp releases do
    [
      symphony: [
        include_erts: true,
        include_executables_for: [:windows],
        strip_beams: true
      ]
    ]
  end
end
