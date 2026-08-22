defmodule Socket.Channels.SitAndGoChannelTest do
  @moduledoc """
  Витрина турниров насквозь: фильтр по дисциплине, регистрация и отмена.

  Уровень 4 — путь целиком, с настоящей БД под Sandbox: пул читает шаблоны
  из базы, а взнос списывается из кошелька, и подменять ни то, ни другое
  нельзя (§11 CLAUDE.md).
  """

  use Socket.ChannelCase, async: false

  import BlockPoker.AccountsFixtures
  import BlockPoker.TablesHelpers

  alias BlockPoker.SitAndGoFixtures
  alias BlockPoker.Tables.SitAndGoLobby
  alias BlockPoker.Wallet
  alias Ecto.Adapters.SQL.Sandbox
  alias Socket.UserSocket

  setup do
    ensure_tables!()

    holdem = SitAndGoFixtures.setting_fixture(%{currency: :play_money, max_players: 3})

    short_deck =
      SitAndGoFixtures.setting_fixture(%{
        name: "Short Deck Hyper 3-Max тест",
        game_type: :short_deck,
        currency: :play_money,
        max_players: 3,
        buy_in: 200,
        blind_levels: SitAndGoFixtures.ante_levels()
      })

    pid = start_supervised!({SitAndGoLobby, reload_ms: nil, room_opts: [timers: :manual]})
    Sandbox.allow(BlockPoker.Repo, self(), pid)
    :ok = SitAndGoLobby.reload()

    %{holdem: holdem, short_deck: short_deck}
  end

  defp join_channel(payload \\ %{}) do
    user = user_fixture()
    {:ok, %{token: token}} = BlockPoker.Accounts.start_session(user)
    {:ok, socket} = connect(UserSocket, %{"token" => token})
    {:ok, snapshot, channel} = subscribe_and_join(socket, "sit_n_go", payload)

    %{user: user, channel: channel, snapshot: snapshot}
  end

  defp names(snapshot), do: snapshot.tournaments |> Enum.map(& &1.name) |> Enum.sort()

  describe "витрина" do
    test "join отдаёт шаблоны со структурой и таблицей призов", %{holdem: holdem} do
      %{snapshot: snapshot} = join_channel()

      row = Enum.find(snapshot.tournaments, &(&1.setting_id == holdem.id))

      assert row.buy_in == holdem.buy_in
      assert row.starting_stack == holdem.starting_stack
      assert row.max_players == 3
      assert row.registered == 0
      assert length(row.blind_levels) == 3
      assert length(row.prize_tiers) == 1
    end

    test "множители и уровни приходят с готовыми подписями" do
      %{snapshot: snapshot} = join_channel()

      row = hd(snapshot.tournaments)

      assert hd(row.prize_tiers).label == "X2"
      assert hd(row.blind_levels).label == "10/20"
    end

    test "у Short Deck уровни подписаны как анте: блайндов у него нет", %{
      short_deck: short_deck
    } do
      %{snapshot: snapshot} = join_channel()

      row = Enum.find(snapshot.tournaments, &(&1.setting_id == short_deck.id))

      assert hd(row.blind_levels).label == "анте 10"
      assert hd(row.blind_levels).big_blind == 0
    end

    test "витрина отдаёт золотые цвета стола: по ним режим опознаётся" do
      %{snapshot: snapshot} = join_channel()

      assert %{felt_color: "#9A7A2E", background_color: "#151006"} =
               hd(snapshot.tournaments).visuals
    end

    test "список дисциплин приходит с сервера" do
      %{snapshot: snapshot} = join_channel()

      assert :texas_holdem in snapshot.filters.game_types
      assert :short_deck in snapshot.filters.game_types
    end
  end

  describe "порядок витрины" do
    setup do
      # Игровой стол заводится первым и с меньшим взносом: если бы порядок
      # определялся вставкой или суммой, он оказался бы наверху.
      play = SitAndGoFixtures.setting_fixture(%{currency: :play_money, buy_in: 25})
      main = SitAndGoFixtures.setting_fixture(%{currency: :main, buy_in: 10_000})

      :ok = SitAndGoLobby.reload()

      %{play: play, main: main}
    end

    test "реальные деньги всегда выше игровых", %{main: main} do
      %{snapshot: snapshot} = join_channel()

      currencies = Enum.map(snapshot.tournaments, & &1.currency)

      # Ни один play_money не может стоять выше любого main.
      assert Enum.find_index(currencies, &(&1 == :main)) <
               Enum.find_index(currencies, &(&1 == :play_money))

      assert hd(snapshot.tournaments).setting_id == main.id
    end

    test "внутри валюты порядок идёт по взносу", %{play: play} do
      %{snapshot: snapshot} = join_channel()

      buy_ins =
        snapshot.tournaments
        |> Enum.filter(&(&1.currency == :play_money))
        |> Enum.map(& &1.buy_in)

      assert buy_ins == Enum.sort(buy_ins)
      assert play.buy_in == hd(buy_ins)
    end

    test "фильтр по дисциплине порядка не ломает" do
      %{snapshot: snapshot} = join_channel(%{"game_types" => ["texas_holdem"]})

      currencies = Enum.map(snapshot.tournaments, & &1.currency)

      assert currencies == Enum.sort_by(currencies, &if(&1 == :main, do: 0, else: 1))
    end
  end

  describe "фильтр по дисциплине" do
    test "без фильтра видны все дисциплины" do
      %{snapshot: snapshot} = join_channel()

      assert length(names(snapshot)) == 2
    end

    test "пустой список — это «все», а не «ничего»" do
      # Экран с ничем не отмеченным фильтром обязан показывать весь пул.
      %{snapshot: snapshot} = join_channel(%{"game_types" => []})

      assert length(names(snapshot)) == 2
    end

    test "фильтр сужает выборку до выбранных дисциплин", %{short_deck: short_deck} do
      %{snapshot: snapshot} = join_channel(%{"game_types" => ["short_deck"]})

      assert Enum.map(snapshot.tournaments, & &1.setting_id) == [short_deck.id]
    end

    test "выбрать можно несколько дисциплин сразу" do
      %{snapshot: snapshot} = join_channel(%{"game_types" => ["short_deck", "texas_holdem"]})

      assert length(snapshot.tournaments) == 2
    end

    test "незнакомая дисциплина отбрасывается молча, а не роняет витрину" do
      %{snapshot: snapshot} = join_channel(%{"game_types" => ["omaha", "short_deck"]})

      assert length(snapshot.tournaments) == 1
    end

    test "list переспрашивает витрину с новым фильтром" do
      %{channel: channel} = join_channel()

      ref = push(channel, "list", %{"game_types" => ["short_deck"]})
      assert_reply ref, :ok, snapshot

      assert length(snapshot.tournaments) == 1
    end
  end

  describe "регистрация" do
    test "списывает взнос и сажает игрока в набираемый турнир", %{holdem: holdem} do
      %{channel: channel, user: user} = join_channel()

      {:ok, wallet} = Wallet.get_wallet(user.id, :play_money)
      before = wallet.amount

      ref = push(channel, "register", %{"setting_id" => holdem.id})
      assert_reply ref, :ok, result

      assert result.seat in [1, 2, 3]

      {:ok, wallet} = Wallet.get_wallet(user.id, :play_money)
      assert wallet.amount == before - holdem.buy_in
    end

    test "стек выдаётся турниром, а не выбирается игроком", %{holdem: holdem} do
      %{channel: channel} = join_channel()

      ref = push(channel, "register", %{"setting_id" => holdem.id})
      assert_reply ref, :ok, result

      assert result.stack == holdem.starting_stack
    end

    test "неизвестный шаблон — ошибка, а не пустая регистрация" do
      %{channel: channel} = join_channel()

      ref = push(channel, "register", %{"setting_id" => Ecto.UUID.generate()})
      assert_reply ref, :error, %{code: "not_found"}
    end

    test "кривой payload отвергается формой, до похода в ядро" do
      %{channel: channel} = join_channel()

      ref = push(channel, "register", %{"setting_id" => "не-uuid"})
      assert_reply ref, :error, %{code: "validation_failed"}
    end

    test "витрина рассылает новое число зарегистрированных", %{holdem: holdem} do
      %{channel: channel} = join_channel()

      ref = push(channel, "register", %{"setting_id" => holdem.id})
      assert_reply ref, :ok, _result

      assert_push "sit_n_go_delta", delta
      assert delta.setting_id == holdem.id
      assert delta.registered == 1
    end
  end

  describe "отмена регистрации" do
    test "до старта возвращает взнос в кошелёк", %{holdem: holdem} do
      %{channel: channel, user: user} = join_channel()

      {:ok, wallet} = Wallet.get_wallet(user.id, :play_money)
      before = wallet.amount

      ref = push(channel, "register", %{"setting_id" => holdem.id})
      assert_reply ref, :ok, %{room_id: room_id}

      ref = push(channel, "unregister", %{"room_id" => room_id})
      assert_reply ref, :ok, _result

      {:ok, wallet} = Wallet.get_wallet(user.id, :play_money)
      assert wallet.amount == before
    end

    test "чужая комната отменить регистрацию не даёт" do
      %{channel: channel} = join_channel()

      ref = push(channel, "unregister", %{"room_id" => Ecto.UUID.generate()})
      assert_reply ref, :error, %{code: "not_found"}
    end
  end
end
