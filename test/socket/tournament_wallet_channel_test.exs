defmodule Socket.Channels.TournamentWalletChannelTest do
  @moduledoc """
  Турнирные деньги на пути до клиента — насквозь, через настоящий сокет.

  Канала турниров ещё нет, но деньги турнира уже доезжают до игрока: все
  восемь новых типов записей журнала уходят в топик `wallet:<user_id>`
  тем же событием, что бай-ин за кэш-столом. Значит, ровно этот путь и
  можно проверить целиком: регистрация в ядре → запись в ledger → PubSub
  → push игроку → JSON на проводе.

  Что здесь ищется:

    * событие вообще доезжает — контекст турнира зовёт `Wallet.publish/2`
      **после** коммита, и забыть его в одной из восьми веток легко;
    * баланс в событии совпадает с базой, а не отстаёт от неё;
    * payload сериализуется в JSON — новые типы это атомы, и любой из них
      мог бы не пережить кодирование;
    * чужие деньги в чужой топик не уходят.
  """

  use Socket.ChannelCase, async: false

  import BlockPoker.AccountsFixtures
  import BlockPoker.TournamentsFixtures

  alias BlockPoker.{Tournaments, Wallet}
  alias Socket.UserSocket

  defp connect_wallet(user) do
    {:ok, %{token: token}} = BlockPoker.Accounts.start_session(user)
    {:ok, socket} = connect(UserSocket, %{"token" => token})
    subscribe_and_join(socket, "wallet:#{user.id}", %{})
  end

  defp balance(user) do
    {:ok, wallet} = Wallet.get_wallet(user.id, :play_money)
    wallet.amount
  end

  # Собирает все пришедшие события о движении денег: одна регистрация
  # порождает два — взнос и комиссию, — и порядок между ними не задан.
  defp drain_entries(acc \\ []) do
    receive do
      %Phoenix.Socket.Message{event: "wallet_entry", payload: payload} ->
        drain_entries([payload | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end

  setup do
    setting = setting_fixture()

    %{setting: setting, tournament: tournament_fixture(setting), user: user_fixture()}
  end

  describe "регистрация" do
    test "взнос и комиссия доезжают до клиента двумя событиями", ctx do
      {:ok, _reply, _channel} = connect_wallet(ctx.user)

      {:ok, _entry} = Tournaments.register(ctx.tournament.id, ctx.user.id)

      types = drain_entries() |> Enum.map(& &1.entry.type) |> Enum.sort()

      assert types == [:tournament_entry, :tournament_fee]
    end

    test "суммы приходят знаковыми: списание отрицательно", ctx do
      {:ok, _reply, _channel} = connect_wallet(ctx.user)

      {:ok, _entry} = Tournaments.register(ctx.tournament.id, ctx.user.id)

      amounts = drain_entries() |> Enum.map(& &1.entry.amount) |> Enum.sort()

      assert amounts == [-1000, -100]
    end

    test "баланс в последнем событии совпадает с базой", ctx do
      {:ok, _reply, _channel} = connect_wallet(ctx.user)

      {:ok, _entry} = Tournaments.register(ctx.tournament.id, ctx.user.id)

      # Событие несёт текущий баланс кошелька, а не `balance_after`
      # записи: при идемпотентном повторе тот давно не актуален.
      assert %{amount: amount} = List.last(drain_entries())
      assert amount == balance(ctx.user)
    end

    test "payload переживает кодирование в JSON", ctx do
      {:ok, _reply, _channel} = connect_wallet(ctx.user)

      {:ok, _entry} = Tournaments.register(ctx.tournament.id, ctx.user.id)

      for payload <- drain_entries() do
        assert {:ok, json} = Jason.encode(payload)
        assert {:ok, decoded} = Jason.decode(json)

        # Тип уходит на провод строкой: клиент ветвится по ней, и новый
        # турнирный тип обязан быть ей представим.
        assert decoded["entry"]["type"] in ["tournament_entry", "tournament_fee"]
      end
    end

    test "фриролл событий не порождает: списывать нечего" do
      setting = setting_fixture(%{buy_in: 0, entry_fee: 0})
      tournament = tournament_fixture(setting)
      user = user_fixture()

      {:ok, _reply, _channel} = connect_wallet(user)

      {:ok, _entry} = Tournaments.register(tournament.id, user.id)

      assert drain_entries() == []
    end

    test "неудачная регистрация не шлёт ничего" do
      setting = setting_fixture(%{buy_in: 100_000})
      tournament = tournament_fixture(setting)
      user = user_fixture()

      {:ok, _reply, _channel} = connect_wallet(user)

      assert {:error, :insufficient_funds} = Tournaments.register(tournament.id, user.id)
      assert drain_entries() == []
    end
  end

  describe "возвраты" do
    test "разрегистрация возвращает деньги одним событием", ctx do
      {:ok, _reply, _channel} = connect_wallet(ctx.user)
      {:ok, _entry} = Tournaments.register(ctx.tournament.id, ctx.user.id)
      _spent = drain_entries()

      :ok = Tournaments.unregister(ctx.tournament.id, ctx.user.id)

      assert [%{entry: %{type: :tournament_refund, amount: 1100}}] = drain_entries()
    end

    test "отмена турнира доезжает до каждого участника" do
      setting = setting_fixture(%{min_players: 3})
      tournament = tournament_fixture(setting)
      one = user_fixture()
      two = user_fixture()

      {:ok, _r1, _c1} = connect_wallet(one)
      {:ok, _entry_one} = Tournaments.register(tournament.id, one.id)
      {:ok, _entry_two} = Tournaments.register(tournament.id, two.id)
      _spent = drain_entries()

      {:ok, 2} = Tournaments.cancel(tournament.id)

      # Подписан только первый — второму возврат тоже сделан, но в этот
      # сокет он не приходит.
      assert [%{entry: %{type: :tournament_refund}}] = drain_entries()
    end
  end

  describe "призы и головы" do
    test "приз за место доезжает записью tournament_prize", ctx do
      {:ok, first} = Tournaments.register(ctx.tournament.id, ctx.user.id)
      {:ok, _second} = Tournaments.register(ctx.tournament.id, user_fixture().id)

      {:ok, tournament} = Tournaments.get_tournament(ctx.tournament.id)
      {:ok, tournament} = Tournaments.close_late_reg(tournament)

      {:ok, _reply, _channel} = connect_wallet(ctx.user)

      {:ok, _payouts} = Tournaments.settle(tournament, [%{entry_id: first.id, place: 1}])

      assert [%{entry: %{type: :tournament_prize, amount: 1300}}] = drain_entries()
    end

    test "голова доезжает записью tournament_bounty сразу после раздачи" do
      setting = setting_fixture(%{bounty_part: 400})
      tournament = tournament_fixture(setting)
      killer = user_fixture()
      victim = user_fixture()

      {:ok, killer_entry} = Tournaments.register(tournament.id, killer.id)
      {:ok, victim_entry} = Tournaments.register(tournament.id, victim.id)
      {:ok, tournament} = Tournaments.get_tournament(tournament.id)

      {:ok, _reply, _channel} = connect_wallet(killer)

      :ok =
        Tournaments.pay_bounty(tournament, %{
          payouts: [
            %{
              entry_id: killer_entry.id,
              victim_entry_id: victim_entry.id,
              seat: 1,
              amount: 200
            }
          ],
          increments: [%{entry_id: killer_entry.id, amount: 200}],
          refunds: []
        })

      assert [%{entry: %{type: :tournament_bounty, amount: 200}}] = drain_entries()
    end
  end

  describe "перезапрос баланса" do
    test "после турнирного списания отдаёт свежую цифру", ctx do
      {:ok, _reply, channel} = connect_wallet(ctx.user)

      {:ok, _entry} = Tournaments.register(ctx.tournament.id, ctx.user.id)
      _spent = drain_entries()

      ref = push(channel, "balance", %{})
      assert_reply ref, :ok, %{wallets: wallets}

      assert Enum.find(wallets, &(&1.type == :play_money)).amount == balance(ctx.user)
    end
  end

  describe "соседство с живыми каналами" do
    # Турнир рассылает свои факты в собственные топики, но подписки живут
    # в одном процессе-сокете. Канал без catch-all в `handle_info/2` упал
    # бы от чужого сообщения — и вместе с ним разорвалось бы соединение,
    # в котором игрок сидел за столом.
    test "кошелёк переживает подписку на турнирный топик", ctx do
      {:ok, _reply, channel} = connect_wallet(ctx.user)

      # Подписываемся руками на топик турнира: так сделает канал турнира,
      # когда появится, — и события пойдут в тот же процесс.
      :ok = Phoenix.PubSub.subscribe(BlockPoker.PubSub, Tournaments.topic(ctx.tournament.id))

      {:ok, _entry} = Tournaments.register(ctx.tournament.id, ctx.user.id)

      ref = push(channel, "balance", %{})
      assert_reply ref, :ok, _snapshot
      assert Process.alive?(channel.channel_pid)
    end
  end

  describe "чужие деньги" do
    test "турнирные события соседа в мой топик не приходят", ctx do
      stranger = user_fixture()

      {:ok, _reply, _channel} = connect_wallet(ctx.user)

      {:ok, _entry} = Tournaments.register(ctx.tournament.id, stranger.id)

      assert drain_entries() == []
    end
  end
end
