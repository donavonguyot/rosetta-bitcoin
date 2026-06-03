defmodule Exbitnode.MixProject do
  use Mix.Project

  def project do
    [
      app: :exbitnode,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      compilers: [:nif] ++ Mix.compilers(),
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
      status: ["run -e 'System.halt(Exbitnode.CLI.NodeStatus.run([]))'"],
      "node.status": ["run -e 'System.halt(Exbitnode.CLI.NodeStatus.run([]))'"],
      "sync.local": ["run -e 'Exbitnode.CLI.SyncLocal.run([])'"],
      "storage.proof": ["run -e 'System.halt(Exbitnode.CLI.StorageProof.run([]))'"],
      "script.corpus": ["run -e 'System.halt(Exbitnode.CLI.ScriptCorpus.run(System.argv()))'"]
    ]
  end
end

defmodule Mix.Tasks.Compile.Nif do
  use Mix.Task.Compiler

  @recursive true

  @impl true
  def run(_args) do
    {output, status} = System.cmd("make", ["-C", "c_src"], stderr_to_stdout: true)
    IO.write(output)

    if status == 0 do
      {:ok, []}
    else
      {:error, []}
    end
  end
end
