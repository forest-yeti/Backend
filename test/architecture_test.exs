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
    pattern = ~r/:preflop|:flop\b|:turn\b|:river|:showdown/

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

  test "транспорт не знает правил китайского покера" do
    # §7 задачи 6. Слово `ofc` в транспорте разрешено — это **раздел
    # витрины**: у столов китайского покера свой топик лобби, и назвать
    # его как-то надо. А вот правила дисциплины — фантазия, роялти и
    # названия боксов — в транспорт протечь не должны: набор полей
    # выбирает дисциплина, view его только рендерит.
    pattern = ~r/fantasy|royalt|:top\b|:middle\b|:bottom\b/

    assert offenders(@transport, pattern) == []
  end

  test "оболочка стола не знает, во что за ним играют" do
    # §8 задачи 6: дисциплина зовётся модулем, и ни один файл оболочки не
    # называет ни OFC, ни его понятий.
    shell = [
      "lib/block_poker/tables/table_server.ex",
      "lib/block_poker/tables/room_state.ex",
      "lib/socket/views/table_view.ex"
    ]

    assert offenders(shell, ~r/Ofc|ofc_|fantas|royalt|boxes/) == []
  end

  test "дисциплина китайского покера не ходит в БД и не заводит процессов" do
    pattern = ~r/BlockPoker\.Repo|\bRepo\.|Ecto\.|Phoenix\.|GenServer|\bsend\(|Process\./

    assert offenders(["lib/block_poker/engine/ofc"], pattern) == []
  end

  test "ядро правил не знает про режим игры" do
    assert offenders(@engine, ~r/GameMode/) == []
  end

  test "раздача не знает ни блайндов, ни анте — только номинал структуры" do
    # §3.4 задачи 4: вынужденные ставки собирает `BettingStructure`, и
    # упоминание блайндов в `Hand` означало бы, что шов проведён неверно.
    source = "lib/block_poker/engine/hand.ex" |> sources() |> hd() |> elem(1) |> strip_docs()

    refute Regex.match?(~r/small_blind|big_blind|\bante\b/, source)
  end

  test "ветвление по структуре ставок живёт только в её реестре реализаций" do
    offenders =
      @engine
      |> Enum.flat_map(&sources/1)
      |> Enum.reject(fn {path, _source} ->
        String.contains?(path, "betting_structure") or String.contains?(path, "variant")
      end)
      |> Enum.filter(fn {_path, source} ->
        Regex.match?(~r/:button_ante|ButtonAnte|:blinds\b/, strip_docs(source))
      end)
      |> Enum.map(&elem(&1, 0))

    assert offenders == []
  end

  test "транспорт не знает ни видов покера, ни структур ставок" do
    pattern = ~r/:short_deck|ShortDeck|:texas_holdem|TexasHoldem|:button_ante|ButtonAnte/

    assert offenders(@transport, pattern) == []
  end

  test "транспорт не решает, кому и когда играть дважды" do
    # Канал только передаёт ответ игрока: кого спрашивают, разрешено ли это
    # за столом и чем кончилось — целиком дело ядра (§3 задачи 5).
    pattern = ~r/allowed_run_it_twice|run_it_twice\?|RunItTwice|\brit\./

    assert offenders(@transport, pattern) == []
  end

  test "админский транспорт не собирает список игр сам" do
    # §9 задачи 8: обходить `Registry` или `Lobby` из контроллера и канала
    # нельзя — список живых игр собирает `Admin.Games.live_games/1`.
    dirs = ["lib/api/controllers/admin", "lib/socket/channels/admin"]

    assert offenders(dirs, ~r/TableRegistry|Lobby\.|TableServer\.state|Tournaments\.card/) == []
  end

  test "админский транспорт зовёт только контекст Admin" do
    # Контроллеры и каналы панели вправе знать ровно один модуль ядра.
    # `Tables`/`Wallet`/`Accounts`/`Tournaments` мимо `Admin` — утёкшая логика.
    dirs = ["lib/api/controllers/admin", "lib/socket/channels/admin"]

    assert offenders(dirs, ~r/BlockPoker\.(Wallet|Accounts|Tables|Tournaments)\b/) == []
  end

  test "роль администратора проверяет ядро, а не транспорт" do
    # §4 задачи 8: `admin?` живёт внутри каждой публичной функции `Admin`.
    # Плаг проверяет подпись токена и не решает, можно ли.
    dirs = ["lib/api/controllers/admin", "lib/socket/channels/admin", "lib/api/plugs"]

    assert offenders(dirs, ~r/role\s*==|:admin\s*->|admin\?/) == []
  end

  test "записи журнала действий не обновляются и не удаляются нигде в коде" do
    # §8 задачи 8: `admin_audit` только на вставку. Запись, которую можно
    # поправить, ничего не доказывает.
    offenders =
      offenders(
        ["lib"],
        ~r/(update|delete)(_all)?\(\s*AdminAudit|AdminAudit\s*\|>\s*Repo\.(update|delete)/
      )

    assert offenders == []
  end

  test "наблюдение живёт ровно в трёх файлах" do
    # §13 задачи 8: удаление god-mode должно быть операцией на один коммит,
    # а не археологией. Упоминания вне трёх файлов — начало археологии.
    allowed = [
      "lib/block_poker/admin/observer.ex",
      "lib/block_poker/admin/admin.ex",
      "lib/socket/channels/admin/room_channel.ex",
      "lib/socket/views/admin/room_view.ex",
      # Сокет обязан знать про топик, чтобы его маршрутизировать, а
      # приложение — поднять процесс. Обе строки удаляются тем же коммитом.
      "lib/socket/admin_socket.ex",
      "lib/block_poker/application.ex"
    ]

    offenders =
      ["lib"]
      |> Enum.flat_map(&sources/1)
      |> Enum.reject(fn {path, _source} -> Path.relative_to_cwd(path) in allowed end)
      |> Enum.filter(fn {_path, source} ->
        Regex.match?(~r/Admin\.Observer|admin:room|table_debug/, strip_docs(source))
      end)
      |> Enum.map(&elem(&1, 0))

    assert offenders == []
  end

  test "наблюдение по умолчанию выключено" do
    # §13 задачи 8: в проде флаг не включён ни разу до тех пор, пока это
    # сознательно не сделано. Дефолт живёт в `config/config.exs`.
    config = File.read!("config/config.exs")

    assert config =~ ~r/config :block_poker, :admin_observer, enabled: false/
  end

  test "комната ходит в кошелёк только через контекст, а не сама" do
    # TableServer держит фишки, но деньгами не двигает: иначе одна медленная
    # транзакция останавливала бы весь стол.
    assert offenders(["lib/block_poker/tables/table_server.ex"], ~r/Wallet\./) == []
  end
end
