defmodule BlockPoker.ArchitectureTest do
  @moduledoc """
  Границы слоёв (§3 CLAUDE.md) проверяются автотестом, а не договорённостью.
  """

  use ExUnit.Case, async: true

  # Принимает и каталог, и конкретный файл: часть правил адресна одному модулю.
  defp sources(path) do
    paths = if File.dir?(path), do: Path.wildcard("#{path}/**/*.ex"), else: [path]
    Enum.map(paths, &{&1, File.read!(&1)})
  end

  # Правила проверяются по коду, а не по документации: упоминание модуля
  # в @moduledoc — это объяснение границы, а не её нарушение.
  defp strip_docs(source), do: String.replace(source, ~r/"""(?s).*?"""/, "")

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

  test "транспорт не ветвится по доменным состояниям раздачи" do
    # Ветвление по правилам игры вне engine запрещено (§3 CLAUDE.md).
    pattern = ~r/:preflop|:flop|:turn|:river|:showdown/

    assert offenders(@transport, pattern) == []
  end

  test "транспорт не считает деньги и не дублирует доменные константы" do
    # Суммы, поты, минимальный рейз и границы бай-ина считает ядро;
    # в канале не должно быть ни арифметики над фишками, ни блайндов.
    pattern = ~r/min_buy_in_chips|max_buy_in_chips|rake|small_blind\s*\*|big_blind\s*\*/

    offenders = offenders(["lib/socket/channels", "lib/api"], pattern)

    assert offenders == []
  end

  test "движок раздачи не знает про кэш-игру" do
    # §9 задачи 3: раздача одинакова для кэша и турнира, поэтому ссылок
    # на контекст CashGames в engine быть не может.
    offenders =
      @engine
      |> Enum.flat_map(&sources/1)
      |> Enum.filter(fn {_path, source} ->
        Regex.match?(~r/CashGames|CashGameSetting|Wallet|Tables\./, strip_docs(source))
      end)
      |> Enum.map(&elem(&1, 0))

    assert offenders == []
  end

  test "ядро правил не знает про режим игры" do
    assert offenders(@engine, ~r/GameMode/) == []
  end

  test "комната ходит в кошелёк только через контекст, а не сама" do
    # TableServer держит фишки, но деньгами не двигает: иначе одна медленная
    # транзакция останавливала бы весь стол.
    assert offenders(["lib/block_poker/tables/table_server.ex"], ~r/Wallet\./) == []
  end
end
