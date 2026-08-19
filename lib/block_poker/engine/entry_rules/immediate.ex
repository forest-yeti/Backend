defmodule BlockPoker.Engine.EntryRules.Immediate do
  @moduledoc """
  Вход без ожидания — правила для структур, где платят все и каждую раздачу
  (`BettingStructure.ButtonAnte`).

  Весь смысл ожидания большого блайнда в том, что круг стоит денег и платит
  за него по очереди каждый: без ожидания можно было бы садиться за кнопкой,
  играть лучшие позиции бесплатно и вставать перед блайндами. Когда анте
  платят все и всегда, уклониться нельзя физически — ждать становится
  нечего, а взнос за вход не за что брать.

  Поэтому здесь нет ни `waiting_for_bb`, ни `post`, ни мёртвого взноса, ни
  учёта пропущенных блайндов: севший играет ближайшую раздачу.

  Форма ответа та же, что у `Engine.EntryRules` — комната спрашивает
  структуру, а не выбирает между двумя разными интерфейсами.
  """

  alias BlockPoker.Engine.EntryRules

  @spec decide(EntryRules.params()) :: EntryRules.decision()
  def decide(_params), do: %{status: :playing, post: 0, dead_post: 0, can_post: false}

  @spec can_post?(EntryRules.params()) :: boolean()
  def can_post?(_params), do: false
end
