defmodule BlockPoker.Repo.Migrations.CreateHouseWallet do
  use Ecto.Migration

  @moduledoc """
  Касса рума: кошелёк, с которого списывается оверлей.

  Оверлей — доплата рума до гарантии — обязан быть **строкой журнала**,
  а не разницей двух сумм (§11 задачи 7): иначе «сколько мы доложили за
  месяц» приходится выводить вычитанием, и любая ошибка в нём необнаружима.
  А строка журнала требует кошелька: журнал не умеет записей ниоткуда.

  ## Почему кошельку разрешён минус

  Касса — источник денег, а не их хранилище. Её баланс и есть накопленный
  результат рума: комиссии и рейк его поднимают, оверлей опускает, и в
  начале жизни рума он законно отрицателен. Запрет отрицательного баланса
  существует ради игроков — чтобы никто не ушёл в минус незаметно, — и к
  кассе он неприменим.

  Поэтому флаг на кошельке, а не глобальное ослабление проверки: у игрока
  минус по-прежнему невозможен, и стережёт это та же БД.

  ## Почему в учётку нельзя войти

  Касса — не человек. Она заведена пользователем только потому, что
  кошелёк принадлежит пользователю; логин ей не нужен и опасен. Поэтому
  статус `blocked` и пароль — хэш случайных байт, которых никто не видел.
  """

  import Ecto.Query

  # Фиксированный идентификатор: касса одна на рум, и код обращается к ней
  # по имени, а не ищет по признаку.
  @house_id "00000000-0000-0000-0000-0000000000ff"

  def up do
    alter table(:user_wallets) do
      add :system, :boolean, null: false, default: false
    end

    drop constraint(:user_wallets, :user_wallets_amount_non_negative)

    create constraint(:user_wallets, :user_wallets_amount_non_negative,
             # `system` — зарезервированное слово MySQL 8, отсюда бэктики.
             check: "`system` = TRUE OR amount >= 0"
           )

    # Колонка должна существовать физически до вставки: миграция копит
    # изменения схемы и применяет их пачкой, а `insert_all` идёт мимо.
    flush()

    insert_house()
  end

  def down do
    execute "DELETE FROM users WHERE id = UUID_TO_BIN('#{@house_id}')"

    drop constraint(:user_wallets, :user_wallets_amount_non_negative)

    create constraint(:user_wallets, :user_wallets_amount_non_negative, check: "amount >= 0")

    alter table(:user_wallets) do
      remove :system
    end
  end

  defp insert_house do
    now = DateTime.utc_now()

    # Пароль от кассы не существует ни у кого: хэшируются случайные байты,
    # которые тут же выбрасываются.
    hash = Argon2.hash_pwd_salt(Base.encode64(:crypto.strong_rand_bytes(32)))

    repo().insert_all(
      "users",
      [
        %{
          id: uuid(),
          name: "house",
          email: "house@block.poker",
          password_hash: hash,
          status: "blocked",
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing
    )

    for type <- ["main", "play_money"] do
      repo().insert_all(
        "user_wallets",
        [
          %{
            id: Ecto.UUID.bingenerate(),
            user_id: uuid(),
            type: type,
            amount: 0,
            system: true,
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: :nothing
      )
    end
  end

  defp uuid, do: Ecto.UUID.dump!(@house_id)
end
