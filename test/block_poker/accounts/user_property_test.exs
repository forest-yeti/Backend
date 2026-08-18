defmodule BlockPoker.Accounts.UserPropertyTest do
  @moduledoc """
  Формат ника: changeset принимает ровно то, что описано регуляркой и границами
  длины. БД тут не нужна — предварительная проверка уникальности выключена.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BlockPoker.Accounts.User

  defp changeset(name) do
    User.registration_changeset(
      %User{},
      %{"name" => name, "email" => "a@b.io", "password" => "correct horse"},
      validate_unique: false
    )
  end

  defp name_errors(name), do: Keyword.get_values(changeset(name).errors, :name)

  property "валидный ник принимается" do
    check all(
            name <-
              StreamData.string(Enum.concat([?a..?z, ?A..?Z, ?0..?9, [?_, ?-]]),
                min_length: 3,
                max_length: 25
              )
          ) do
      assert name_errors(name) == []
    end
  end

  property "слишком короткий или слишком длинный ник отвергается" do
    check all(
            name <-
              StreamData.one_of([
                StreamData.string(?a..?z, min_length: 0, max_length: 2),
                StreamData.string(?a..?z, min_length: 26, max_length: 40)
              ])
          ) do
      assert name_errors(name) != []
    end
  end

  property "символы вне [A-Za-z0-9_-] отвергаются" do
    check all(
            prefix <- StreamData.string(?a..?z, min_length: 3, max_length: 10),
            bad <- StreamData.member_of(String.graphemes(" .@!/+*,;:()[]{}?%#игрок"))
          ) do
      assert name_errors(prefix <> bad) != []
    end
  end
end
