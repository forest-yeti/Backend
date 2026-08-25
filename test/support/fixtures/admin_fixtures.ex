defmodule BlockPoker.AdminFixtures do
  @moduledoc """
  Фабрики панели администратора. Всё создаётся через публичный API
  контекста, а не прямыми `Repo.insert` (§11 CLAUDE.md): админ — это
  обычная учётка с ролью, а сессия — результат настоящего входа.
  """

  import BlockPoker.AccountsFixtures

  alias BlockPoker.Accounts
  alias BlockPoker.Admin
  alias BlockPoker.Admin.Context

  @doc "Учётка с ролью администратора."
  def admin_fixture(overrides \\ %{}) do
    user = user_fixture(overrides)
    {:ok, admin} = Accounts.set_role(user, :admin)
    admin
  end

  @doc """
  Настоящий вход в панель: пара токенов и сессия.

  Через `Admin.login/3`, а не вставкой строки, потому что тесты уровня 3
  проверяют в том числе то, что вход пишет запись в журнал.
  """
  def admin_session_fixture(admin \\ nil, meta \\ %{}) do
    admin = admin || admin_fixture()

    {:ok, session} =
      Admin.login(
        admin.email,
        valid_password(),
        Map.merge(%{ip: "127.0.0.1", user_agent: "test"}, meta)
      )

    session
  end

  @doc "Контекст действия: то, что транспорт собирает из `assigns`."
  def admin_ctx(session) do
    %Context{admin_id: session.admin.id, session_id: session.session.id, ip: "127.0.0.1"}
  end

  @doc "Админ, его сессия и готовый контекст — самый частый набор в тестах."
  def admin_with_ctx(overrides \\ %{}) do
    admin = admin_fixture(overrides)
    session = admin_session_fixture(admin)

    %{admin: admin, session: session, ctx: admin_ctx(session)}
  end

  @doc "Ключ идемпотентности денежной операции: панель генерирует его UUID'ом."
  def idempotency_key, do: Ecto.UUID.generate()
end
