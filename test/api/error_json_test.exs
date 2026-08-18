defmodule Api.ErrorJSONTest do
  use ExUnit.Case, async: true

  test "рендерит 404" do
    assert Api.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "рендерит 500" do
    assert Api.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
