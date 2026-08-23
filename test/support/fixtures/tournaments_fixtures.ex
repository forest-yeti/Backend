defmodule BlockPoker.TournamentsFixtures do
  @moduledoc """
  Фабрики турниров. Через публичный API контекста, а не прямыми
  `Repo.insert` (§11 CLAUDE.md).

  `valid_*_attrs` собирают минимально осмысленный турнир: два уровня,
  из которых первый разрешает вход, и сетка выплат, покрывающая явку
  без дыр. Меньше сделать нельзя — набор, не проходящий аудит, не
  создастся вовсе, и это правильно.
  """

  alias BlockPoker.Repo
  alias BlockPoker.Tickets
  alias BlockPoker.Tournaments
  alias BlockPoker.Tournaments.Tournament

  def valid_setting_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        name: "Тестовый турнир #{System.unique_integer([:positive])}",
        game_type: :texas_holdem,
        currency: :play_money,
        buy_in: 1000,
        entry_fee: 100,
        starting_stack: 5000,
        table_size: 6,
        min_players: 2,
        max_players: 100,
        registration_opens_before: 3600
      },
      Map.new(overrides)
    )
  end

  @doc """
  Два уровня: на первом можно войти, на втором уже нет.

  Последний уровень обязан закрывать регистрацию, иначе турнир не может
  закончиться, — поэтому минимальная валидная структура именно такая.
  """
  def valid_levels(overrides \\ []) do
    defaults = [
      %{
        level: 1,
        small_blind: 25,
        big_blind: 50,
        ante: 0,
        duration_seconds: 600,
        rebuy_allowed: true,
        addon_allowed: false
      },
      %{
        level: 2,
        small_blind: 50,
        big_blind: 100,
        ante: 10,
        duration_seconds: 600,
        rebuy_allowed: false,
        addon_allowed: false
      }
    ]

    if overrides == [], do: defaults, else: overrides
  end

  @doc "Сетка на два места, покрывающая явку от двух и выше без дыр."
  def valid_payouts(overrides \\ []) do
    defaults = [
      %{entries_from: 2, entries_to: nil, place_from: 1, place_to: 1, share_ppm: 650_000},
      %{entries_from: 2, entries_to: nil, place_from: 2, place_to: 2, share_ppm: 350_000}
    ]

    if overrides == [], do: defaults, else: overrides
  end

  def setting_fixture(overrides \\ %{}, levels \\ [], payouts \\ []) do
    {:ok, setting} =
      Tournaments.create_setting(
        valid_setting_attrs(overrides),
        valid_levels(levels),
        valid_payouts(payouts)
      )

    setting
  end

  @doc """
  Инстанс в состоянии «принимает регистрации».

  Снапшот настроек снимается на этом переходе, поэтому фикстура делает
  ровно то же, что сделал бы планировщик: создаёт анонс и открывает
  регистрацию.
  """
  def tournament_fixture(setting, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          tournament_setting_id: setting.id,
          starts_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          status: :announced
        },
        Map.new(overrides)
      )

    {:ok, tournament} = %Tournament{} |> Tournament.changeset(attrs) |> Repo.insert()
    {:ok, tournament} = Tournaments.open_registration(tournament)

    tournament
  end

  def ticket_fixture(setting, overrides \\ %{}) do
    {:ok, ticket} =
      Tickets.create_ticket(
        Map.merge(
          %{
            tournament_setting_id: setting.id,
            name: "Билет на #{setting.name}",
            face_value: setting.buy_in + setting.entry_fee
          },
          Map.new(overrides)
        )
      )

    ticket
  end

  @doc "Выдаёт игроку экземпляр билета."
  def user_ticket_fixture(ticket, user, overrides \\ %{}) do
    {:ok, %{issued: user_ticket}} =
      Ecto.Multi.new()
      |> Tickets.issue(
        :issued,
        Map.merge(
          %{ticket_id: ticket.id, user_id: user.id, issued_by: "test"},
          Map.new(overrides)
        )
      )
      |> Repo.transaction()

    user_ticket
  end
end
