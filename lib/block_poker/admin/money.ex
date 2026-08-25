defmodule BlockPoker.Admin.Money do
  @moduledoc """
  Деньги панели: начисление игроку и перевод с его кошелька на кошелёк
  админа.

  Обе операции — один `Ecto.Multi`: запись журнала действий и записи
  журнала операций коммитятся вместе. Не записалось — не произошло
  (§8 задачи 8).

  Перевод, а не списание в никуда: `−игроку / +админу` одной транзакцией,
  поэтому суммарное количество фишек в системе не меняется и инвариант
  «сохранение фишек» продолжает проверяться тестом (§11 CLAUDE.md).

  **Фишки, которые сейчас на столе, не трогаются.** Списывается только то,
  что лежит в кошельке: вмешиваться в состояние `TableServer` посреди
  раздачи ради денежной операции нельзя, а «сколько у игрока в игре»
  панель показывает отдельно — предупреждением, а не участием в сумме.
  """

  alias BlockPoker.Admin.{Audit, Context}
  alias BlockPoker.Repo
  alias BlockPoker.Wallet
  alias Ecto.Multi

  @type currency :: :main | :play_money

  @doc """
  Начисление игроку.

  `idempotency_key` обязателен и приходит от панели (UUID, сгенерированный
  при открытии формы, а не при отправке): повторная отправка той же формы
  — это тот же ключ, и UNIQUE журнала гасит второе начисление.
  """
  @spec credit(Context.t(), Ecto.UUID.t(), currency(), pos_integer(), String.t(), String.t()) ::
          {:ok, map()} | {:error, atom()}
  def credit(%Context{} = ctx, user_id, currency, amount, reason, idem) do
    key = "admin_credit:#{idem}"

    with :ok <- ensure_other(ctx, user_id),
         :ok <- ensure_amount(amount),
         :ok <- ensure_currency(currency),
         {:ok, wallet} <- fetch_wallet(user_id, currency) do
      Multi.new()
      |> Audit.step(:audit, ctx, %{
        action: :credit,
        subject_type: :wallet,
        subject_id: wallet.id,
        amount: amount,
        currency: currency,
        reason: reason,
        meta: %{user_id: user_id, before: wallet.amount, after: wallet.amount + amount}
      })
      |> Wallet.record_entry(:entry, fn changes ->
        %{
          wallet_id: wallet.id,
          amount: amount,
          type: :admin_credit,
          ref_id: changes.audit.id,
          idempotency_key: key
        }
      end)
      |> ensure_fresh(:entry)
      |> Repo.transaction()
      |> case do
        {:ok, %{entry: entry, audit: audit}} ->
          Wallet.publish(user_id, entry)
          {:ok, %{audit_id: audit.id, balance: entry.balance_after, currency: currency}}

        {:error, :idempotent, :repeated, _changes} ->
          repeated(key, currency)

        {:error, step, reason, _changes} ->
          {:error, failure(step, reason)}
      end
    end
  end

  @doc """
  Перевод с кошелька игрока на кошелёк админа: две записи журнала с общим
  `ref_id`, `−amount` у игрока и `+amount` у админа, в одной валюте.
  """
  @spec take_to_admin(
          Context.t(),
          Ecto.UUID.t(),
          currency(),
          pos_integer(),
          String.t(),
          String.t()
        ) :: {:ok, map()} | {:error, atom()}
  def take_to_admin(%Context{} = ctx, user_id, currency, amount, reason, idem) do
    key = "admin_transfer:#{idem}"

    with :ok <- ensure_other(ctx, user_id),
         :ok <- ensure_amount(amount),
         :ok <- ensure_currency(currency),
         {:ok, from} <- fetch_wallet(user_id, currency),
         {:ok, to} <- fetch_wallet(ctx.admin_id, currency),
         :ok <- ensure_enough(from, amount) do
      Multi.new()
      |> Audit.step(:audit, ctx, %{
        action: :debit_to_admin,
        subject_type: :wallet,
        subject_id: from.id,
        amount: amount,
        currency: currency,
        reason: reason,
        meta: %{user_id: user_id, before: from.amount, after: from.amount - amount}
      })
      |> Wallet.record_entry(:from, fn changes ->
        %{
          wallet_id: from.id,
          amount: -amount,
          type: :admin_transfer,
          ref_id: changes.audit.id,
          idempotency_key: key <> ":from"
        }
      end)
      |> Wallet.record_entry(:to, fn changes ->
        %{
          wallet_id: to.id,
          amount: amount,
          type: :admin_transfer,
          ref_id: changes.audit.id,
          idempotency_key: key <> ":to"
        }
      end)
      |> ensure_fresh(:from)
      |> Repo.transaction()
      |> case do
        {:ok, %{from: from_entry, to: to_entry, audit: audit}} ->
          Wallet.publish(user_id, from_entry)
          Wallet.publish(ctx.admin_id, to_entry)

          {:ok,
           %{
             audit_id: audit.id,
             currency: currency,
             player_balance: from_entry.balance_after,
             admin_balance: to_entry.balance_after
           }}

        {:error, :idempotent, :repeated, _changes} ->
          repeated(key <> ":from", currency)

        {:error, step, reason, _changes} ->
          {:error, failure(step, reason)}
      end
    end
  end

  # Начислить и списать себе через панель нельзя: собственный кошелёк
  # правится `mix`-задачей, где это видно в истории команд (§7 задачи 8).
  defp ensure_other(%Context{admin_id: admin_id}, user_id) do
    if admin_id == user_id, do: {:error, :admin_self_target}, else: :ok
  end

  defp ensure_amount(amount) when is_integer(amount) and amount > 0, do: :ok
  defp ensure_amount(_amount), do: {:error, :admin_amount_invalid}

  defp ensure_currency(currency) do
    if currency in [:main, :play_money], do: :ok, else: {:error, :admin_amount_invalid}
  end

  # Повтор ловит **база**, а не предварительный `SELECT`: только UNIQUE по
  # `idempotency_key` даёт гарантию при конкурентных ретраях, и
  # `record_entry/3` при дубле молча возвращает уже существующую запись.
  #
  # Отличить её от только что вставленной можно по `ref_id`: у свежей он
  # указывает на запись аудита этой самой транзакции. Если нет — операция
  # уже выполнялась, и вся транзакция откатывается, чтобы в `admin_audit`
  # не легла вторая запись о действии, которого не было.
  defp ensure_fresh(multi, step) do
    Multi.run(multi, :idempotent, fn _repo, changes ->
      if changes[step].ref_id == changes.audit.id,
        do: {:ok, :fresh},
        else: {:error, :repeated}
    end)
  end

  # Повторная отправка той же формы — успех, а не ошибка: операция уже
  # выполнена, и панель обязана увидеть её результат, а не отказ.
  defp repeated(key, currency) do
    case Wallet.get_entry_by_key(key) do
      nil -> {:error, :validation_failed}
      entry -> {:ok, %{repeated: true, balance: entry.balance_after, currency: currency}}
    end
  end

  # Явная проверка поверх `check_constraint`: игрок должен получить
  # понятную ошибку, а не отказ базы.
  defp ensure_enough(wallet, amount) do
    if wallet.amount >= amount, do: :ok, else: {:error, :admin_insufficient_funds}
  end

  defp fetch_wallet(user_id, currency) do
    case Wallet.get_wallet(user_id, currency) do
      {:ok, wallet} -> {:ok, wallet}
      {:error, :not_found} -> {:error, :wallet_not_found}
    end
  end

  defp failure(:audit, _reason), do: :admin_reason_required
  defp failure(_step, :insufficient_funds), do: :admin_insufficient_funds
  defp failure(_step, :not_found), do: :wallet_not_found
  defp failure(_step, _reason), do: :validation_failed
end
