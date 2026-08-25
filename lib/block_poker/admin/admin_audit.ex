defmodule BlockPoker.Admin.AdminAudit do
  @moduledoc """
  Журнал действий администратора — append-only (§3, §8 задачи 8).

  Разрешён только `INSERT`. Ни `update`, ни `delete` по этой таблице не
  делает никто и никогда: запись, которую можно поправить, ничего не
  доказывает. Поэтому у схемы нет ни `updated_at`, ни changeset'а
  обновления — это стережёт `ArchitectureTest`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BlockPoker.Accounts.User
  alias BlockPoker.Admin.AdminSession

  @type t :: %__MODULE__{}

  @actions [
    :login,
    :login_failed,
    :logout,
    :ban_user,
    :unban_user,
    :credit,
    :debit_to_admin,
    :observe_room_open,
    :observe_room_close,
    :force_close_room,
    :pause_tournament,
    :resume_tournament,
    :cancel_tournament
  ]

  @subject_types [:user, :room, :tournament, :wallet]
  @currencies [:main, :play_money]

  # Действия, у которых причина обязательна: без неё запись бесполезна
  # (§7 задачи 8). Чтение и вход причины не требуют — она в них не значит
  # ничего, кроме лишнего поля в форме.
  @requires_reason [:ban_user, :unban_user, :credit, :debit_to_admin]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "admin_audit" do
    field :action, Ecto.Enum, values: @actions
    field :subject_type, Ecto.Enum, values: @subject_types
    field :subject_id, :string
    field :amount, :integer
    field :currency, Ecto.Enum, values: @currencies
    field :reason, :string
    field :meta, :map
    field :ip, :string

    belongs_to :admin, User
    belongs_to :session, AdminSession

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @spec actions() :: [atom()]
  def actions, do: @actions

  @spec subject_types() :: [atom()]
  def subject_types, do: @subject_types

  @spec requires_reason?(atom()) :: boolean()
  def requires_reason?(action), do: action in @requires_reason

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(audit, attrs) do
    audit
    |> cast(attrs, [
      :admin_id,
      :session_id,
      :action,
      :subject_type,
      :subject_id,
      :amount,
      :currency,
      :reason,
      :meta,
      :ip
    ])
    |> validate_required([:admin_id, :action, :subject_type, :subject_id, :ip])
    |> validate_reason()
    |> validate_length(:subject_id, max: 64)
    |> assoc_constraint(:admin)
  end

  # Причина проверяется здесь, а не в транспорте: правило «без причины
  # операции не было» — доменное, и форма его не решает (§9 задачи 8).
  defp validate_reason(changeset) do
    if requires_reason?(get_field(changeset, :action)) do
      changeset
      |> validate_required([:reason])
      |> validate_length(:reason, min: 3, max: 500)
    else
      validate_length(changeset, :reason, max: 500)
    end
  end
end
