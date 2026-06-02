defmodule Exbitnode.Db.Database do
  @moduledoc false

  alias Exbitnode.Db.{Schema, Sql}
  alias Exqlite.Sqlite3

  def open(path) do
    File.mkdir_p!(Path.dirname(path))

    {:ok, conn} = Sqlite3.open(path)
    :ok = Sqlite3.execute(conn, Schema.init_schema_sql())
    migrate_schema(conn)

    Sql.exec!(
      conn,
      "INSERT OR IGNORE INTO meta(key, value) VALUES('schema_version', ?1), ('node_version', ?2)",
      [Integer.to_string(Schema.schema_version()), Schema.node_version()]
    )

    {:ok, conn}
  end

  def close(conn) do
    Sqlite3.close(conn)
  end

  defp migrate_schema(conn) do
    migrate_utxo_undo_utxo_height(conn)
  end

  defp migrate_utxo_undo_utxo_height(conn) do
    columns =
      case Sql.query_all(conn, "PRAGMA table_info(utxo_undo)", []) do
        rows when is_list(rows) -> Enum.map(rows, fn [_cid, name | _] -> name end)
        _ -> []
      end

    unless "utxo_height" in columns do
      Sql.exec!(conn, "ALTER TABLE utxo_undo ADD COLUMN utxo_height INTEGER NOT NULL DEFAULT 0")
    end
  end
end
