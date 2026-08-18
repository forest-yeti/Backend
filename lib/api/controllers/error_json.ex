defmodule Api.ErrorJSON do
  @moduledoc """
  Рендер ошибок HTTP-слоя. Коды ошибок домена приходят из `BlockPoker.ErrorCode`.
  """

  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end
