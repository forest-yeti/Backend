defmodule BlockPoker.ArchitectureTest do
  @moduledoc """
  Границы слоёв (§3 CLAUDE.md) проверяются автотестом, а не договорённостью.
  """

  use ExUnit.Case, async: true

  defp sources(dir) do
    Path.wildcard("#{dir}/**/*.ex")
    |> Enum.map(&{&1, File.read!(&1)})
  end

  defp offenders(dirs, regex) do
    dirs
    |> Enum.flat_map(&sources/1)
    |> Enum.filter(fn {_path, source} -> Regex.match?(regex, source) end)
    |> Enum.map(&elem(&1, 0))
  end

  @transport ["lib/api", "lib/socket"]
  @engine ["lib/block_poker/engine"]

  test "транспорт не ходит в Repo" do
    assert offenders(@transport, ~r/BlockPoker\.Repo|\bRepo\./) == []
  end

  test "транспорт не пишет запросов" do
    assert offenders(@transport, ~r/Ecto\.Query|\bfrom\(/) == []
  end

  test "транспорт не знает про хэширование паролей" do
    assert offenders(@transport, ~r/Argon2/) == []
  end

  test "журнал операций трогает только контекст Wallet" do
    dirs = ["lib/api", "lib/socket", "lib/block_poker/accounts", "lib/block_poker/tables"]

    assert offenders(dirs, ~r/WalletEntry|wallet_entries/) == []
  end

  test "записи журнала не обновляются и не удаляются нигде в коде" do
    offenders =
      offenders(
        ["lib"],
        ~r/(update|delete)(_all)?\(\s*WalletEntry|WalletEntry\s*\|>\s*Repo\.(update|delete)/
      )

    assert offenders == []
  end

  test "ядро правил не знает про хранилище, транспорт и процессы" do
    pattern = ~r/BlockPoker\.Repo|\bRepo\.|Ecto\.|Phoenix\.|GenServer|\bsend\(|Process\./

    assert offenders(@engine, pattern) == []
  end

  test "карты тасуются криптографическим RNG, а не :rand" do
    assert offenders(["lib"], ~r/:rand\./) == []
  end

  test "ветвление по виду покера живёт только в реестре вариантов" do
    offenders =
      @engine
      |> Enum.flat_map(&sources/1)
      |> Enum.reject(fn {path, _source} -> String.contains?(path, "variant") end)
      |> Enum.filter(fn {_path, source} ->
        Regex.match?(~r/:texas_holdem|TexasHoldem/, source)
      end)
      |> Enum.map(&elem(&1, 0))

    assert offenders == []
  end
end
