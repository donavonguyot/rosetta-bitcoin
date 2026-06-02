defmodule Exbitnode.Db.Sql do
  @moduledoc false

  alias Exqlite.Sqlite3

  def exec!(conn, sql, params \\ []) do
    {:ok, stmt} = Sqlite3.prepare(conn, sql)
    :ok = Sqlite3.bind(stmt, params)
    drain(conn, stmt)
    changes = Sqlite3.changes(conn)
    Sqlite3.release(conn, stmt)
    changes
  end

  def query_all(conn, sql, params \\ []) do
    {:ok, stmt} = Sqlite3.prepare(conn, sql)
    :ok = Sqlite3.bind(stmt, params)
    rows = collect_rows(conn, stmt, [])
    Sqlite3.release(conn, stmt)
    rows
  end

  defp collect_rows(conn, stmt, acc) do
    case Sqlite3.step(conn, stmt) do
      {:row, row} -> collect_rows(conn, stmt, [row | acc])
      :done -> Enum.reverse(acc)
      other -> raise "unexpected sqlite step: #{inspect(other)}"
    end
  end

  def query_one(conn, sql, params \\ []) do
    {:ok, stmt} = Sqlite3.prepare(conn, sql)
    :ok = Sqlite3.bind(stmt, params)

    result =
      case Sqlite3.step(conn, stmt) do
        {:row, row} -> row
        :done -> nil
        other -> raise "unexpected sqlite step: #{inspect(other)}"
      end

    Sqlite3.release(conn, stmt)
    result
  end

  defp drain(conn, stmt) do
    case Sqlite3.step(conn, stmt) do
      :done -> :ok
      {:row, _row} -> drain(conn, stmt)
      other -> raise "unexpected sqlite step: #{inspect(other)}"
    end
  end

  def with_transaction(conn, fun) when is_function(fun, 1) do
    exec!(conn, "BEGIN IMMEDIATE")

    try do
      result = fun.(conn)
      exec!(conn, "COMMIT")
      result
    rescue
      error ->
        exec!(conn, "ROLLBACK")
        reraise error, __STACKTRACE__
    end
  end
end
