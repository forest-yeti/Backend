defmodule BlockPoker.Engine.Discipline do
  @moduledoc """
  Что вообще происходит внутри раздачи — третья ось различий между столами
  рядом с видом покера (`Engine.Variant`) и режимом стола.

  Оболочка стола почти не знает про раздачу: `TableServer` умеет её начать,
  передать ей действие, доиграть за отвалившегося, спросить «кончилась ли» и
  «чей ход», забрать результат и отрендерить снапшот. Ровно эти два десятка
  вопросов и собраны здесь — по **фактическому** списку вызовов из
  `table_server.ex`, `room_state.ex` и `table_view.ex`, а не по воображаемому
  идеалу.

  Критерий, по которому behaviour считается верным, тот же, что у варианта:
  новая дисциплина — это один модуль и строка в реестре, и ноль правок в
  оболочке. Проверяется искусственной дисциплиной в `test/support`.

  ## Про необязательные коллбэки

  Механики, которых у дисциплины нет, она не «отключает флагом» — она про
  них молчит, и умолчание отвечает «механики нет». Два прогона, rabbit
  hunting, показатели сессии, добровольный показ карт: холдем их реализует,
  китайский покер — нет, и оболочка ни в одном месте не спрашивает, какая
  перед ней дисциплина.

  Дозирование раздачи по времени оболочка узнаёт из `progress/1`, а не из
  полей раздачи: ветки `:offering` и `:running_out` существуют только для
  той дисциплины, которая их возвращает, и остальные в них не заходят.
  """

  alias BlockPoker.Engine.{Card, HandSetup}

  @typedoc "Раздача. Её внутреннее устройство принадлежит дисциплине и наружу не течёт."
  @type hand :: term()

  @typedoc "Событие раздачи: `{имя, payload}`. Один и тот же факт идёт и в сокет, и в историю."
  @type event :: {atom(), map()}

  @typedoc """
  Место в раздаче глазами оболочки: чьё оно, сколько на нём фишек и сколько
  их было на старте. Больше стол про игрока в раздаче ничего не спрашивает.
  """
  @type player :: %{
          required(:id) => term(),
          required(:stack) => non_neg_integer(),
          required(:total) => non_neg_integer()
        }

  @typedoc """
  Чего раздача ждёт прямо сейчас.

  * `:acting` — хода игрока, стол взводит таймер;
  * `:offering` — ответа на предложение (два прогона), окно со своим таймером;
  * `:running_out` — ничьего хода: стол доводит раздачу по тику;
  * `:finished` — всё, можно рассчитываться.
  """
  @type progress :: :acting | :offering | :running_out | :finished

  @typedoc """
  Кусок снапшота, который рисует дисциплина. Обычные значения уходят в JSON
  как есть; карты помечаются `{:card, c}` и `{:cards, list}`, потому что
  внутри ядра карта — целое число, и превращать её в `%{rank, suit}` обязан
  транспорт, а не раздача.
  """
  @type view :: %{atom() => term()}

  @doc "Идентификатор дисциплины; по нему она достаётся из реестра."
  @callback id() :: atom()

  @doc "Сколько игроков нужно, чтобы раздача вообще состоялась."
  @callback min_players() :: pos_integer()

  @doc "Сколько игроков дисциплина сажает за стол максимум."
  @callback max_players() :: pos_integer()

  @doc "Начало раздачи: расклад мест, источник случайности, опции стола."
  @callback start(HandSetup.t(), rng :: term(), opts :: keyword()) :: {hand(), [event()]}

  @doc "Действие игрока. `seq` — счётчик, который клиент видел; `nil` — ход за игрока."
  @callback act(hand(), seat :: pos_integer(), action :: term(), seq :: non_neg_integer() | nil) ::
              {:ok, hand(), [event()]} | {:error, atom()}

  @doc """
  Время на ход вышло. Дисциплина сама решает, чем ходить за игрока: в холдеме
  это чек-фолд, в раскладке — автоматическое размещение, потому что фолд там
  означает мёртвую руку и минус всем сразу.
  """
  @callback timeout(hand()) :: {:ok, hand(), [event()]} | {:error, atom()}

  @doc "Что игрок может сделать. Единственный источник правды для кнопок клиента."
  @callback legal_actions(hand(), seat :: pos_integer()) :: term()

  @doc "Чей сейчас ход. `nil` — ничьего."
  @callback to_act(hand()) :: pos_integer() | nil

  @doc "Счётчик действий раздачи: по нему стол отвергает устаревшие команды."
  @callback seq(hand()) :: non_neg_integer()

  @doc "Места раздачи. Комната зеркалит из них стеки, пока раздача идёт."
  @callback players(hand()) :: %{pos_integer() => player()}

  @doc "Чего раздача ждёт прямо сейчас."
  @callback progress(hand()) :: progress()

  @doc "Итог раздачи в том виде, в каком его ждёт режим стола по концу раздачи."
  @callback results(hand()) :: term()

  @doc "Публичная часть снапшота: то, что видит за столом каждый."
  @callback public_view(hand()) :: view()

  @doc "Личная часть снапшота владельца места. `nil` — этого места в раздаче нет."
  @callback private_view(hand(), seat :: pos_integer()) :: view() | nil

  @doc """
  Карманные карты по местам — для окна добровольного показа после раздачи.
  Дисциплина без закрытых карт коллбэк не реализует, и окна у неё нет.
  """
  @callback hole_cards(hand()) :: %{pos_integer() => [Card.t()]}

  @doc "Кто уже открылся на вскрытии: таким показывать нечего."
  @callback reveal_decision(hand()) :: %{pos_integer() => :show | :muck}

  @doc "Карты недостающих улиц (rabbit hunting) либо отказ."
  @callback rabbit_runout(hand()) :: {:ok, term()} | {:error, atom()}

  @doc "Что стол показывает про идущее предложение (два прогона). `nil` — предложения нет."
  @callback offer_view(hand()) :: map() | nil

  @doc "Разбор своей руки для окна-калькулятора."
  @callback insight(hand(), seat :: pos_integer()) :: term() | nil

  @doc "Накопитель показателей сессии на эту раздачу. `nil` — дисциплина их не считает."
  @callback stats_new(hand()) :: term() | nil

  @optional_callbacks hole_cards: 1,
                      reveal_decision: 1,
                      rabbit_runout: 1,
                      offer_view: 1,
                      insight: 2,
                      stats_new: 1

  @type t :: module()

  @doc """
  Вызов необязательного коллбэка. Нереализованный отвечает умолчанием —
  «механики нет», и ветвиться по дисциплине оболочке не приходится.
  """
  @spec optional(t(), atom(), [term()], term()) :: term()
  def optional(discipline, fun, args, default) do
    if Code.ensure_loaded?(discipline) and function_exported?(discipline, fun, length(args)) do
      apply(discipline, fun, args)
    else
      default
    end
  end
end
