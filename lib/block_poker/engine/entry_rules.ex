defmodule BlockPoker.Engine.EntryRules do
  @moduledoc """
  Вход в игру: ждать большого блайнда или войти немедленно за post (§6 задачи 3).

  Правило существует ради одной вещи: **вход в игру должен стоить столько же,
  сколько круг стоит уже сидящему**. Игрок, которому позволено вступить в любой
  момент, сядет за кнопкой, сыграет лучшие позиции круга бесплатно и встанет
  перед блайндами. Повторяя это, он играет покер, в котором блайнды за него
  платят остальные.

  Модуль чистый: на входе — расклад мест и намерение игрока, на выходе —
  решение. Ни процессов, ни настроек-структур из БД: числа и флаги.
  """

  @type intent :: :wait_bb | :post

  @type decision :: %{
          status: :playing | :waiting_for_bb | :post_required,
          post: non_neg_integer(),
          dead_post: non_neg_integer(),
          can_post: boolean()
        }

  @type params :: %{
          seat: pos_integer(),
          intent: intent(),
          seats_in_game: [pos_integer()],
          button_seat: pos_integer() | nil,
          big_blind_seat: pos_integer() | nil,
          big_blind: pos_integer(),
          heads_up?: boolean(),
          allow_post_blind?: boolean(),
          missed_blinds: non_neg_integer(),
          dodging?: boolean()
        }

  @doc """
  Решение о вступлении.

  `intent` — намерение клиента, а не решение: если правила требуют иного
  (хедз-ап, место на большом блайнде, окно возврата), решает эта функция
  и сообщает результат. Канал ничего из этого не проверяет.
  """
  @spec decide(params()) :: decision()
  def decide(%{} = params) do
    cond do
      # Игра ещё не идёт — ждать нечего, круг начнётся вместе с ним.
      is_nil(params.button_seat) or is_nil(params.big_blind_seat) -> immediate()
      # За двухместным столом ожидание бессмысленно.
      params.heads_up? -> immediate()
      # Сел на большой блайнд или сразу за него: круг и так начинается с него.
      round_starts_here?(params) -> immediate()
      true -> choose(params)
    end
  end

  @doc """
  Может ли игрок прямо сейчас войти за post. Отдаётся клиенту в снапшоте,
  чтобы он нарисовал кнопку, но правом решать клиент не обладает.
  """
  @spec can_post?(params()) :: boolean()
  def can_post?(%{allow_post_blind?: false}), do: false

  def can_post?(%{} = params),
    do: not is_nil(params.button_seat) and not round_starts_here?(params)

  @doc """
  Мёртв ли взнос: игрок входит между кнопкой и большим блайндом, то есть круг
  блайндов в этой раздаче он пропускает. Такой post уходит в банк, но ставкой
  игрока не считается и права чека не даёт.
  """
  @spec dead_post?(pos_integer(), pos_integer(), pos_integer(), [pos_integer()]) :: boolean()
  def dead_post?(seat, button_seat, big_blind_seat, seats) do
    seat in between(button_seat, big_blind_seat, seats)
  end

  defp choose(params) do
    posting? = params.intent == :post and params.allow_post_blind?

    cond do
      posting? -> post_decision(params)
      # Встал и сел обратно внутри окна — право «ждать блайнда» потеряно.
      params.dodging? and params.allow_post_blind? -> post_required(params)
      true -> waiting(params)
    end
  end

  defp post_decision(params) do
    dead? =
      dead_post?(params.seat, params.button_seat, params.big_blind_seat, params.seats_in_game)

    amount = params.big_blind + missed_amount(params)

    %{
      status: :playing,
      post: if(dead?, do: 0, else: amount),
      dead_post: if(dead?, do: amount, else: 0),
      can_post: true
    }
  end

  defp post_required(params) do
    %{status: :post_required, post: 0, dead_post: 0, can_post: can_post?(params)}
  end

  defp waiting(params) do
    %{status: :waiting_for_bb, post: 0, dead_post: 0, can_post: can_post?(params)}
  end

  defp immediate, do: %{status: :playing, post: 0, dead_post: 0, can_post: false}

  # Пропущенные блайнды гасятся тем же взносом: игрок либо доплачивает их
  # и вступает сразу, либо ждёт своего большого блайнда.
  defp missed_amount(%{missed_blinds: missed, big_blind: big_blind}) when missed > 0 do
    big_blind
  end

  defp missed_amount(_params), do: 0

  defp round_starts_here?(params) do
    params.seat == params.big_blind_seat or
      params.seat == next_seat(params.big_blind_seat, params.seats_in_game)
  end

  defp next_seat(_seat, []), do: nil

  defp next_seat(seat, seats) do
    sorted = Enum.sort(seats)
    Enum.find(sorted, fn candidate -> candidate > seat end) || List.first(sorted)
  end

  # Места строго между `from` и `to` по часовой стрелке.
  defp between(from, to, seats) do
    sorted = Enum.sort(seats)

    if from in sorted and to in sorted do
      sorted
      |> Stream.cycle()
      |> Stream.drop_while(&(&1 != from))
      |> Stream.drop(1)
      |> Enum.take_while(&(&1 != to))
    else
      []
    end
  end
end
