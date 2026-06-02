defmodule Exbitnode.MixProject do
  use Mix.Project

  def project do
    [
      app: :exbitnode,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :ssl],
      mod: {Exbitnode.Application, []}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"}
    ]
  end

  defp aliases do
    [
      status: ["run -e 'Exbitnode.CLI.NodeStatus.run([])'"],
      "node.status": ["run -e 'Exbitnode.CLI.NodeStatus.run([])'"],
      "sync.local": ["run -e 'Exbitnode.CLI.SyncLocal.run([])'"],
      "storage.proof": ["run -e 'Exbitnode.CLI.StorageProof.run([])'"]
    ]
  end
end
