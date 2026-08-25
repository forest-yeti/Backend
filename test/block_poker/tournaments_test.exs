defmodule BlockPoker.TournamentsTest do
  @moduledoc """
  Контекст турниров на настоящей MySQL под Sandbox.

  БД здесь не мокается намеренно (§11 CLAUDE.md): значительная часть
  гарантий по деньгам обеспечивается самой базой — `UNIQUE` на
  `idempotency_key`, `UNIQUE` на номер входа, откат транзакции. Мок
  этих правил проверял бы мок.

  Поэтому тесты двойной регистрации и повторной выплаты сформулированы
  так, чтобы падать, если constraint убрать: они не проверяют «код
  вернул ошибку», они проверяют, что второй записи в БД не появилось.
  """

  use BlockPoker.DataCase, async: true

  import BlockPoker.AccountsFixtures
  import BlockPoker.TournamentsFixtures

  alias BlockPoker.Tickets
  alias BlockPoker.Tickets.UserTicket
  alias BlockPoker.Tournaments
  alias BlockPoker.Tournaments.{Entry, Tournament}
  alias BlockPoker.Wallet
  alias BlockPoker.Wallet.WalletEntry

  defp balance(user, currency \\ :play_money) do
    {:ok, wallet} = Wallet.get_wallet(user.id, currency)
    wallet.amount
  end

  defp entries_of(tournament),
    do: Repo.all(from(e in Entry, where: e.tournament_id == ^tournament.id))

  defp ledger(user, currency \\ :play_money) do
    {:ok, wallet} = Wallet.get_wallet(user.id, currency)

    Repo.all(from(e in WalletEntry, where: e.wallet_id == ^wallet.id, order_by: e.inserted_at))
  end

  describe "шаблон целиком" do
    test "создаётся вместе с уровнями и сеткой" do
      setting = setting_fixture()

      assert length(setting.blind_levels) == 2
      assert length(setting.payout_rows) == 2
      assert Tournaments.audit(setting) == :ok
    end

    test "структура с дырой в уровнях не создаётся" do
      levels = [
        %{level: 1, small_blind: 25, big_blind: 50, duration_seconds: 600, rebuy_allowed: false},
        %{level: 3, small_blind: 50, big_blind: 100, duration_seconds: 600, rebuy_allowed: false}
      ]

      assert {:error, :levels_not_contiguous} =
               Tournaments.create_setting(valid_setting_attrs(), levels, valid_payouts())
    end

    test "ребаи, закрывшиеся и снова открывшиеся, — ошибка оператора" do
      levels = [
        %{level: 1, small_blind: 25, big_blind: 50, duration_seconds: 600, rebuy_allowed: true},
        %{level: 2, small_blind: 50, big_blind: 100, duration_seconds: 600, rebuy_allowed: false},
        %{level: 3, small_blind: 75, big_blind: 150, duration_seconds: 600, rebuy_allowed: true},
        %{level: 4, small_blind: 100, big_blind: 200, duration_seconds: 600, rebuy_allowed: false}
      ]

      assert {:error, :rebuy_not_monotonic} =
               Tournaments.create_setting(valid_setting_attrs(), levels, valid_payouts())
    end

    test "турнир, где регистрация не закрывается, создать нельзя" do
      levels = [
        %{level: 1, small_blind: 25, big_blind: 50, duration_seconds: 600, rebuy_allowed: true}
      ]

      assert {:error, :rebuy_never_closes} =
               Tournaments.create_setting(valid_setting_attrs(), levels, valid_payouts())
    end

    test "сетка, не складывающаяся в миллион, откатывает весь шаблон" do
      payouts = [
        %{entries_from: 2, entries_to: nil, place_from: 1, place_to: 1, share_ppm: 500_000}
      ]

      assert {:error, :shares_do_not_sum} =
               Tournaments.create_setting(valid_setting_attrs(), valid_levels(), payouts)

      # Откат целиком: половины шаблона в БД не осталось.
      assert Tournaments.list_settings() == []
    end

    test "голова больше взноса не проходит" do
      assert {:error, changeset} =
               Tournaments.create_setting(
                 valid_setting_attrs(%{buy_in: 1000, bounty_part: 1500}),
                 valid_levels(),
                 valid_payouts()
               )

      assert %{bounty_part: _errors} = errors_on(changeset)
    end
  end

  describe "снапшот настроек" do
    test "снимается при открытии регистрации" do
      setting = setting_fixture()
      tournament = tournament_fixture(setting)

      assert is_map(tournament.snapshot)
      assert tournament.status == :registering
    end

    test "несёт уровни вместе с флагами входа" do
      setting = setting_fixture()
      tournament = tournament_fixture(setting)

      levels = tournament.snapshot["levels"]

      assert length(levels) == 2
      assert Enum.map(levels, & &1["level"]) == [1, 2]
      assert Enum.map(levels, & &1["big_blind"]) == [50, 100]

      # Флаг входа — половина смысла снапшота: по нему процесс решает,
      # можно ли ещё войти, и читать его из шаблона он не вправе.
      assert Enum.map(levels, & &1["rebuy_allowed"]) == [true, false]
      assert Enum.map(levels, & &1["addon_allowed"]) == [false, false]
    end

    test "несёт сетку выплат" do
      setting = setting_fixture()
      tournament = tournament_fixture(setting)

      assert [first, second] = tournament.snapshot["payouts"]
      assert first["share_ppm"] == 650_000
      assert second["place_from"] == 2
    end

    test "несёт цены, включая выведенные из умолчаний" do
      setting = setting_fixture(%{rebuy_allowed: true, max_rebuys: 1})
      tournament = tournament_fixture(setting)

      # `rebuy_cost` и `rebuy_stack` в шаблоне пустые — в снапшот уходят
      # уже посчитанные значения, а не `nil`, который процессу пришлось бы
      # разворачивать самому.
      assert tournament.snapshot["rebuy_cost"] == 1100
      assert tournament.snapshot["rebuy_stack"] == 5000
    end

    test "ключи строковые: это JSON, а не структура Elixir" do
      setting = setting_fixture()
      tournament = tournament_fixture(setting)

      assert Enum.all?(Map.keys(tournament.snapshot), &is_binary/1)

      assert Enum.all?(tournament.snapshot["levels"], fn level ->
               Enum.all?(Map.keys(level), &is_binary/1)
             end)
    end

    test "переживает перечитывание из БД" do
      setting = setting_fixture()
      tournament = tournament_fixture(setting)

      {:ok, reloaded} = Tournaments.get_tournament(tournament.id)

      assert reloaded.snapshot == tournament.snapshot
    end

    test "правка шаблона после снятия снапшота его не меняет" do
      setting = setting_fixture()
      tournament = tournament_fixture(setting)

      {:ok, _updated} =
        setting.blind_levels
        |> hd()
        |> BlockPoker.Tournaments.BlindLevel.changeset(%{big_blind: 999_999})
        |> Repo.update()

      {:ok, reloaded} = Tournaments.get_tournament(tournament.id)

      # Ради этого снапшот и существует: правка структуры в БД не должна
      # поднимать блайнды посреди идущего турнира.
      assert hd(reloaded.snapshot["levels"])["big_blind"] == 50
    end
  end

  describe "цена входа" do
    test "обычный турнир: весь взнос в фонд" do
      setting = setting_fixture()

      assert Tournaments.price_of(setting, :entry) == %{
               total: 1100,
               stake: 1000,
               fee: 100,
               bounty: 0,
               prize: 1000
             }
    end

    test "баунти-турнир: часть взноса уходит на голову, а не в фонд" do
      setting = setting_fixture(%{bounty_part: 400})

      price = Tournaments.price_of(setting, :entry)

      assert price.bounty == 400
      assert price.prize == 600
      assert price.total == 1100
    end

    test "ре-энтри делится в той же пропорции, что и первичный вход" do
      setting = setting_fixture(%{bounty_part: 400, rebuy_allowed: true, rebuy_cost: 1100})

      assert Tournaments.price_of(setting, :reentry).bounty == 400
    end

    test "фриролл: цена входа нулевая" do
      setting = setting_fixture(%{buy_in: 0, entry_fee: 0})

      assert Tournaments.price_of(setting, :entry).total == 0
    end
  end

  describe "регистрация деньгами" do
    setup do
      setting = setting_fixture()
      %{setting: setting, tournament: tournament_fixture(setting), user: user_fixture()}
    end

    test "списывает взнос и комиссию, заводит вход", %{tournament: tournament, user: user} do
      before = balance(user)

      assert {:ok, entry} = Tournaments.register(tournament.id, user.id)

      assert entry.entry_number == 1
      assert entry.status == :registered
      assert balance(user) == before - 1100
    end

    test "взнос и комиссия — разные записи журнала", %{tournament: tournament, user: user} do
      {:ok, _entry} = Tournaments.register(tournament.id, user.id)

      types = user |> ledger() |> Enum.map(& &1.type)

      assert :tournament_entry in types
      assert :tournament_fee in types
    end

    test "счётчики входов и людей растут", %{tournament: tournament, user: user} do
      {:ok, _entry} = Tournaments.register(tournament.id, user.id)

      {:ok, reloaded} = Tournaments.get_tournament(tournament.id)

      assert reloaded.entries_count == 1
      assert reloaded.players_count == 1
    end

    test "двойной клик не создаёт второго входа и не списывает дважды", %{
      tournament: tournament,
      user: user
    } do
      before = balance(user)

      assert {:ok, _entry} = Tournaments.register(tournament.id, user.id)
      assert {:error, :already_registered} = Tournaments.register(tournament.id, user.id)

      assert length(entries_of(tournament)) == 1
      assert balance(user) == before - 1100
    end

    test "денег не хватает — отказ целиком, без частичной регистрации" do
      setting = setting_fixture(%{buy_in: 100_000, entry_fee: 1000})
      tournament = tournament_fixture(setting)
      user = user_fixture()

      before = balance(user)

      assert {:error, :insufficient_funds} = Tournaments.register(tournament.id, user.id)

      assert entries_of(tournament) == []
      assert balance(user) == before
    end

    test "денег хватает на взнос, но не на комиссию — тоже отказ целиком" do
      # Баланс 10_000: взнос проходит, комиссия уже нет.
      setting = setting_fixture(%{buy_in: 10_000, entry_fee: 500})
      tournament = tournament_fixture(setting)
      user = user_fixture()

      assert {:error, :insufficient_funds} = Tournaments.register(tournament.id, user.id)

      assert entries_of(tournament) == []
      assert balance(user) == 10_000
    end

    test "в анонсированный турнир войти нельзя", %{setting: setting, user: user} do
      tournament = tournament_fixture(setting, %{status: :announced})

      # Фикстура открывает регистрацию, поэтому статус возвращаем руками.
      {:ok, tournament} =
        tournament |> Tournament.changeset(%{status: :announced}) |> Repo.update()

      assert {:error, :registration_closed} = Tournaments.register(tournament.id, user.id)
    end

    test "в отменённый турнир войти нельзя", %{tournament: tournament, user: user} do
      {:ok, tournament} =
        tournament |> Tournament.changeset(%{status: :cancelled}) |> Repo.update()

      assert {:error, :tournament_cancelled} = Tournaments.register(tournament.id, user.id)
    end

    test "фриролл не пишет в журнал вовсе" do
      setting = setting_fixture(%{buy_in: 0, entry_fee: 0})
      tournament = tournament_fixture(setting)
      user = user_fixture()

      before = length(ledger(user))

      assert {:ok, _entry} = Tournaments.register(tournament.id, user.id)
      assert length(ledger(user)) == before
    end
  end

  describe "потолки" do
    test "потолок людей закрывает вход" do
      setting = setting_fixture(%{min_players: 2, max_players: 2})
      tournament = tournament_fixture(setting)

      {:ok, _one} = Tournaments.register(tournament.id, user_fixture().id)
      {:ok, _two} = Tournaments.register(tournament.id, user_fixture().id)

      assert {:error, :tournament_full} = Tournaments.register(tournament.id, user_fixture().id)
    end

    test "потолок входов закрывает регистрацию досрочно" do
      setting = setting_fixture(%{max_entries: 2})
      tournament = tournament_fixture(setting)

      {:ok, _one} = Tournaments.register(tournament.id, user_fixture().id)
      {:ok, _two} = Tournaments.register(tournament.id, user_fixture().id)

      assert {:error, :tournament_full} = Tournaments.register(tournament.id, user_fixture().id)
    end
  end

  describe "ре-энтри" do
    setup do
      setting = setting_fixture(%{rebuy_allowed: true, max_rebuys: 1, bounty_part: 400})
      tournament = tournament_fixture(setting)
      user = user_fixture()

      {:ok, entry} = Tournaments.register(tournament.id, user.id)

      %{setting: setting, tournament: tournament, user: user, entry: entry}
    end

    test "игрок с фишками войти заново не может", %{tournament: tournament, user: user} do
      assert {:error, :already_registered} = Tournaments.reenter(tournament.id, user.id)
    end

    test "выбывший входит заново и получает новый номер входа", %{
      tournament: tournament,
      user: user,
      entry: entry
    } do
      {:ok, _busted} = Tournaments.bust(entry.id, nil)

      assert {:ok, second} = Tournaments.reenter(tournament.id, user.id)
      assert second.entry_number == 2
    end

    test "повторный вход несёт новую голову", %{
      tournament: tournament,
      user: user,
      entry: entry
    } do
      {:ok, _busted} = Tournaments.bust(entry.id, nil)
      {:ok, second} = Tournaments.reenter(tournament.id, user.id)

      assert second.bounty == 400
    end

    test "ре-энтри растит входы, но не людей", %{
      tournament: tournament,
      user: user,
      entry: entry
    } do
      {:ok, _busted} = Tournaments.bust(entry.id, nil)
      {:ok, _second} = Tournaments.reenter(tournament.id, user.id)

      {:ok, reloaded} = Tournaments.get_tournament(tournament.id)

      assert reloaded.entries_count == 2
      assert reloaded.players_count == 1
      assert reloaded.reentries_count == 1
    end

    test "лимит игрока исчерпан", %{tournament: tournament, user: user, entry: entry} do
      {:ok, _busted} = Tournaments.bust(entry.id, nil)
      {:ok, second} = Tournaments.reenter(tournament.id, user.id)
      {:ok, _busted_again} = Tournaments.bust(second.id, nil)

      assert {:error, :rebuy_limit_reached} = Tournaments.reenter(tournament.id, user.id)
    end

    test "фризаут не пускает обратно" do
      setting = setting_fixture(%{rebuy_allowed: false})
      tournament = tournament_fixture(setting)
      user = user_fixture()

      {:ok, entry} = Tournaments.register(tournament.id, user.id)
      {:ok, _busted} = Tournaments.bust(entry.id, nil)

      assert {:error, :reentry_not_allowed} = Tournaments.reenter(tournament.id, user.id)
    end
  end

  describe "регистрация билетом" do
    setup do
      setting = setting_fixture()
      tournament = tournament_fixture(setting)
      user = user_fixture()
      ticket = ticket_fixture(setting)

      %{setting: setting, tournament: tournament, user: user, ticket: ticket}
    end

    test "билет гасится, денег не списывается", ctx do
      user_ticket = user_ticket_fixture(ctx.ticket, ctx.user)
      before = balance(ctx.user)

      assert {:ok, entry} =
               Tournaments.register(ctx.tournament.id, ctx.user.id, pay_with: :ticket)

      assert entry.paid_with_ticket_id == user_ticket.id
      assert balance(ctx.user) == before
      assert Repo.get!(UserTicket, user_ticket.id).status == :used
    end

    test "без билета в кошельке — отказ", ctx do
      assert {:error, :ticket_required} =
               Tournaments.register(ctx.tournament.id, ctx.user.id, pay_with: :ticket)
    end

    test "истёкший билет не пускают", ctx do
      _expired =
        user_ticket_fixture(ctx.ticket, ctx.user, %{
          expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      assert {:error, :ticket_required} =
               Tournaments.register(ctx.tournament.id, ctx.user.id, pay_with: :ticket)
    end

    test "второй билет остаётся активным: гасится ровно один", ctx do
      _first = user_ticket_fixture(ctx.ticket, ctx.user)
      _second = user_ticket_fixture(ctx.ticket, ctx.user)

      {:ok, _entry} = Tournaments.register(ctx.tournament.id, ctx.user.id, pay_with: :ticket)

      assert length(Tickets.list_active(ctx.user.id)) == 1
    end

    test "разрегистрация возвращает билет", ctx do
      user_ticket = user_ticket_fixture(ctx.ticket, ctx.user)

      {:ok, _entry} = Tournaments.register(ctx.tournament.id, ctx.user.id, pay_with: :ticket)
      :ok = Tournaments.unregister(ctx.tournament.id, ctx.user.id)

      returned = Repo.get!(UserTicket, user_ticket.id)

      assert returned.status == :active

      # Привязка к турниру снимается вместе со статусом: иначе уникальный
      # индекс не пустил бы игрока обратно в этот же турнир.
      assert returned.used_in_tournament_id == nil
    end

    test "возвращённым билетом можно войти снова", ctx do
      _user_ticket = user_ticket_fixture(ctx.ticket, ctx.user)

      {:ok, _first} = Tournaments.register(ctx.tournament.id, ctx.user.id, pay_with: :ticket)
      :ok = Tournaments.unregister(ctx.tournament.id, ctx.user.id)

      assert {:ok, second} =
               Tournaments.register(ctx.tournament.id, ctx.user.id, pay_with: :ticket)

      assert second.entry_number == 2
      assert second.paid_with_ticket_id != nil
    end

    test "разрегистрация по билету денег не начисляет", ctx do
      _user_ticket = user_ticket_fixture(ctx.ticket, ctx.user)
      before = balance(ctx.user)

      {:ok, _entry} = Tournaments.register(ctx.tournament.id, ctx.user.id, pay_with: :ticket)
      :ok = Tournaments.unregister(ctx.tournament.id, ctx.user.id)

      # Денег не списывали — возвращать нечего. Иначе билет обменивался бы
      # на деньги парой нажатий.
      assert balance(ctx.user) == before
    end

    test "ре-энтри билетом не оплачивается" do
      setting = setting_fixture(%{rebuy_allowed: true, max_rebuys: 2})
      tournament = tournament_fixture(setting)
      user = user_fixture()
      ticket = ticket_fixture(setting)
      _user_ticket = user_ticket_fixture(ticket, user)

      {:ok, entry} = Tournaments.register(tournament.id, user.id)
      {:ok, _busted} = Tournaments.bust(entry.id, nil)

      # Публичный путь ре-энтри денег не спрашивает: билет туда не подать.
      assert {:ok, second} = Tournaments.reenter(tournament.id, user.id)
      assert second.paid_with_ticket_id == nil
    end
  end

  describe "разрегистрация" do
    setup do
      setting = setting_fixture()
      %{setting: setting, tournament: tournament_fixture(setting), user: user_fixture()}
    end

    test "до старта возвращает взнос и комиссию", %{tournament: tournament, user: user} do
      before = balance(user)
      {:ok, _entry} = Tournaments.register(tournament.id, user.id)

      assert :ok = Tournaments.unregister(tournament.id, user.id)
      assert balance(user) == before

      # Строка входа остаётся возвращённой: она держит номер, из которого
      # строится ключ идемпотентности следующей оплаты.
      assert [%Entry{status: :refunded}] = entries_of(tournament)
    end

    test "счётчики возвращаются назад", %{tournament: tournament, user: user} do
      {:ok, _entry} = Tournaments.register(tournament.id, user.id)
      :ok = Tournaments.unregister(tournament.id, user.id)

      {:ok, reloaded} = Tournaments.get_tournament(tournament.id)

      assert reloaded.entries_count == 0
      assert reloaded.players_count == 0
    end

    test "после старта выйти нельзя", %{tournament: tournament, user: user} do
      {:ok, _entry} = Tournaments.register(tournament.id, user.id)
      {:ok, _started} = Tournaments.start(tournament, nil)

      assert {:error, :unregister_too_late} = Tournaments.unregister(tournament.id, user.id)
    end

    test "повторный вход после разрегистрации снова стоит денег", %{
      tournament: tournament,
      user: user
    } do
      start = balance(user)

      {:ok, _first} = Tournaments.register(tournament.id, user.id)
      :ok = Tournaments.unregister(tournament.id, user.id)
      assert balance(user) == start

      # Ключ идемпотентности несёт номер входа. Без него кошелёк принял бы
      # вторую регистрацию за ретрай первой и пустил бы игрока даром.
      {:ok, second} = Tournaments.register(tournament.id, user.id)

      assert second.entry_number == 2
      assert balance(user) == start - 1100
    end

    test "разрегистрация не удаляет вход, а помечает возвращённым", %{
      tournament: tournament,
      user: user
    } do
      {:ok, entry} = Tournaments.register(tournament.id, user.id)
      :ok = Tournaments.unregister(tournament.id, user.id)

      assert Repo.get!(Entry, entry.id).status == :refunded
    end

    test "возвращённый вход не занимает места и не тратит попытку" do
      setting =
        setting_fixture(%{min_players: 2, max_players: 2, rebuy_allowed: true, max_rebuys: 1})

      tournament = tournament_fixture(setting)
      user = user_fixture()

      {:ok, _first} = Tournaments.register(tournament.id, user.id)
      :ok = Tournaments.unregister(tournament.id, user.id)

      # Место освободилось: потолок в одного человека снова не выбран.
      assert {:ok, second} = Tournaments.register(tournament.id, user.id)

      # И попытка ре-энтри не потрачена: разрегистрация — не вылет.
      {:ok, _busted} = Tournaments.bust(second.id, nil)
      assert {:ok, _third} = Tournaments.reenter(tournament.id, user.id)
    end

    test "счётчик людей после разрегистрации и возврата не задваивается", %{
      tournament: tournament,
      user: user
    } do
      {:ok, _first} = Tournaments.register(tournament.id, user.id)
      :ok = Tournaments.unregister(tournament.id, user.id)
      {:ok, _second} = Tournaments.register(tournament.id, user.id)

      {:ok, reloaded} = Tournaments.get_tournament(tournament.id)

      assert reloaded.players_count == 1
      assert reloaded.entries_count == 1
    end

    test "незарегистрированный получает отказ", %{tournament: tournament, user: user} do
      assert {:error, :not_registered} = Tournaments.unregister(tournament.id, user.id)
    end
  end

  describe "отмена по недобору" do
    test "возвращает деньги всем одной транзакцией" do
      setting = setting_fixture()
      tournament = tournament_fixture(setting)
      one = user_fixture()
      two = user_fixture()

      before_one = balance(one)
      before_two = balance(two)

      {:ok, _e1} = Tournaments.register(tournament.id, one.id)
      {:ok, _e2} = Tournaments.register(tournament.id, two.id)

      assert {:ok, 2} = Tournaments.cancel(tournament.id)

      assert balance(one) == before_one
      assert balance(two) == before_two
    end

    test "возвращает билеты" do
      setting = setting_fixture()
      tournament = tournament_fixture(setting)
      user = user_fixture()
      ticket = ticket_fixture(setting)
      user_ticket = user_ticket_fixture(ticket, user)

      {:ok, _entry} = Tournaments.register(tournament.id, user.id, pay_with: :ticket)

      assert {:ok, 1} = Tournaments.cancel(tournament.id)

      returned = Repo.get!(UserTicket, user_ticket.id)
      assert returned.status == :active

      # Иначе уникальный индекс не пустил бы игрока в следующий запуск.
      assert returned.used_in_tournament_id == nil
    end

    test "входы помечаются возвращёнными, а не остаются живыми" do
      setting = setting_fixture()
      tournament = tournament_fixture(setting)
      user = user_fixture()

      {:ok, entry} = Tournaments.register(tournament.id, user.id)
      {:ok, 1} = Tournaments.cancel(tournament.id)

      assert Repo.get!(Entry, entry.id).status == :refunded
    end

    test "турнир переходит в cancelled" do
      setting = setting_fixture()
      tournament = tournament_fixture(setting)

      {:ok, _cancelled} = Tournaments.cancel(tournament.id)
      {:ok, reloaded} = Tournaments.get_tournament(tournament.id)

      assert reloaded.status == :cancelled
    end

    test "начавшийся турнир отменить нельзя" do
      setting = setting_fixture()
      tournament = tournament_fixture(setting)
      {:ok, started} = Tournaments.start(tournament, nil)

      assert {:error, :tournament_started} = Tournaments.cancel(started.id)
    end

    test "гарантия при отмене не выплачивается" do
      setting = setting_fixture(%{guarantee: 1_000_000})
      tournament = tournament_fixture(setting)
      user = user_fixture()

      before = balance(user)
      {:ok, _entry} = Tournaments.register(tournament.id, user.id)

      {:ok, 1} = Tournaments.cancel(tournament.id)

      # Ровно взнос обратно и ни центом больше: GTD обещает фонд
      # состоявшегося турнира, а несостоявшийся не обещает ничего.
      assert balance(user) == before
    end
  end

  describe "фонд" do
    test "собранное не включает комиссию" do
      setting = setting_fixture()
      tournament = tournament_fixture(setting)

      {:ok, _e1} = Tournaments.register(tournament.id, user_fixture().id)
      {:ok, _e2} = Tournaments.register(tournament.id, user_fixture().id)

      {:ok, reloaded} = Tournaments.get_tournament(tournament.id)

      # Два взноса по 1000; комиссия 2×100 осталась руму.
      assert Tournaments.collected(reloaded) == 2000
    end

    test "собранное не включает головы" do
      setting = setting_fixture(%{bounty_part: 400})
      tournament = tournament_fixture(setting)

      {:ok, _e1} = Tournaments.register(tournament.id, user_fixture().id)

      {:ok, reloaded} = Tournaments.get_tournament(tournament.id)

      assert Tournaments.collected(reloaded) == 600
    end

    test "вход по билету зачитывается по номиналу билета" do
      setting = setting_fixture()
      ticket = ticket_fixture(setting, %{face_value: 1100})
      user = user_fixture()
      _user_ticket = user_ticket_fixture(ticket, user)

      # Турнир подорожал уже после выдачи билета.
      {:ok, _updated} =
        setting
        |> BlockPoker.Tournaments.TournamentSetting.changeset(%{buy_in: 5000})
        |> Repo.update()

      {:ok, setting} = Tournaments.get_setting(setting.id)
      tournament = tournament_fixture(setting)

      {:ok, _entry} = Tournaments.register(tournament.id, user.id, pay_with: :ticket)
      {:ok, reloaded} = Tournaments.get_tournament(tournament.id)

      # В фонд ушёл номинал за вычетом комиссии, а не сегодняшняя цена:
      # разницу доплачивает рум, но фонд не раздувается деньгами, которых
      # никто не вносил.
      assert Tournaments.collected(reloaded) == 1000
    end

    test "аддон идёт в фонд целиком" do
      setting = setting_fixture(%{addon_cost: 500, addon_stack: 5000})
      tournament = tournament_fixture(setting)
      user = user_fixture()

      {:ok, _entry} = Tournaments.register(tournament.id, user.id)
      {:ok, _addon} = Tournaments.addon(tournament.id, user.id)

      {:ok, reloaded} = Tournaments.get_tournament(tournament.id)

      # 1000 призовой части входа плюс 500 аддона: голову аддон не растит.
      assert Tournaments.collected(reloaded) == 1500
    end

    test "аддон после фиксации фонда в него всё-таки попадает" do
      setting = setting_fixture(%{addon_cost: 500, addon_stack: 5000})
      tournament = tournament_fixture(setting)
      user = user_fixture()

      {:ok, _entry} = Tournaments.register(tournament.id, user.id)
      {:ok, _second} = Tournaments.register(tournament.id, user_fixture().id)

      # Окно входа закрывается по стенным часам, а перерыв с аддоном
      # приходит по часам уровня — те стоят на каждом перерыве. То есть
      # аддонный перерыв наступает **после** фиксации почти всегда, и
      # эти деньги не имеют права пропасть.
      {:ok, tournament} = Tournaments.get_tournament(tournament.id)
      {:ok, closed} = Tournaments.close_late_reg(tournament)
      assert closed.prize_pool == 2000

      {:ok, _addon} = Tournaments.addon(tournament.id, user.id)

      {:ok, reloaded} = Tournaments.get_tournament(tournament.id)
      assert Tournaments.collected(reloaded) == 2500
      assert reloaded.prize_pool == 2500

      # И сетка выплат считает уже от него: место стоит больше, чем
      # стоило до аддона.
      {:ok, payouts} = Tournaments.payouts(reloaded)
      assert Enum.sum(Enum.map(payouts, & &1.amount)) == 2500
    end

    test "аддон после фиксации съедает оверлей, а не добавляется к гарантии" do
      setting = setting_fixture(%{addon_cost: 500, addon_stack: 5000, guarantee: 10_000})
      tournament = tournament_fixture(setting)
      user = user_fixture()

      {:ok, _entry} = Tournaments.register(tournament.id, user.id)
      {:ok, tournament} = Tournaments.get_tournament(tournament.id)
      {:ok, closed} = Tournaments.close_late_reg(tournament)

      assert closed.prize_pool == 10_000
      assert closed.overlay == 9000

      {:ok, _addon} = Tournaments.addon(tournament.id, user.id)

      # Фонд держит гарантия, и он не растёт: растёт вклад игроков,
      # а доля рума на те же 500 уменьшается.
      {:ok, reloaded} = Tournaments.get_tournament(tournament.id)
      assert reloaded.prize_pool == 10_000
      assert reloaded.overlay == 8500
    end

    test "доигранный турнир аддон не продаёт" do
      setting = setting_fixture(%{addon_cost: 500, addon_stack: 5000})
      tournament = tournament_fixture(setting)
      user = user_fixture()

      {:ok, _entry} = Tournaments.register(tournament.id, user.id)

      {:ok, tournament} = Tournaments.get_tournament(tournament.id)

      {:ok, _finished} =
        tournament
        |> Tournament.changeset(%{status: :finished})
        |> BlockPoker.Repo.update()

      assert {:error, :addon_not_allowed} = Tournaments.addon(tournament.id, user.id)
    end

    test "откат аддона возвращает и деньги, и фонд" do
      setting = setting_fixture(%{addon_cost: 500, addon_stack: 5000})
      tournament = tournament_fixture(setting)
      user = user_fixture()

      {:ok, _entry} = Tournaments.register(tournament.id, user.id)
      {:ok, tournament} = Tournaments.get_tournament(tournament.id)
      {:ok, _closed} = Tournaments.close_late_reg(tournament)

      before = balance(user)

      {:ok, entry} = Tournaments.addon(tournament.id, user.id)
      assert balance(user) == before - 500

      :ok = Tournaments.refund_addon(tournament.id, entry.id)

      # Всё на месте: кошелёк, счётчик аддонов входа и фонд.
      assert balance(user) == before

      {:ok, reloaded} = Tournaments.get_tournament(tournament.id)
      assert Tournaments.collected(reloaded) == 1000
      assert reloaded.prize_pool == 1000
      assert reloaded.addons_count == 0

      {:ok, refunded} = Tournaments.get_entry(entry.id)
      assert refunded.addons_count == 0
    end

    test "расчёт платит по сетке инстанса, а не по правленому шаблону" do
      setting = setting_fixture()
      tournament = tournament_fixture(setting)

      {:ok, _first} = Tournaments.register(tournament.id, user_fixture().id)
      {:ok, _second} = Tournaments.register(tournament.id, user_fixture().id)

      {:ok, tournament} = Tournaments.get_tournament(tournament.id)
      {:ok, closed} = Tournaments.close_late_reg(tournament)

      # Сумма, объявленная игроку сейчас: 65% фонда за первое место.
      {:ok, announced} = Tournaments.current_payouts(closed)
      assert Enum.find(announced, &(&1.place == 1)).amount == 1300

      # Оператор правит шаблон посреди турнира — так бывает, и снапшот
      # инстанса существует ровно ради этого.
      for row <- setting.payout_rows do
        share = if row.place_from == 1, do: 900_000, else: 100_000

        {:ok, _updated} =
          row |> BlockPoker.Tournaments.PayoutRow.changeset(%{share_ppm: share}) |> Repo.update()
      end

      {:ok, reloaded} = Tournaments.get_tournament(tournament.id)

      # По этой функции пишутся деньги. Разойтись с уже объявленной
      # суммой ей нельзя: игрок обязан получить то, что ему сказали.
      {:ok, paid} = Tournaments.payouts(reloaded)
      assert Enum.find(paid, &(&1.place == 1)).amount == 1300
    end

    test "закрытие поздней регистрации фиксирует фонд и оверлей" do
      setting = setting_fixture(%{guarantee: 10_000})
      tournament = tournament_fixture(setting)

      {:ok, _e1} = Tournaments.register(tournament.id, user_fixture().id)
      {:ok, _e2} = Tournaments.register(tournament.id, user_fixture().id)

      {:ok, reloaded} = Tournaments.get_tournament(tournament.id)
      {:ok, closed} = Tournaments.close_late_reg(reloaded)

      assert closed.status == :late_reg_closed
      assert closed.prize_pool == 10_000
      assert closed.overlay == 8000
    end
  end

  describe "оверлей" do
    setup do
      setting = setting_fixture(%{guarantee: 10_000})
      tournament = tournament_fixture(setting)
      user = user_fixture()

      {:ok, entry} = Tournaments.register(tournament.id, user.id)
      {:ok, tournament} = Tournaments.get_tournament(tournament.id)
      {:ok, tournament} = Tournaments.close_late_reg(tournament)

      %{tournament: tournament, user: user, entry: entry}
    end

    test "списывается с кассы рума отдельной записью", ctx do
      {:ok, house} = Wallet.house_wallet(:play_money)
      before = house.amount

      {:ok, _payouts} =
        Tournaments.settle(ctx.tournament, [%{entry_id: ctx.entry.id, place: 1}])

      {:ok, house} = Wallet.house_wallet(:play_money)

      # Гарантия 10 000 против собранной 1000: рум доложил 9000.
      assert house.amount == before - 9000
    end

    test "касса уходит в минус законно", ctx do
      {:ok, _payouts} =
        Tournaments.settle(ctx.tournament, [%{entry_id: ctx.entry.id, place: 1}])

      {:ok, house} = Wallet.house_wallet(:play_money)

      # Касса — источник денег, а не их хранилище: её баланс и есть
      # накопленный результат рума, и в начале он отрицателен.
      assert house.amount < 0
    end

    test "запись видна в журнале типом overlay", ctx do
      {:ok, house} = Wallet.house_wallet(:play_money)

      {:ok, _payouts} =
        Tournaments.settle(ctx.tournament, [%{entry_id: ctx.entry.id, place: 1}])

      types =
        WalletEntry
        |> where([e], e.wallet_id == ^house.id)
        |> Repo.all()
        |> Enum.map(& &1.type)

      assert :overlay in types
    end

    test "турнир без гарантии кассу не трогает" do
      setting = setting_fixture()
      tournament = tournament_fixture(setting)
      user = user_fixture()

      {:ok, entry} = Tournaments.register(tournament.id, user.id)
      {:ok, tournament} = Tournaments.get_tournament(tournament.id)
      {:ok, tournament} = Tournaments.close_late_reg(tournament)

      {:ok, house} = Wallet.house_wallet(:play_money)
      before = house.amount

      {:ok, _payouts} = Tournaments.settle(tournament, [%{entry_id: entry.id, place: 1}])

      {:ok, house} = Wallet.house_wallet(:play_money)
      assert house.amount == before
    end

    test "повторная выплата не списывает оверлей дважды", ctx do
      results = [%{entry_id: ctx.entry.id, place: 1}]

      {:ok, _first} = Tournaments.settle(ctx.tournament, results)
      {:ok, house} = Wallet.house_wallet(:play_money)
      after_first = house.amount

      {:ok, _second} = Tournaments.settle(ctx.tournament, results)

      {:ok, house} = Wallet.house_wallet(:play_money)
      assert house.amount == after_first
    end
  end

  describe "выплаты" do
    setup do
      setting = setting_fixture()
      tournament = tournament_fixture(setting)

      one = user_fixture()
      two = user_fixture()

      {:ok, first} = Tournaments.register(tournament.id, one.id)
      {:ok, second} = Tournaments.register(tournament.id, two.id)

      {:ok, tournament} = Tournaments.get_tournament(tournament.id)
      {:ok, tournament} = Tournaments.close_late_reg(tournament)

      %{tournament: tournament, one: one, two: two, first: first, second: second}
    end

    test "суммы считаются от зафиксированного фонда", %{tournament: tournament} do
      {:ok, payouts} = Tournaments.payouts(tournament)

      assert Enum.map(payouts, & &1.amount) == [1300, 700]
    end

    test "правка сетки шаблона не сдвигает сумму идущего турнира", ctx do
      # Снапшот снят при открытии регистрации — с него и считается всё,
      # что относится к идущему инстансу. Иначе правка `tournament_payouts`
      # развела бы две цифры, которые обязаны сходиться: призовую границу
      # на баббле (её `TournamentServer` считает по снапшоту) и сумму,
      # объявленную вылетевшему в `player_busted`.
      {:ok, before} = Tournaments.current_payouts(ctx.tournament)
      assert Enum.map(before, & &1.amount) == [1300, 700]

      # Ровно то, что делает админ рума: правит строки сетки прямо в БД
      # (§6 CLAUDE.md), не трогая идущие инстансы.
      setting_id = ctx.tournament.tournament_setting_id

      {2, _} =
        BlockPoker.Tournaments.PayoutRow
        |> where([row], row.tournament_setting_id == ^setting_id)
        |> Repo.update_all(set: [share_ppm: 500_000])

      {:ok, reloaded} = Tournaments.get_tournament(ctx.tournament.id)

      # Шаблон уже другой, инстанс — прежний.
      assert Tournaments.payout_grid(reloaded.setting) |> Enum.map(& &1.share_ppm) == [
               500_000,
               500_000
             ]

      assert {:ok, ^before} = Tournaments.current_payouts(reloaded)
    end

    test "сетка пустого турнира не роняет карточку" do
      setting = setting_fixture()
      tournament = tournament_fixture(setting)

      # Карточка в лобби показывает выплаты «при текущей явке», и у
      # анонсированного турнира она нулевая.
      assert {:ok, []} = Tournaments.payouts(tournament)
    end

    test "отмена после разрегистрации не возвращает деньги дважды" do
      setting = setting_fixture(%{min_players: 3})
      tournament = tournament_fixture(setting)
      user = user_fixture()

      before = balance(user)
      {:ok, _entry} = Tournaments.register(tournament.id, user.id)
      :ok = Tournaments.unregister(tournament.id, user.id)

      # Отмена перебирает все входы турнира, включая уже возвращённый.
      # Второй возврат гасит ключ идемпотентности, а не проверка в коде.
      {:ok, _refunded} = Tournaments.cancel(tournament.id)

      assert balance(user) == before
    end

    test "призы начисляются на кошельки", ctx do
      before_one = balance(ctx.one)

      {:ok, _payouts} =
        Tournaments.settle(ctx.tournament, [
          %{entry_id: ctx.first.id, place: 1},
          %{entry_id: ctx.second.id, place: 2}
        ])

      assert balance(ctx.one) == before_one + 1300
    end

    test "выплата помечает входы и ставит места", ctx do
      {:ok, _payouts} =
        Tournaments.settle(ctx.tournament, [
          %{entry_id: ctx.first.id, place: 1},
          %{entry_id: ctx.second.id, place: 2}
        ])

      winner = Repo.get!(Entry, ctx.first.id)

      assert winner.status == :paid
      assert winner.place == 1
      assert winner.prize == 1300
    end

    test "турнир закрывается в той же транзакции", ctx do
      {:ok, _payouts} =
        Tournaments.settle(ctx.tournament, [%{entry_id: ctx.first.id, place: 1}])

      {:ok, reloaded} = Tournaments.get_tournament(ctx.tournament.id)

      assert reloaded.status == :finished
      assert reloaded.finished_at
    end

    test "сумма выплат равна фонду ровно", ctx do
      {:ok, payouts} = Tournaments.payouts(ctx.tournament)

      total = Enum.reduce(payouts, 0, &(&2 + &1.amount + &1.ticket_value))

      assert total == ctx.tournament.prize_pool
    end

    test "слитые места делятся поровну", ctx do
      before_one = balance(ctx.one)
      before_two = balance(ctx.two)

      # Двое вылетели одной раздачей с равным стеком: игра не решила,
      # кто из них выше, и решать это деньгами нельзя. Призы первого и
      # второго места складываются и делятся пополам
      # (`Engine.Elimination`).
      {:ok, _payouts} =
        Tournaments.settle(ctx.tournament, [
          %{entry_id: ctx.first.id, place: 1, shared_places: [1, 2]},
          %{entry_id: ctx.second.id, place: 2, shared_places: [1, 2]}
        ])

      assert balance(ctx.one) == before_one + 1000
      assert balance(ctx.two) == before_two + 1000

      # И в БД лежит то же, что ушло в кошелёк: иначе история покажет
      # одну сумму, а кошелёк другую.
      assert Repo.get!(Entry, ctx.first.id).prize == 1000
      assert Repo.get!(Entry, ctx.second.id).prize == 1000
    end

    test "сумма слитых мест равна сумме их призов", ctx do
      {:ok, payouts} = Tournaments.payouts(ctx.tournament)

      shared = [1, 2]

      total =
        Enum.reduce(shared, 0, fn place, acc ->
          acc + Tournaments.share_of_places(payouts, shared, place)
        end)

      # Ни фишки, ни копейки не теряется на делении: остаток уходит
      # первому по тайбрейку, а не пропадает.
      assert total == 1300 + 700
    end

    test "распавшаяся группа платит каждому его место", ctx do
      before_one = balance(ctx.one)

      # Связанный вход вошёл заново, вылета у него нет, и в результатах
      # его тоже нет. Делить не с кем — оставшийся получает своё место
      # целиком, а не половину.
      {:ok, _payouts} =
        Tournaments.settle(ctx.tournament, [
          %{entry_id: ctx.first.id, place: 1, shared_places: [1, 2]}
        ])

      assert balance(ctx.one) == before_one + 1300
    end

    test "повторная выплата не начисляет дважды", ctx do
      results = [%{entry_id: ctx.first.id, place: 1}]

      {:ok, _first_run} = Tournaments.settle(ctx.tournament, results)
      after_first = balance(ctx.one)

      # Ретрай после рестарта: `idempotency_key` гасит вторую запись
      # средствами БД, а не проверкой в коде.
      {:ok, _second_run} = Tournaments.settle(ctx.tournament, results)

      assert balance(ctx.one) == after_first
    end
  end

  describe "головы" do
    setup do
      setting = setting_fixture(%{bounty_part: 400})
      tournament = tournament_fixture(setting)

      killer = user_fixture()
      victim = user_fixture()

      {:ok, killer_entry} = Tournaments.register(tournament.id, killer.id)
      {:ok, victim_entry} = Tournaments.register(tournament.id, victim.id)

      {:ok, tournament} = Tournaments.get_tournament(tournament.id)

      %{
        tournament: tournament,
        killer: killer,
        victim: victim,
        killer_entry: killer_entry,
        victim_entry: victim_entry
      }
    end

    test "денежная часть попадает на кошелёк убийцы сразу", ctx do
      before = balance(ctx.killer)

      :ok =
        Tournaments.pay_bounty(ctx.tournament, %{
          payouts: [
            %{
              entry_id: ctx.killer_entry.id,
              victim_entry_id: ctx.victim_entry.id,
              seat: 1,
              amount: 200
            }
          ],
          increments: [%{entry_id: ctx.killer_entry.id, amount: 200}],
          refunds: []
        })

      assert balance(ctx.killer) == before + 200
    end

    test "прирост головы в журнал не пишется, но голову растит", ctx do
      :ok =
        Tournaments.pay_bounty(ctx.tournament, %{
          payouts: [
            %{
              entry_id: ctx.killer_entry.id,
              victim_entry_id: ctx.victim_entry.id,
              seat: 1,
              amount: 200
            }
          ],
          increments: [%{entry_id: ctx.killer_entry.id, amount: 200}],
          refunds: []
        })

      killer_entry = Repo.get!(Entry, ctx.killer_entry.id)
      types = ctx.killer |> ledger() |> Enum.map(& &1.type)

      assert killer_entry.bounty == 600
      assert Enum.count(types, &(&1 == :tournament_bounty)) == 1
    end

    test "заработанное баунти — сумма выплаченных голов этого турнира, а не текущая цена своей",
         ctx do
      :ok =
        Tournaments.pay_bounty(ctx.tournament, %{
          payouts: [
            %{
              entry_id: ctx.killer_entry.id,
              victim_entry_id: ctx.victim_entry.id,
              seat: 1,
              amount: 200
            }
          ],
          increments: [%{entry_id: ctx.killer_entry.id, amount: 200}],
          refunds: []
        })

      # Прирост собственной головы убийцы (`entry.bounty`, 600 — см. тест
      # выше) — это не то, что он уже получил. Заработано — только
      # денежная часть, выплаченная сразу: 200.
      assert Tournaments.bounty_earned(ctx.killer.id, :play_money, ctx.tournament.id) == 200

      # Жертва никого не убивала — её заработок нулевой, даже если у неё
      # была своя голова.
      assert Tournaments.bounty_earned(ctx.victim.id, :play_money, ctx.tournament.id) == 0
    end

    test "заработанное баунти суммирует несколько голов подряд", ctx do
      third = user_fixture()
      {:ok, third_entry} = Tournaments.register(ctx.tournament.id, third.id)

      :ok =
        Tournaments.pay_bounty(ctx.tournament, %{
          payouts: [
            %{
              entry_id: ctx.killer_entry.id,
              victim_entry_id: ctx.victim_entry.id,
              seat: 1,
              amount: 200
            }
          ],
          increments: [%{entry_id: ctx.killer_entry.id, amount: 200}],
          refunds: []
        })

      :ok =
        Tournaments.pay_bounty(ctx.tournament, %{
          payouts: [
            %{
              entry_id: ctx.killer_entry.id,
              victim_entry_id: third_entry.id,
              seat: 1,
              amount: 200
            }
          ],
          increments: [%{entry_id: ctx.killer_entry.id, amount: 200}],
          refunds: []
        })

      assert Tournaments.bounty_earned(ctx.killer.id, :play_money, ctx.tournament.id) == 400
    end

    test "двойной нокаут в одной раздаче не роняет выплату", ctx do
      third = user_fixture()
      {:ok, third_entry} = Tournaments.register(ctx.tournament.id, third.id)

      # Один убийца, две головы одной раздачей: два прироста на один и
      # тот же вход. Имя шага в `Multi` уникально, поэтому приросты
      # обязаны сложиться, а не встать двумя одноимёнными шагами.
      :ok =
        Tournaments.pay_bounty(ctx.tournament, %{
          payouts: [
            %{
              entry_id: ctx.killer_entry.id,
              victim_entry_id: ctx.victim_entry.id,
              seat: 1,
              amount: 200
            },
            %{
              entry_id: ctx.killer_entry.id,
              victim_entry_id: third_entry.id,
              seat: 1,
              amount: 200
            }
          ],
          increments: [
            %{entry_id: ctx.killer_entry.id, amount: 200},
            %{entry_id: ctx.killer_entry.id, amount: 200}
          ],
          refunds: []
        })

      assert Tournaments.bounty_earned(ctx.killer.id, :play_money, ctx.tournament.id) == 400

      # Голова убийцы выросла на оба прироста, а не на один из них.
      killer_entry = Repo.get!(Entry, ctx.killer_entry.id)
      assert killer_entry.bounty == 400 + 400
    end

    test "заработанное баунти не путает турниры одного игрока", ctx do
      other_setting = setting_fixture(%{bounty_part: 400})
      other_tournament = tournament_fixture(other_setting)
      {:ok, other_entry} = Tournaments.register(other_tournament.id, ctx.killer.id)
      {:ok, other_victim} = Tournaments.register(other_tournament.id, ctx.victim.id)

      :ok =
        Tournaments.pay_bounty(ctx.tournament, %{
          payouts: [
            %{
              entry_id: ctx.killer_entry.id,
              victim_entry_id: ctx.victim_entry.id,
              seat: 1,
              amount: 200
            }
          ],
          increments: [%{entry_id: ctx.killer_entry.id, amount: 200}],
          refunds: []
        })

      :ok =
        Tournaments.pay_bounty(other_tournament, %{
          payouts: [
            %{entry_id: other_entry.id, victim_entry_id: other_victim.id, seat: 1, amount: 200}
          ],
          increments: [%{entry_id: other_entry.id, amount: 200}],
          refunds: []
        })

      assert Tournaments.bounty_earned(ctx.killer.id, :play_money, ctx.tournament.id) == 200
      assert Tournaments.bounty_earned(ctx.killer.id, :play_money, other_tournament.id) == 200
    end

    test "голова жертвы обнуляется и помечается выплаченной", ctx do
      :ok =
        Tournaments.pay_bounty(ctx.tournament, %{
          payouts: [
            %{
              entry_id: ctx.killer_entry.id,
              victim_entry_id: ctx.victim_entry.id,
              seat: 1,
              amount: 400
            }
          ],
          increments: [],
          refunds: []
        })

      victim_entry = Repo.get!(Entry, ctx.victim_entry.id)

      assert victim_entry.bounty == 0
      assert victim_entry.bounty_paid == 400
    end

    test "голова конкретного входа выплачивается ровно один раз", ctx do
      payload = %{
        payouts: [
          %{
            entry_id: ctx.killer_entry.id,
            victim_entry_id: ctx.victim_entry.id,
            seat: 1,
            amount: 400
          }
        ],
        increments: [],
        refunds: []
      }

      :ok = Tournaments.pay_bounty(ctx.tournament, payload)
      after_first = balance(ctx.killer)

      # Повтор гасит UNIQUE на `idempotency_key`, а не проверка в коде.
      :ok = Tournaments.pay_bounty(ctx.tournament, payload)

      assert balance(ctx.killer) == after_first
    end

    test "вылет не в раздаче возвращает голову владельцу", ctx do
      before = balance(ctx.victim)

      :ok =
        Tournaments.pay_bounty(ctx.tournament, %{
          payouts: [],
          increments: [],
          refunds: [%{entry_id: ctx.victim_entry.id, amount: 400}]
        })

      assert balance(ctx.victim) == before + 400
    end
  end

  describe "снапшот рассадки" do
    test "пишется и перечитывается" do
      setting = setting_fixture()
      tournament = tournament_fixture(setting)

      seats = [%{"table" => 1, "seat" => 3, "entry_id" => "e1", "stack" => 5000}]

      assert {:ok, _snapshot} =
               Tournaments.save_snapshot(tournament.id, %{level: 2, hands_played: 7, seats: seats})

      assert {:ok, loaded} = Tournaments.get_snapshot(tournament.id)
      assert loaded.level == 2
      assert loaded.seats == seats
    end

    test "переписывается, а не копится" do
      setting = setting_fixture()
      tournament = tournament_fixture(setting)

      {:ok, _first} = Tournaments.save_snapshot(tournament.id, %{level: 1, seats: []})
      {:ok, _second} = Tournaments.save_snapshot(tournament.id, %{level: 5, seats: []})

      {:ok, loaded} = Tournaments.get_snapshot(tournament.id)

      assert loaded.level == 5
    end
  end
end
