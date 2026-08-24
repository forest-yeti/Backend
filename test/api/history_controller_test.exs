defmodule Api.HistoryControllerTest do
  @moduledoc """
  Уровень 4: история по HTTP насквозь — запрос, ядро, JSON.

  Ключевые проверки — приватность, и они делаются **на сыром теле
  ответа**, а не на структуре: тест ищет отсутствие данных в том, что
  реально уйдёт клиенту. Проверка на структуре пропустила бы утечку через
  поле, о котором тест не знал.
  """

  use Api.ConnCase, async: true

  import BlockPoker.AccountsFixtures
  import BlockPoker.HistoryFixtures

  alias BlockPoker.Accounts.Tokens
  alias BlockPoker.History

  setup do
    owner = user_fixture()
    opponent = user_fixture()

    {:ok, owner: owner, opponent: opponent}
  end

  describe "GET /api/history/hands/:id" do
    test "чужая раздача — 404, а не 403", %{conn: conn, owner: owner, opponent: opponent} do
      # Существование чужой раздачи не подтверждается.
      rows = holdem_rows(%{users: [opponent.id, user_fixture().id]})
      History.write(rows)

      conn = get(authed(conn, owner), "/api/history/hands/#{rows.hand.id}")

      assert json_response(conn, 404)
    end

    test "мукнувший победитель: карт нет в сыром JSON, при том что в БД они лежат",
         %{conn: conn, owner: owner, opponent: opponent} do
      rows = holdem_rows(%{users: [opponent.id, owner.id]})
      History.write(rows)

      conn = get(authed(conn, owner), "/api/history/hands/#{rows.hand.id}")
      raw = conn.resp_body

      assert conn.status == 200

      # Туз пик — карта победителя, оставшегося закрытым. Своя семёрка
      # бубён на месте: игрок её и так знал.
      refute raw =~ ~s("rank":14)
      assert raw =~ ~s("rank":7)
    end

    test "показанные карты видны всем", %{conn: conn, owner: owner, opponent: opponent} do
      rows = holdem_rows(%{users: [opponent.id, owner.id]})
      shown = %{Enum.at(rows.players, 0) | card_visibility: :showdown}
      History.write(%{rows | players: [shown, Enum.at(rows.players, 1)]})

      conn = get(authed(conn, owner), "/api/history/hands/#{rows.hand.id}")

      assert conn.resp_body =~ ~s("rank":14)
    end

    test "добровольный показ после записи меняет выдачу",
         %{conn: conn, owner: owner, opponent: opponent} do
      rows = holdem_rows(%{users: [opponent.id, owner.id]})
      History.write(rows)

      before = get(authed(conn, owner), "/api/history/hands/#{rows.hand.id}").resp_body
      refute before =~ ~s("rank":14)

      # Второй, маленький апдейт по закрытии окна показа.
      History.mark_voluntary(rows.hand.id, [opponent.id])

      after_reveal = get(authed(conn, owner), "/api/history/hands/#{rows.hand.id}").resp_body
      assert after_reveal =~ ~s("rank":14)
    end

    test "чужие сбросы в OFC не покидают сервер",
         %{conn: conn, owner: owner, opponent: opponent} do
      rows = ofc_rows(%{users: [opponent.id, owner.id]})
      History.write(rows)

      conn = get(authed(conn, owner), "/api/history/hands/#{rows.hand.id}")
      body = json_response(conn, 200)

      by_seat = Map.new(body["players"], &{&1["seat"], &1})

      # За столом сбросы не видит никто, включая соперников, — значит и
      # история не показывает больше, чем показал стол.
      assert by_seat[1]["discards"] == []
      assert by_seat[2]["discards"] != []

      # Сетка была открыта целиком и отдаётся всем: это основное
      # содержимое OFC-истории.
      assert by_seat[1]["box"] != nil
    end

    test "у участников реплея есть ники", %{conn: conn, owner: owner, opponent: opponent} do
      rows = holdem_rows(%{users: [opponent.id, owner.id]})
      History.write(rows)

      conn = get(authed(conn, owner), "/api/history/hands/#{rows.hand.id}")
      body = json_response(conn, 200)

      # Место в разных раздачах занимают разные люди: без ников реплей —
      # таблица номеров мест, и разобрать по ней раздачу нельзя.
      names = Enum.map(body["players"], & &1["name"])
      assert opponent.name in names
      assert owner.name in names
    end
  end

  describe "GET /api/history/hands" do
    test "пагинация курсором не теряет и не дублирует раздачи",
         %{conn: conn, owner: owner, opponent: opponent} do
      # Раздачи с разным временем: курсор — пара `(ended_at, id)`, и
      # именно её достаточно, чтобы страница не поехала.
      ids =
        for offset <- 1..5 do
          rows =
            holdem_rows(%{
              users: [owner.id, opponent.id],
              ended_at: DateTime.add(DateTime.utc_now(), -offset, :second)
            })

          History.write(rows)
          rows.hand.id
        end

      first = json_response(get(authed(conn, owner), "/api/history/hands?limit=2"), 200)
      assert length(first["items"]) == 2
      assert first["cursor"]

      # Между страницами добавилась новая раздача — она не должна ни
      # сдвинуть окно, ни продублировать уже показанное.
      History.write(holdem_rows(%{users: [owner.id, opponent.id]}))

      second =
        json_response(
          get(authed(conn, owner), "/api/history/hands?limit=2&cursor=#{first["cursor"]}"),
          200
        )

      seen = Enum.map(first["items"] ++ second["items"], & &1["id"])
      assert length(Enum.uniq(seen)) == length(seen)
      assert Enum.all?(seen, &(&1 in ids))
    end

    test "чужих карт нет в списке вообще", %{conn: conn, owner: owner, opponent: opponent} do
      History.write(holdem_rows(%{users: [opponent.id, owner.id]}))

      raw = get(authed(conn, owner), "/api/history/hands").resp_body

      # Список короткий, и чужие карты в нём не нужны даже показанные.
      refute raw =~ ~s("rank":14)
    end

    test "без токена — 401", %{conn: conn} do
      assert conn |> get("/api/history/hands") |> json_response(401)
    end
  end

  describe "GET /api/history/stats" do
    test "кэш отдаёт winrate, турнир — нет", %{conn: conn, owner: owner, opponent: opponent} do
      History.write(holdem_rows(%{users: [owner.id, opponent.id]}))

      History.write(
        holdem_rows(%{users: [owner.id, opponent.id], game_mode: :mtt, hand_number: 2})
      )

      body = json_response(get(authed(conn, owner), "/api/history/stats"), 200)

      assert body["modes"]["cash"]["winrate_ppm"]

      # Величина большого блайнда меняется по уровням: средневзвешенный
      # bb/100 был бы ложью, поэтому его нет вовсе.
      refute Map.has_key?(body["modes"]["mtt"], "winrate_ppm")

      # Как и `net` в фишках: складывать его с деньгами нечем.
      refute Map.has_key?(body["modes"]["mtt"], "net")
      assert body["modes"]["mtt"]["hands"] == 1
    end

    test "валюта приходит рядом с числами и не смешивается",
         %{conn: conn, owner: owner, opponent: opponent} do
      History.write(holdem_rows(%{users: [owner.id, opponent.id]}))

      History.write(
        holdem_rows(%{
          users: [owner.id, opponent.id],
          hand_number: 2,
          currency: :play_money
        })
      )

      body = json_response(get(authed(conn, owner), "/api/history/stats"), 200)

      # Центы и игровые фишки — разные шкалы: одной цифрой их не покажешь,
      # и клиент обязан знать, в какой шкале ему пришли суммы.
      assert body["currency"] in ["main", "play_money"]
      assert Enum.sort(body["currencies"]) == ["main", "play_money"]
      assert body["modes"]["cash"]["hands"] == 1

      other = if body["currency"] == "main", do: "play_money", else: "main"

      switched =
        json_response(get(authed(conn, owner), "/api/history/stats?currency=#{other}"), 200)

      assert switched["currency"] == other
      assert switched["modes"]["cash"]["hands"] == 1
    end

    test "неизвестная валюта — 422", %{conn: conn, owner: owner} do
      assert json_response(get(authed(conn, owner), "/api/history/stats?currency=euro"), 422)
    end
  end

  describe "GET /api/history/tournaments/:id" do
    test "турнир с вычищенными раздачами отдаётся с местом и пустым списком",
         %{conn: conn, owner: owner} do
      tournament_id = Ecto.UUID.generate()

      History.write_tournament_result(
        tournament_result(%{user_id: owner.id, tournament_id: tournament_id, place: 3})
      )

      body =
        json_response(get(authed(conn, owner), "/api/history/tournaments/#{tournament_id}"), 200)

      # Иначе половина списка сыгранных турниров стала бы битой: сами
      # результаты хранятся вечно, а раздачи — 90 дней.
      assert [%{"place" => 3}] = body["entries"]
      assert body["hands"] == []
    end

    test "чужой турнир — 404", %{conn: conn, owner: owner, opponent: opponent} do
      tournament_id = Ecto.UUID.generate()

      History.write_tournament_result(
        tournament_result(%{user_id: opponent.id, tournament_id: tournament_id})
      )

      assert authed(conn, owner)
             |> get("/api/history/tournaments/#{tournament_id}")
             |> json_response(404)
    end
  end

  defp authed(conn, user) do
    put_req_header(conn, "authorization", "Bearer " <> Tokens.issue_socket_token(user))
  end
end
