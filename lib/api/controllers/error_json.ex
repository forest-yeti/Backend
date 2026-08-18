defmodule Api.ErrorJSON do
  @moduledoc """
  Рендер ошибок HTTP-слоя. Коды ошибок домена приходят из `BlockPoker.ErrorCode`.
  """

  alias BlockPoker.ErrorCode

  def error(%{code: code} = assigns) do
    %{code: Atom.to_string(code), message: ErrorCode.message(code)}
    |> maybe_put_errors(assigns[:errors])
  end

  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end

  defp maybe_put_errors(payload, nil), do: payload
  defp maybe_put_errors(payload, errors), do: Map.put(payload, :errors, errors)
end
