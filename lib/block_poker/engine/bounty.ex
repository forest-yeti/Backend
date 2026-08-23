defmodule BlockPoker.Engine.Bounty do
  @moduledoc """
  Головы баунти-турнира: кто сколько получил деньгами и на сколько
  выросла его собственная голова.

  Чистый модуль: выбитые, их головы, победители банков и правила деления
  на входе — выплаты и приросты на выходе. Ни кошелька, ни процессов.

  ## Откуда берётся голова

  Взнос баунти-турнира делится на три части, и это единственное место,
  где деление вообще происходит:

      цена входа = buy_in + entry_fee
      buy_in     = призовая часть + bounty_part

  `bounty_part` идёт **не в призовой фонд**, а на голову самого игрока.
  Отсюда следствие, о котором оператор обязан знать: в баунти-турнире
  фонд за места меньше при той же цене входа, и гарантия относится
  только к фонду — головы игроки платят друг другу, и гарантировать их
  рум не может.

  ## PKO

  Половина выбитой головы (`split_ppm`) уходит убийце деньгами, остаток —
  на его собственную голову:

      убийце деньгами = B.bounty × split_ppm / 1_000_000
      на голову убийцы = B.bounty − убийце деньгами

  Остаток от деления попадает **на голову**, а не в карман, — по
  построению, потому что денежная часть округляется вниз. Это не
  косметика: голова остаётся в турнире и рано или поздно будет выплачена
  целиком, а лишняя копейка в кармане создала бы расхождение
  «сумма голов ≠ собранное».

  Обычный фиксированный баунти — тот же код при `progressive?: false`:
  вся голова уходит деньгами, голова убийцы не растёт.

  ## Кто считается убийцей

  Правило одно и оно чистое: **убийца — тот, кто выиграл банк, в котором
  у выбывшего кончились фишки.** Не победитель большего банка и не тот,
  кто выиграл больше всех за раздачу. Разрешение сайд-потов — забота
  вызывающего: сюда приходит уже готовый список победителей **того**
  банка, а модуль решает, как поделить голову между ними.

  Крайние случаи:

    * **сплит-пот** — голова делится поровну, нечётные единицы уходят
      ближайшим к кнопке по часовой стрелке (тот же тайбрейк, что у
      нечётных фишек банка);
    * **несколько выбитых одной раздачей** — каждая голова считается по
      своему банку, убийцы могут быть разными; порядок обработки — по
      стеку на начало раздачи, чтобы результат был детерминирован;
    * **вылет не в раздаче** (исчерпан лимит ре-энтри, дисквалификация) —
      голова не достаётся никому и возвращается владельцу деньгами.
      Голову выигрывают, а не наследуют.

  ## Инвариант

      Σ выплаченных голов + Σ возвратов + Σ текущих голов живых
        = входы × bounty_part

  Он обязан держаться после **каждой** раздачи и проверяется
  property-тестом. Именно он ловит и потерянный остаток от деления,
  и двойную выплату, и невыплаченную голову победителя.
  """

  @ppm 1_000_000

  @typedoc "Победитель банка, в котором у выбывшего кончились фишки."
  @type killer :: %{entry_id: term(), seat: pos_integer()}

  @typedoc """
  Выбитый игрок. `killers: []` означает вылет не в раздаче — голова
  возвращается владельцу. `stack_before` задаёт порядок обработки при
  нескольких выбитых одной раздачей.
  """
  @type victim :: %{
          entry_id: term(),
          seat: pos_integer(),
          bounty: non_neg_integer(),
          stack_before: non_neg_integer(),
          killers: [killer()]
        }

  @typedoc """
  Правила деления. `split_ppm` значим только при `progressive?: true`:
  фиксированный баунти отдаёт голову целиком и деления не знает.
  """
  @type rules :: %{progressive?: boolean(), split_ppm: non_neg_integer()}

  @typedoc "Расположение стола — нужно только для тайбрейка нечётных единиц."
  @type table :: %{button_seat: pos_integer(), table_size: pos_integer()}

  @typedoc """
  Результат расчёта.

    * `payouts` — деньги убийцам, каждая запись помечена входом жертвы:
      ключ идемпотентности строится по нему, и голова конкретного входа
      выплачивается ровно один раз;
    * `increments` — прирост собственных голов убийц; в ledger **не
      пишется**, это обязательство турнира, а не деньги в кошельке;
    * `refunds` — головы, не доставшиеся никому.
  """
  @type result :: %{
          payouts: [
            %{
              entry_id: term(),
              victim_entry_id: term(),
              seat: pos_integer(),
              amount: pos_integer()
            }
          ],
          increments: [%{entry_id: term(), amount: pos_integer()}],
          refunds: [%{entry_id: term(), amount: pos_integer()}]
        }

  @doc "Знаменатель шкалы деления: `split_ppm / ppm()` — доля убийце деньгами."
  @spec ppm() :: pos_integer()
  def ppm, do: @ppm

  @doc """
  Стартовая цена головы входа. Отдельная функция, потому что она же
  применяется к ре-энтри: `rebuy_cost` делится в той же пропорции, и
  повторный вход несёт новую голову того же номинала.

  Иначе за столом оказались бы игроки с головой и без, и колл против них
  стоил бы разного при одинаковом стеке.
  """
  @spec initial(non_neg_integer()) :: non_neg_integer()
  def initial(bounty_part) when bounty_part >= 0, do: bounty_part

  @doc """
  Призовая часть взноса: то, что идёт в `collected` и дальше в фонд.

  Голова из фонда вычитается, комиссия в него не входит вовсе.
  """
  @spec prize_part(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def prize_part(buy_in, bounty_part) when buy_in >= bounty_part, do: buy_in - bounty_part

  @doc """
  Разбирает раздачу: кому сколько денег и на сколько выросли головы.

  Выбитые обрабатываются по убыванию стека на начало раздачи — тем же
  порядком, каким им присваиваются места. Порядок важен не для сумм
  (головы независимы), а для воспроизводимости: список выплат обязан
  быть одинаковым при одинаковом входе.
  """
  @spec settle([victim()], rules(), table()) :: result()
  def settle(victims, rules, table) do
    victims
    |> Enum.sort_by(& &1.stack_before, :desc)
    |> Enum.reduce(%{payouts: [], increments: [], refunds: []}, fn victim, acc ->
      victim |> settle_one(rules, table) |> merge(acc)
    end)
    |> then(fn result ->
      %{
        payouts: Enum.reverse(result.payouts),
        increments: Enum.reverse(result.increments),
        refunds: Enum.reverse(result.refunds)
      }
    end)
  end

  @doc """
  Голова победителя турнира.

  Он забирает её деньгами — иначе `bounty_part` победителя не был бы
  выплачен никому, и инвариант не сошёлся бы. Выплачивается это в той же
  транзакции, что и приз за первое место.
  """
  @spec winner_payout(term(), non_neg_integer()) :: [%{entry_id: term(), amount: pos_integer()}]
  def winner_payout(_entry_id, 0), do: []
  def winner_payout(entry_id, bounty) when bounty > 0, do: [%{entry_id: entry_id, amount: bounty}]

  # --- Одна голова ---------------------------------------------------------

  defp settle_one(%{bounty: 0}, _rules, _table), do: empty()

  # Вылет не в раздаче: банка, в котором кончились фишки, не было вовсе.
  # Голову выигрывают, а не наследуют, поэтому она возвращается владельцу.
  defp settle_one(%{killers: []} = victim, _rules, _table) do
    %{empty() | refunds: [%{entry_id: victim.entry_id, amount: victim.bounty}]}
  end

  defp settle_one(victim, rules, table) do
    cash_total = cash_part(victim.bounty, rules)
    growth_total = victim.bounty - cash_total

    ordered = order_by_button(victim.killers, table)

    cash = share(cash_total, ordered)
    growth = share(growth_total, ordered)

    %{
      payouts:
        for {killer, amount} <- cash, amount > 0 do
          %{
            entry_id: killer.entry_id,
            victim_entry_id: victim.entry_id,
            seat: killer.seat,
            amount: amount
          }
        end,
      increments:
        for(
          {killer, amount} <- growth,
          amount > 0,
          do: %{entry_id: killer.entry_id, amount: amount}
        ),
      refunds: []
    }
  end

  # Фиксированный баунти — частный случай прогрессивного: вся голова
  # уходит деньгами, расти нечему.
  defp cash_part(bounty, %{progressive?: false}), do: bounty

  defp cash_part(bounty, %{progressive?: true, split_ppm: split_ppm}) do
    div(bounty * split_ppm, @ppm)
  end

  # Поровну, а нечётные единицы — по одной ближайшим к кнопке. Тот же
  # тайбрейк, что у нечётных фишек банка: два разных правила для одной
  # ситуации разошлись бы на первом же сплите.
  defp share(0, killers), do: Enum.map(killers, &{&1, 0})

  defp share(total, killers) do
    count = length(killers)
    base = div(total, count)
    odd = total - base * count

    killers
    |> Enum.with_index()
    |> Enum.map(fn {killer, index} ->
      {killer, base + if(index < odd, do: 1, else: 0)}
    end)
  end

  # Ближайший к кнопке по часовой стрелке — тот, у кого меньше шагов от
  # кнопки. Сама кнопка идёт первой: она и есть нулевой шаг.
  defp order_by_button(killers, %{button_seat: button, table_size: size}) do
    Enum.sort_by(killers, fn killer -> Integer.mod(killer.seat - button, size) end)
  end

  defp empty, do: %{payouts: [], increments: [], refunds: []}

  defp merge(one, acc) do
    %{
      payouts: prepend(one.payouts, acc.payouts),
      increments: prepend(one.increments, acc.increments),
      refunds: prepend(one.refunds, acc.refunds)
    }
  end

  defp prepend(items, acc), do: Enum.reduce(items, acc, &[&1 | &2])
end
