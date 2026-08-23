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
      assert entries_of(tournament) == []
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
      assert Tournaments.collected(reloaded, setting) == 2000
    end

    test "собранное не включает головы" do
      setting = setting_fixture(%{bounty_part: 400})
      tournament = tournament_fixture(setting)

      {:ok, _e1} = Tournaments.register(tournament.id, user_fixture().id)

      {:ok, reloaded} = Tournaments.get_tournament(tournament.id)

      assert Tournaments.collected(reloaded, setting) == 600
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
