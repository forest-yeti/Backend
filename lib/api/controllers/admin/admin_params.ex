defmodule Api.Admin.AdminParams do
  @moduledoc """
  Разбор параметров ручек панели.

  Транспортная работа и ничего кроме: поле есть, тип верный, число в
  границах, валюта — из списка. Что означает «достаточно ли денег»,
  «можно ли банить» и как курсор превращается в условие выборки — не
  здесь, а в `BlockPoker.Admin` (§9 задачи 8).

  Курсор ездит одной непрозрачной строкой по той же причине, что и в
  истории: клиенту не следует его собирать — он возвращает то, что отдал
  сервер.
  """

  alias BlockPoker.Admin
  alias BlockPoker.Admin.AdminAudit

  @currencies ~w(main play_money)
  @statuses ~w(active blocked)
  @roles ~w(default admin)
  @sorts ~w(registered_at name balance)
  @subject_types ~w(user room tournament wallet game_setting)

  @doc "Параметры страницы списка пользователей."
  @spec users(map()) :: {:ok, map()} | {:error, :validation_failed}
  def users(params) do
    with {:ok, limit} <- limit(params),
         {:ok, cursor} <- cursor(params),
         {:ok, status} <- enum(params["status"], @statuses),
         {:ok, role} <- enum(params["role"], @roles),
         {:ok, sort} <- enum(params["sort"], @sorts) do
      {:ok,
       %{
         limit: limit,
         cursor: cursor,
         q: params["q"],
         status: status,
         role: role,
         sort: sort,
         verify: params["verify"] in [true, "true", "1"]
       }}
    end
  end

  @doc "Параметры выписки по кошелькам. Курсор здесь — `seq` журнала."
  @spec ledger(map()) :: {:ok, map()} | {:error, :validation_failed}
  def ledger(params) do
    with {:ok, limit} <- limit(params),
         {:ok, currency} <- enum(params["currency"], @currencies),
         {:ok, cursor} <- seq(params["cursor"]) do
      {:ok, %{limit: limit, currency: currency, cursor: cursor}}
    end
  end

  @doc "Параметры страницы журнала действий."
  @spec audit(map()) :: {:ok, map()} | {:error, :validation_failed}
  def audit(params) do
    with {:ok, limit} <- limit(params),
         {:ok, cursor} <- cursor(params),
         {:ok, admin_id} <- uuid(params["admin_id"]),
         {:ok, action} <- enum(params["action"], Enum.map(AdminAudit.actions(), &to_string/1)),
         {:ok, subject_type} <- enum(params["subject_type"], @subject_types) do
      {:ok,
       %{
         limit: limit,
         cursor: cursor,
         admin_id: admin_id,
         action: action,
         subject_type: subject_type,
         subject_id: params["subject_id"]
       }}
    end
  end

  @doc """
  Вид игры для фильтра списка. Отсутствие фильтра — `:all`.

  Разбирает его ядро: «какие бывают режимы» — доменное знание, и второй
  его список в транспорте разошёлся бы с первым (§3 CLAUDE.md).
  """
  @spec kind(term()) :: {:ok, atom()}
  def kind(value), do: {:ok, Admin.game_kind(value)}

  @doc """
  Вид сетки: адрес таблицы, а не фильтр. Разбирает его ядро — «какие
  бывают режимы» доменное знание, и второй его список в транспорте
  разошёлся бы с первым (§3 CLAUDE.md).
  """
  @spec setting_kind(term()) :: {:ok, atom()} | {:error, :validation_failed}
  def setting_kind(value), do: Admin.grid_kind(value)

  @doc """
  Фильтр сетки: показывать живые шаблоны, снятые или всё вместе.
  `archived=all` — это форма запроса, а не доменное понятие, поэтому
  разбирается здесь.
  """
  @spec grid_filter(map()) :: {:ok, keyword()} | {:error, :validation_failed}
  def grid_filter(params) do
    case params["archived"] do
      value when value in [nil, "", "false", false] -> {:ok, [archived: false]}
      value when value in ["true", true] -> {:ok, [archived: true]}
      "all" -> {:ok, [archived: nil]}
      _other -> {:error, :validation_failed}
    end
  end

  @doc """
  Тело денежной операции: валюта, сумма, причина и ключ идемпотентности.

  Границы суммы и длина причины проверяются в ядре; здесь — только форма:
  сумма целая и положительная, ключ есть и не пустой. Float в деньгах
  запрещён (§5 CLAUDE.md).
  """
  @spec money(map()) :: {:ok, map()} | {:error, :validation_failed}
  def money(params) do
    with {:ok, currency} <- required_enum(params["currency"], @currencies),
         {:ok, amount} <- amount(params["amount"]),
         {:ok, idem} <- idempotency_key(params["idempotency_key"]) do
      {:ok,
       %{currency: currency, amount: amount, reason: params["reason"], idempotency_key: idem}}
    end
  end

  @doc """
  Курсор наружу: непрозрачная строка, которую клиент возвращает как есть.

  Base64 не ради секретности — прятать тут нечего, — а ради того, чтобы
  клиент не начал разбирать его на части и полагаться на форму.
  """
  @spec encode_cursor(term()) :: String.t() | nil
  def encode_cursor(nil), do: nil
  def encode_cursor(seq) when is_integer(seq), do: Integer.to_string(seq)

  def encode_cursor({%DateTime{} = at, id}) do
    Base.url_encode64("#{DateTime.to_iso8601(at)}|#{id}", padding: false)
  end

  def encode_cursor({value, id}) do
    Base.url_encode64("#{value}|#{id}", padding: false)
  end

  defp cursor(%{"cursor" => value}) when is_binary(value) and value != "" do
    with {:ok, decoded} <- Base.url_decode64(value, padding: false),
         [head, id] <- String.split(decoded, "|", parts: 2) do
      {:ok, {decode_head(head), id}}
    else
      _other -> {:error, :validation_failed}
    end
  end

  defp cursor(_params), do: {:ok, nil}

  # Голова курсора — либо момент времени, либо строка сортировки (ник,
  # баланс). Разбирать её по виду страницы значило бы завести здесь знание
  # о сортировках, которое живёт в `Admin.People`.
  defp decode_head(head) do
    case DateTime.from_iso8601(head) do
      {:ok, at, _offset} -> at
      _other -> head
    end
  end

  defp limit(%{"limit" => value}) do
    case parse_int(value) do
      {:ok, limit} when limit > 0 -> {:ok, min(limit, 100)}
      _other -> {:error, :validation_failed}
    end
  end

  defp limit(_params), do: {:ok, 50}

  defp seq(nil), do: {:ok, nil}
  defp seq(""), do: {:ok, nil}

  defp seq(value) do
    case parse_int(value) do
      {:ok, seq} -> {:ok, seq}
      :error -> {:error, :validation_failed}
    end
  end

  defp amount(value) do
    case value do
      amount when is_integer(amount) and amount > 0 -> {:ok, amount}
      _other -> {:error, :validation_failed}
    end
  end

  defp idempotency_key(value) when is_binary(value) and byte_size(value) in 8..120,
    do: {:ok, value}

  defp idempotency_key(_value), do: {:error, :validation_failed}

  defp enum(nil, _allowed), do: {:ok, nil}
  defp enum("", _allowed), do: {:ok, nil}

  defp enum(value, allowed) when is_binary(value) do
    if value in allowed,
      do: {:ok, String.to_existing_atom(value)},
      else: {:error, :validation_failed}
  end

  defp enum(_value, _allowed), do: {:error, :validation_failed}

  defp required_enum(value, allowed) do
    case enum(value, allowed) do
      {:ok, nil} -> {:error, :validation_failed}
      other -> other
    end
  end

  defp uuid(nil), do: {:ok, nil}
  defp uuid(""), do: {:ok, nil}

  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :validation_failed}
    end
  end

  defp uuid(_value), do: {:error, :validation_failed}

  defp parse_int(value) when is_integer(value), do: {:ok, value}

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _other -> :error
    end
  end

  defp parse_int(_value), do: :error
end
