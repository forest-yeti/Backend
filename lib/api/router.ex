defmodule Api.Router do
  use Api, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Защита перебора: логин и регистрация — 10 попыток за 5 минут на IP,
  # продление токена — 30 (клиент дёргает его штатно, на каждом реконнекте).
  pipeline :auth_rate_limit do
    plug Api.Plugs.RateLimit, scope: :auth, limit: 10, window_ms: 300_000
  end

  # Личность на HTTP-ручках истории: тот же токен, что авторизует сокет.
  pipeline :authenticated do
    plug Api.Plugs.Authenticate
  end

  pipeline :refresh_rate_limit do
    plug Api.Plugs.RateLimit, scope: :refresh, limit: 30, window_ms: 300_000
  end

  # Панель администратора (задача 8). Отдельный пайплайн целиком: свой
  # токен и своя проверка сессии. Игровой токен здесь не работает никогда.
  # CORS панели живёт в `Socket.Endpoint`: предполётный `OPTIONS` маршрута
  # не имеет и до пайплайна не доходит.
  pipeline :admin do
    plug :accepts, ["json"]
  end

  pipeline :admin_authenticated do
    plug Api.Plugs.AdminAuth
  end

  # Вход в панель — самый дорогой перебор в системе: 5 попыток за 15 минут.
  pipeline :admin_login_rate_limit do
    plug Api.Plugs.RateLimit, scope: :admin_login, limit: 5, window_ms: 900_000
  end

  scope "/", Api do
    pipe_through :api

    get "/health", HealthController, :show
  end

  # Версия клиента — публично и без токена: её спрашивают до логина и до
  # сокета, в том числе сборкой, которую в игру уже не пускают (§1 задачи 34).
  scope "/api", Api do
    pipe_through :api

    get "/client/version", ClientController, :show

    # Баннеры — публично и без токена: `OnRunApplication` показывается на
    # запуске приложения, когда логина ещё не было.
    get "/banners/:place", BannerController, :show
  end

  scope "/api", Api do
    pipe_through [:api, :auth_rate_limit]

    post "/auth/register", AuthController, :register
    post "/auth/login", AuthController, :login
  end

  scope "/api", Api do
    pipe_through [:api, :refresh_rate_limit]

    post "/auth/refresh", AuthController, :refresh
  end

  # История и статистика — единственное чтение, вынесенное из сокета
  # (§2 задачи 6). Всё, что меняет состояние игры или требует пуша,
  # остаётся в канале.
  scope "/api", Api do
    pipe_through [:api, :authenticated]

    get "/history/hands", HistoryController, :hands
    get "/history/hands/:id", HistoryController, :hand
    get "/history/stats", HistoryController, :stats
    get "/history/graph", HistoryController, :graph
    get "/history/tournaments", HistoryController, :tournaments
    get "/history/tournaments/:id", HistoryController, :tournament
  end

  # Панель администратора. Списки и деньги — это чтение с пагинацией и
  # транзакционная запись, то есть HTTP; god-mode стола — это push, и он
  # живёт в `/admin/socket` (§2 задачи 8).
  scope "/admin", Api.Admin do
    pipe_through [:admin, :admin_login_rate_limit]

    post "/auth/login", AuthController, :login
    post "/auth/refresh", AuthController, :refresh
  end

  scope "/admin", Api.Admin do
    pipe_through [:admin, :admin_authenticated]

    post "/auth/logout", AuthController, :logout
    get "/auth/me", AuthController, :me

    get "/users", UserController, :index
    get "/users/:id", UserController, :show
    get "/users/:id/ledger", UserController, :ledger
    post "/users/:id/ban", UserController, :ban
    post "/users/:id/unban", UserController, :unban
    post "/users/:id/credit", UserController, :credit
    post "/users/:id/take", UserController, :take

    get "/games", GameController, :index
    get "/games/:kind/:id", GameController, :show

    # Вмешательство в идущую игру. По HTTP, а не сообщением канала
    # `admin:tournament:<id>`: у действия есть `reason` и запись в
    # журнале, то есть тело и ответ, — а канал панели только смотрит.
    post "/games/mtt/:id/pause", GameController, :pause
    post "/games/mtt/:id/resume", GameController, :resume
    post "/games/mtt/:id/cancel", GameController, :cancel

    # Сетки режимов: то, из чего рум состоит. Ручка одна на четыре
    # режима — `kind` едет в пути и разбирается ядром.
    #
    # `apply` и `meta` стоят выше `:kind`, потому что Phoenix читает
    # маршруты по порядку, и «apply» иначе уехало бы в шаблон режима
    # с таким именем.
    get "/settings", GridController, :index
    get "/settings/meta", GridController, :meta
    post "/settings/apply", GridController, :apply
    get "/settings/:kind/:id", GridController, :show
    post "/settings/:kind", GridController, :create
    patch "/settings/:kind/:id", GridController, :update

    # Удаления нет: на строку шаблона ссылается история раздач, поэтому
    # он снимается с сетки и возвращается, а не исчезает.
    post "/settings/:kind/:id/archive", GridController, :archive
    post "/settings/:kind/:id/restore", GridController, :restore

    get "/audit", AuditController, :index

    # Сборки клиента. Загрузка — единственная ручка панели с файлом, и
    # тело у неё измеряется сотнями мегабайт: разбирает её отдельный
    # плаг в `Socket.Endpoint`, а не общий `Plug.Parsers` (§3 задачи 34).
    get "/client-releases", ClientReleaseController, :index
    post "/client-releases", ClientReleaseController, :create
    post "/client-releases/:id/publish", ClientReleaseController, :publish
    delete "/client-releases/:id", ClientReleaseController, :delete

    # Баннеры. Место — ключ, поэтому создание и правка это одна ручка:
    # `POST` кладёт баннер на место независимо от того, стоял там что-то
    # раньше. Тело — multipart с картинкой, его разбирает
    # `Api.Plugs.BannerUpload` со своим небольшим пределом размера.
    get "/banners", BannerController, :index
    post "/banners", BannerController, :create
    delete "/banners/:place", BannerController, :delete

    # Объявление всем игрокам. Ручка только создаёт: объявление —
    # событие, а не запись, читать и отзывать нечего.
    post "/announcements", AnnouncementController, :create

    # Звуки. Библиотека — сущность (загрузили один раз, играем много),
    # само воспроизведение — событие: отозвать его нечем, поэтому ручки
    # «остановить» нет. Тело загрузки — multipart, его разбирает
    # `Api.Plugs.SoundUpload` со своим небольшим пределом размера.
    get "/sounds", SoundController, :index
    post "/sounds", SoundController, :create
    delete "/sounds/:id", SoundController, :delete
    post "/sounds/:id/play", SoundController, :play_everyone

    # Звук в конкретную игру. Живёт в адресном пространстве игр, а не
    # звуков, потому что выбирают здесь именно игру: `:mtt` — это турнир
    # целиком со всеми его столами, остальные виды — одна комната.
    post "/games/:kind/:id/sound", SoundController, :play_game
  end
end
