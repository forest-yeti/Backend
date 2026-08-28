defmodule BlockPoker.Admin do
  @moduledoc """
  Контекст панели администратора: единственное, что зовёт транспорт
  `admin/*`.

  **Правило проверки прав.** `admin?` проверяется внутри каждой публичной
  функции этого контекста, а не в плаге и не в канале. Плаг проверяет
  только подпись токена и отвечает на вопрос «кто это»; на вопрос «можно
  ли ему» отвечает контекст (§4 задачи 8). Это делает невозможным вызов
  операции из ядра без проверки роли — в том числе из `iex` и из будущих
  фоновых задач.

  Вход в панель — отдельный токен с отдельной солью, не взаимозаменяемый
  с игровым: утёкший из игрового клиента токен доступа сюда не даёт.

  Ни одна мутирующая операция не выполняется без записи в `admin_audit`,
  и запись идёт **той же транзакцией**: не записалось — не произошло.
  """

  alias BlockPoker.Accounts.User

  alias BlockPoker.Admin.{
    AdminSession,
    Audit,
    Auth,
    Context,
    Games,
    Grids,
    Money,
    Observer,
    People
  }

  alias BlockPoker.Announcements
  alias BlockPoker.Banners
  alias BlockPoker.ClientReleases
  alias BlockPoker.Sounds

  @type ctx :: Context.t()

  # --- аутентификация -------------------------------------------------------

  @spec login(String.t(), String.t(), map()) :: {:ok, map()} | {:error, atom()}
  defdelegate login(email, password, meta), to: Auth

  @spec refresh(String.t(), map()) :: {:ok, map()} | {:error, atom()}
  defdelegate refresh(refresh_token, meta), to: Auth

  @spec logout(Ecto.UUID.t()) :: :ok
  defdelegate logout(session_id), to: Auth

  @spec authorize(String.t()) ::
          {:ok, %{admin: User.t(), session: AdminSession.t()}} | {:error, atom()}
  defdelegate authorize(token), to: Auth

  @doc """
  Жива ли сессия соединения. Сокет спрашивает при каждом `join` и по
  таймеру: access-токен переживает отзыв сессии до конца своего TTL, а
  открытый god-mode отозванному админу — нет.
  """
  @spec session_alive?(ctx()) :: boolean()
  def session_alive?(%Context{session_id: session_id}), do: Auth.session_alive?(session_id)

  @spec sessions(ctx()) :: {:ok, [AdminSession.t()]} | {:error, atom()}
  def sessions(%Context{} = ctx) do
    with {:ok, admin} <- Auth.ensure_admin(ctx.admin_id) do
      {:ok, Auth.list_sessions(admin.id)}
    end
  end

  # --- люди -----------------------------------------------------------------

  @spec list_users(ctx(), map()) :: {:ok, map()} | {:error, atom()}
  def list_users(%Context{} = ctx, params) do
    with :ok <- allowed(ctx), do: {:ok, People.list(params)}
  end

  @spec user_card(ctx(), Ecto.UUID.t()) :: {:ok, map()} | {:error, atom()}
  def user_card(%Context{} = ctx, user_id) do
    with :ok <- allowed(ctx), do: People.user_card(user_id)
  end

  @spec ledger(ctx(), Ecto.UUID.t(), map()) :: {:ok, map()} | {:error, atom()}
  def ledger(%Context{} = ctx, user_id, params) do
    with :ok <- allowed(ctx), do: People.ledger(user_id, params)
  end

  @spec ban(ctx(), Ecto.UUID.t(), String.t()) :: {:ok, User.t()} | {:error, atom()}
  def ban(%Context{} = ctx, user_id, reason) do
    with :ok <- allowed(ctx), do: People.ban(ctx, user_id, reason)
  end

  @spec unban(ctx(), Ecto.UUID.t(), String.t()) :: {:ok, User.t()} | {:error, atom()}
  def unban(%Context{} = ctx, user_id, reason) do
    with :ok <- allowed(ctx), do: People.unban(ctx, user_id, reason)
  end

  # --- деньги ---------------------------------------------------------------

  @spec credit(ctx(), Ecto.UUID.t(), atom(), pos_integer(), String.t(), String.t()) ::
          {:ok, map()} | {:error, atom()}
  def credit(%Context{} = ctx, user_id, currency, amount, reason, idem) do
    with :ok <- allowed(ctx), do: Money.credit(ctx, user_id, currency, amount, reason, idem)
  end

  @spec take_to_admin(ctx(), Ecto.UUID.t(), atom(), pos_integer(), String.t(), String.t()) ::
          {:ok, map()} | {:error, atom()}
  def take_to_admin(%Context{} = ctx, user_id, currency, amount, reason, idem) do
    with :ok <- allowed(ctx),
         do: Money.take_to_admin(ctx, user_id, currency, amount, reason, idem)
  end

  # --- сборки клиента -------------------------------------------------------

  @spec client_releases(ctx()) :: {:ok, [map()]} | {:error, atom()}
  def client_releases(%Context{} = ctx) do
    with :ok <- allowed(ctx), do: {:ok, ClientReleases.list()}
  end

  @doc """
  Приём загруженной сборки. `attrs` содержит путь к временному файлу и
  имя, под которым его выбрали, — разбирать multipart умеет транспорт,
  решать, что с этим файлом делать, умеет только контекст.
  """
  @spec upload_client_release(ctx(), map()) :: {:ok, map()} | {:error, atom()}
  def upload_client_release(%Context{} = ctx, attrs) do
    with :ok <- allowed(ctx), do: ClientReleases.upload(ctx, attrs)
  end

  @spec publish_client_release(ctx(), Ecto.UUID.t()) :: {:ok, map()} | {:error, atom()}
  def publish_client_release(%Context{} = ctx, id) do
    with :ok <- allowed(ctx), do: ClientReleases.publish(ctx, id)
  end

  @spec delete_client_release(ctx(), Ecto.UUID.t()) :: :ok | {:error, atom()}
  def delete_client_release(%Context{} = ctx, id) do
    with :ok <- allowed(ctx), do: ClientReleases.delete(ctx, id)
  end

  # --- баннеры ---------------------------------------------------------------

  @spec banners(ctx()) :: {:ok, map()} | {:error, atom()}
  def banners(%Context{} = ctx) do
    with :ok <- allowed(ctx), do: {:ok, Banners.list()}
  end

  @doc """
  Замена содержимого места. `attrs` содержит место, тексты и — если
  картинку меняют — путь к временному файлу: разбирать multipart умеет
  транспорт, решать, что с этим файлом делать, умеет только контекст.
  """
  @spec put_banner(ctx(), map()) :: {:ok, map()} | {:error, atom() | Ecto.Changeset.t()}
  def put_banner(%Context{} = ctx, attrs) do
    with :ok <- allowed(ctx), do: Banners.put(ctx, attrs)
  end

  @spec delete_banner(ctx(), String.t()) :: :ok | {:error, atom()}
  def delete_banner(%Context{} = ctx, place) do
    with :ok <- allowed(ctx), do: Banners.delete(ctx, place)
  end

  # --- объявления -------------------------------------------------------------

  @doc """
  Объявление всем подключённым игрокам. Отправленное объявление не
  отзывается: оно уже ушло (см. `BlockPoker.Announcements`).
  """
  @spec announce(ctx(), map()) :: {:ok, map()} | {:error, atom()}
  def announce(%Context{} = ctx, attrs) do
    with :ok <- allowed(ctx), do: Announcements.announce(ctx, attrs)
  end

  # --- звуки ------------------------------------------------------------------

  @spec sounds(ctx()) :: {:ok, [map()]} | {:error, atom()}
  def sounds(%Context{} = ctx) do
    with :ok <- allowed(ctx), do: {:ok, Sounds.list()}
  end

  @doc """
  Загрузка звука в библиотеку. `attrs` — название и путь к временному
  файлу: разбирать multipart умеет транспорт, решать судьбу файла —
  только контекст.
  """
  @spec upload_sound(ctx(), map()) :: {:ok, map()} | {:error, atom() | Ecto.Changeset.t()}
  def upload_sound(%Context{} = ctx, attrs) do
    with :ok <- allowed(ctx), do: Sounds.create(ctx, attrs)
  end

  @spec delete_sound(ctx(), Ecto.UUID.t()) :: :ok | {:error, atom()}
  def delete_sound(%Context{} = ctx, id) do
    with :ok <- allowed(ctx), do: Sounds.delete(ctx, id)
  end

  @doc """
  Адресат по строке списка игр. Прав не требует: это разбор значения, а
  не действие, — как и `kind/1`.
  """
  @spec sound_target(atom(), String.t()) :: Sounds.target()
  defdelegate sound_target(kind, id), to: Sounds, as: :target

  @doc """
  Воспроизведение звука у адресата: комната, турнир целиком или весь зал.
  Отозвать отправленное нельзя — см. `BlockPoker.Sounds`.
  """
  @spec play_sound(ctx(), Sounds.target(), Ecto.UUID.t()) :: {:ok, map()} | {:error, atom()}
  def play_sound(%Context{} = ctx, target, sound_id) do
    with :ok <- allowed(ctx), do: Sounds.play(ctx, target, sound_id)
  end

  # --- игры -----------------------------------------------------------------

  @spec live_games(ctx(), atom()) :: {:ok, [map()]} | {:error, atom()}
  def live_games(%Context{} = ctx, kind \\ :all) do
    with :ok <- allowed(ctx), do: {:ok, Games.live_games(kind)}
  end

  @doc """
  Вид игры из строки с провода. Права не требует: это разбор значения,
  а не операция.
  """
  @spec game_kind(term()) :: atom()
  defdelegate game_kind(value), to: Games, as: :kind

  @doc """
  Топики, на которых слышно изменение списка игр: открытие и закрытие
  комнат, старт и финиш турниров.

  Спрашивается у контекста, а не собирается каналом: из чего состоит
  «живой список», знает ядро, и знать это в двух местах — значит рано или
  поздно забыть про один из них (§9 задачи 8).
  """
  @spec games_topics() :: [String.t()]
  defdelegate games_topics(), to: Games, as: :topics

  @doc "Топик конкретного турнира — его ход слышно на нём."
  @spec tournament_topic(Ecto.UUID.t()) :: String.t()
  defdelegate tournament_topic(tournament_id), to: Games, as: :topic

  @doc """
  Остановка, возобновление и снятие идущего турнира.

  Единственные операции панели, которые вмешиваются в игру, а не в
  учётку. Причина обязательна: без неё в журнале остаётся «кто-то
  остановил», а это не ответ ни на один вопрос, который зададут потом.
  """
  @spec pause_tournament(ctx(), Ecto.UUID.t(), String.t() | nil) ::
          {:ok, map()} | {:error, atom()}
  def pause_tournament(%Context{} = ctx, tournament_id, reason) do
    with :ok <- allowed(ctx), do: Games.pause_tournament(ctx, tournament_id, reason)
  end

  @spec resume_tournament(ctx(), Ecto.UUID.t(), String.t() | nil) ::
          {:ok, map()} | {:error, atom()}
  def resume_tournament(%Context{} = ctx, tournament_id, reason) do
    with :ok <- allowed(ctx), do: Games.resume_tournament(ctx, tournament_id, reason)
  end

  @spec cancel_tournament(ctx(), Ecto.UUID.t(), String.t() | nil) ::
          {:ok, map()} | {:error, atom()}
  def cancel_tournament(%Context{} = ctx, tournament_id, reason) do
    with :ok <- allowed(ctx), do: Games.cancel_tournament(ctx, tournament_id, reason)
  end

  @spec game_card(ctx(), atom(), String.t()) :: {:ok, map()} | {:error, atom()}
  def game_card(%Context{} = ctx, kind, id) do
    with :ok <- allowed(ctx), do: Games.game_card(kind, id)
  end

  # --- сетки ----------------------------------------------------------------

  @doc """
  Сетка режима: шаблоны, из которых поднимаются комнаты и турниры.

  Пара к `live_games/2` и её противоположность: там процессы, здесь
  строки, из которых процессы разворачиваются.
  """
  @spec grids(ctx(), atom(), keyword()) :: {:ok, [map()]} | {:error, atom()}
  def grids(%Context{} = ctx, kind, opts \\ []) do
    with :ok <- allowed(ctx), do: {:ok, Grids.list(kind, opts)}
  end

  @spec grid(ctx(), atom(), Ecto.UUID.t()) :: {:ok, map()} | {:error, atom()}
  def grid(%Context{} = ctx, kind, id) do
    with :ok <- allowed(ctx), do: Grids.get(kind, id)
  end

  @doc """
  Справочник для форм панели. Права требует так же, как остальное:
  список видов покера — не публичное знание.
  """
  @spec grid_meta(ctx()) :: {:ok, map()} | {:error, atom()}
  def grid_meta(%Context{} = ctx) do
    with :ok <- allowed(ctx), do: {:ok, Grids.meta()}
  end

  @doc """
  Вид сетки из строки с провода. Права не требует: разбор значения,
  а не операция.
  """
  @spec grid_kind(term()) :: {:ok, atom()} | {:error, :validation_failed}
  defdelegate grid_kind(value), to: Grids, as: :kind

  @spec create_grid(ctx(), atom(), map()) ::
          {:ok, map()} | {:error, atom() | Ecto.Changeset.t()}
  def create_grid(%Context{} = ctx, kind, attrs) do
    with :ok <- allowed(ctx), do: Grids.create(ctx, kind, attrs)
  end

  @spec update_grid(ctx(), atom(), Ecto.UUID.t(), map()) ::
          {:ok, map()} | {:error, atom() | Ecto.Changeset.t()}
  def update_grid(%Context{} = ctx, kind, id, attrs) do
    with :ok <- allowed(ctx), do: Grids.update(ctx, kind, id, attrs)
  end

  @doc "Снятие шаблона с сетки. Удаления строки не бывает: см. `Admin.Grids`."
  @spec archive_grid(ctx(), atom(), Ecto.UUID.t(), String.t() | nil) ::
          {:ok, map()} | {:error, atom() | Ecto.Changeset.t()}
  def archive_grid(%Context{} = ctx, kind, id, reason) do
    with :ok <- allowed(ctx), do: Grids.archive(ctx, kind, id, reason)
  end

  @spec restore_grid(ctx(), atom(), Ecto.UUID.t()) ::
          {:ok, map()} | {:error, atom() | Ecto.Changeset.t()}
  def restore_grid(%Context{} = ctx, kind, id) do
    with :ok <- allowed(ctx), do: Grids.restore(ctx, kind, id)
  end

  @doc "«Не жди таймера»: витрины перечитывают сетку немедленно."
  @spec apply_grids(ctx()) :: {:ok, map()} | {:error, atom()}
  def apply_grids(%Context{} = ctx) do
    with :ok <- allowed(ctx), do: Grids.apply(ctx)
  end

  # --- журнал ---------------------------------------------------------------

  @spec audit(ctx(), map()) :: {:ok, map()} | {:error, atom()}
  def audit(%Context{} = ctx, params) do
    with :ok <- allowed(ctx), do: {:ok, Audit.list(params)}
  end

  # --- god-mode -------------------------------------------------------------

  @spec observe(ctx(), Ecto.UUID.t()) :: {:ok, map()} | {:error, atom()}
  defdelegate observe(ctx, room_id), to: Observer

  @spec stop_observing(ctx(), Ecto.UUID.t()) :: :ok
  defdelegate stop_observing(ctx, room_id), to: Observer

  @doc "Включено ли наблюдение. Панель по этому флагу прячет вкладку «Стол»."
  @spec observer_enabled?() :: boolean()
  defdelegate observer_enabled?(), to: Observer, as: :enabled?

  defp allowed(%Context{admin_id: admin_id}) do
    with {:ok, _admin} <- Auth.ensure_admin(admin_id), do: :ok
  end
end
