defmodule Api.HistoryParams do
  @moduledoc """
  Разбор параметров запросов истории.

  Транспортная работа и ничего кроме: поле есть, тип верный, число в
  границах. Что означает `game_mode`, какой лимит страницы разумен и как
  курсор превращается в условие выборки — не здесь, а в `History`
  (§3 CLAUDE.md).

  Курсор ездит одной непрозрачной строкой, а не парой параметров, ровно
  потому, что клиенту не следует его собирать: он берёт то, что отдал
  сервер, и возвращает как есть.
  """

  alias BlockPoker.History.PlayerStatsDaily

  @modes ~w(cash sit_and_go mtt ofc_cash)
  @currencies ~w(main play_money)
  @formats ~w(sit_and_go mtt)

  @doc "Параметры страницы списка раздач."
  @spec list(map()) :: {:ok, map()} | {:error, :validation_failed}
  def list(params) do
    with {:ok, opts} <- period(params),
         {:ok, limit} <- limit(params),
         {:ok, cursor} <- cursor(params),
         {:ok, setting_id} <- uuid(params["setting_id"]) do
      {:ok,
       opts
       |> Map.merge(%{limit: limit, cursor: cursor, setting_id: setting_id})
       |> Map.put(:only_won, params["only_won"] in [true, "true", "1"])}
    end
  end

  @doc "Параметры страницы списка турниров."
  @spec tournaments(map()) :: {:ok, map()} | {:error, :validation_failed}
  def tournaments(params) do
    with {:ok, opts} <- period(params),
         {:ok, limit} <- limit(params),
         {:ok, cursor} <- cursor(params),
         {:ok, formats} <- formats(params["format"]) do
      {:ok, Map.merge(opts, %{limit: limit, cursor: cursor, format: formats})}
    end
  end

  @doc "Период и разрез: общее у сводки, графика и списков."
  @spec period(map()) :: {:ok, map()} | {:error, :validation_failed}
  def period(params) do
    with {:ok, from} <- datetime(params["from"]),
         {:ok, to} <- datetime(params["to"]),
         {:ok, modes} <- modes(params["game_mode"]),
         {:ok, currency} <- currency(params["currency"]),
         {:ok, setting_id} <- uuid(params["setting_id"]) do
      {:ok, %{from: from, to: to, game_mode: modes, currency: currency, setting_id: setting_id}}
    end
  end

  @doc """
  Курсор наружу: непрозрачная строка, которую клиент возвращает как есть.

  Base64 не ради секретности — прятать тут нечего, — а ради того, чтобы
  клиент не начал разбирать его на части и полагаться на форму.
  """
  @spec encode_cursor({DateTime.t(), Ecto.UUID.t()} | nil) :: String.t() | nil
  def encode_cursor(nil), do: nil

  def encode_cursor({at, id}) do
    Base.url_encode64("#{DateTime.to_iso8601(at)}|#{id}", padding: false)
  end

  defp cursor(%{"cursor" => value}) when is_binary(value) and value != "" do
    with {:ok, decoded} <- Base.url_decode64(value, padding: false),
         [at, id] <- String.split(decoded, "|", parts: 2),
         {:ok, at, _offset} <- DateTime.from_iso8601(at),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {:ok, {at, id}}
    else
      _other -> {:error, :validation_failed}
    end
  end

  defp cursor(_params), do: {:ok, nil}

  defp limit(%{"limit" => value}) do
    case parse_int(value) do
      {:ok, limit} when limit > 0 -> {:ok, min(limit, 100)}
      _other -> {:error, :validation_failed}
    end
  end

  defp limit(_params), do: {:ok, 25}

  defp datetime(nil), do: {:ok, nil}
  defp datetime(""), do: {:ok, nil}

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> {:ok, at}
      _error -> {:error, :validation_failed}
    end
  end

  defp datetime(_value), do: {:error, :validation_failed}

  defp modes(nil), do: {:ok, nil}
  defp modes(value) when is_binary(value), do: modes(String.split(value, ","))

  defp modes(values) when is_list(values) do
    if Enum.all?(values, &(&1 in @modes)) do
      {:ok, Enum.map(values, &String.to_existing_atom/1)}
    else
      {:error, :validation_failed}
    end
  end

  defp modes(_value), do: {:error, :validation_failed}

  # Валюта задаёт масштаб сумм, а не оформление: центы и игровые фишки
  # нельзя ни складывать, ни рисовать одной шкалой.
  defp currency(nil), do: {:ok, nil}
  defp currency(""), do: {:ok, nil}

  defp currency(value) when is_binary(value) do
    if value in @currencies do
      {:ok, String.to_existing_atom(value)}
    else
      {:error, :validation_failed}
    end
  end

  defp currency(_value), do: {:error, :validation_failed}

  defp formats(nil), do: {:ok, nil}
  defp formats(value) when is_binary(value), do: formats(String.split(value, ","))

  defp formats(values) when is_list(values) do
    if Enum.all?(values, &(&1 in @formats)) do
      {:ok, Enum.map(values, &String.to_existing_atom/1)}
    else
      {:error, :validation_failed}
    end
  end

  defp formats(_value), do: {:error, :validation_failed}

  # Разрез «без лимита» приходит с провода пустой строкой, а хранится
  # нулевым UUID: `NULL` не может участвовать в первичном ключе агрегата.
  defp uuid(nil), do: {:ok, nil}
  defp uuid(""), do: {:ok, nil}
  defp uuid("none"), do: {:ok, PlayerStatsDaily.no_setting()}

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
