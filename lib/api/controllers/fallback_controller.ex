defmodule Api.FallbackController do
  @moduledoc """
  Единая точка перевода доменных ответов в HTTP: код из `BlockPoker.ErrorCode`
  определяет и статус, и текст. Контроллеры сами ошибки не рендерят.
  """

  use Api, :controller

  alias BlockPoker.ErrorCode

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(ErrorCode.http_status(:validation_failed))
    |> put_view(json: Api.ErrorJSON)
    |> render(:error, code: :validation_failed, errors: changeset_errors(changeset))
  end

  def call(conn, {:error, code}) when is_atom(code) do
    code = if ErrorCode.valid?(code), do: code, else: :internal_error

    conn
    |> put_status(ErrorCode.http_status(code))
    |> put_view(json: Api.ErrorJSON)
    |> render(:error, code: code)
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _whole, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
