defmodule AshUi.UpstreamBugs.ReloadWindowDependenciesTest.Artist do
  @moduledoc false
  use Ash.Resource,
    domain: nil,
    data_layer: Ash.DataLayer.Ets,
    validate_domain_inclusion?: false

  ets do
    private?(true)
  end

  actions do
    default_accept(:*)
    defaults([:read, create: :*])

    read :search do
      argument(:query, :string, default: "", constraints: [allow_empty?: true, trim?: false])
      filter(expr(contains(name, ^arg(:query))))
      pagination(offset?: true, countable: true, max_page_size: 20)
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
    attribute(:plays, :integer, public?: true, default: 0)
  end
end

defmodule AshUi.UpstreamBugs.ReloadWindowDependenciesTest.Browse do
  @moduledoc false
  use Ash.Resource,
    domain: nil,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshUi],
    validate_domain_inclusion?: false

  alias AshUi.UpstreamBugs.ReloadWindowDependenciesTest.Artist

  ets do
    private?(true)
  end

  attributes do
    attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)

    attribute(:query, :string,
      allow_nil?: false,
      default: "",
      public?: true,
      constraints: [allow_empty?: true, trim?: false]
    )

    attribute(:sort_by, :atom,
      allow_nil?: false,
      default: :name,
      public?: true,
      constraints: [one_of: [:name, :"-plays"]]
    )

    attribute(:offset, :integer, allow_nil?: false, default: 0, public?: true, constraints: [min: 0])
    attribute(:draft, :string, allow_nil?: false, default: "", public?: true)
  end

  identities do
    identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
  end

  relationships do
    has_many :artists, Artist do
      public?(true)
      no_attributes?(true)
      read_action(:search)

      window do
        argument(:query, parent: :query)
        sort_by(:sort_by)
        sort(:name, name: :asc)
        sort(:"-plays", plays: :desc)
        size(2)
        offset(:offset)
      end
    end
  end

  calculations do
    calculate(
      :view,
      AshUi.Type.RenderTree,
      expr(
        section(:root, [part: :browse_root], [
          list(:artists, [part: :artist_list], [
            each(artists, :artist, [], [item(:a, [part: :artist_row], [text(artist.name)])])
          ])
        ])
      )
    )
  end

  actions do
    defaults([:read])

    create :mount do
    end

    update :set_query do
      require_atomic?(false)
      argument(:query, :string, allow_nil?: false, constraints: [allow_empty?: true, trim?: false])
      change(set_attribute(:query, arg(:query)))
    end

    update :set_sort do
      require_atomic?(false)
      argument(:sort_by, :atom, allow_nil?: false, constraints: [one_of: [:name, :"-plays"]])
      change(set_attribute(:sort_by, arg(:sort_by)))
    end

    update :set_offset do
      require_atomic?(false)
      argument(:offset, :integer, allow_nil?: false, constraints: [min: 0])
      change(set_attribute(:offset, arg(:offset)))
    end

    update :type do
      require_atomic?(false)
      argument(:draft, :string, allow_nil?: false)
      change(set_attribute(:draft, arg(:draft)))
    end
  end
end

defmodule AshUi.UpstreamBugs.ReloadWindowDependenciesTest do
  @moduledoc """
  A `has_many` window (the Ash fork's `Ash.Resource.Relationships.Window`) reads its relationship's
  action with arguments, a sort and a position taken from the page row: `argument :query, parent:
  :query`, `sort_by :sort_by`, `offset :offset` (or `after :cursor`). The reload index derived a
  declarative relationship's dependencies from its `source_attribute` and its filter's `parent(...)`
  refs only, so a window (`no_attributes? true`, no filter) depended on no attribute: a dispatch
  that changed the page row's query, sort or offset re-read nothing, and the page kept the list it
  had (Tunez's Browse: searching, sorting or paging the artists showed them as they were).

  Built against the Ash fork beside this checkout (`ASH_VERSION=local`, the default; mix.exs).
  """
  use ExUnit.Case, async: false

  alias AshUi.Reload
  alias AshUi.UpstreamBugs.ReloadWindowDependenciesTest.{Artist, Browse}

  setup do
    on_exit(fn ->
      Ash.DataLayer.Ets.stop(Browse)
      Ash.DataLayer.Ets.stop(Artist)
    end)

    for {name, plays} <- [{"Ann", 1}, {"Bob", 5}, {"Cyd", 3}] do
      Artist
      |> Ash.Changeset.for_create(:create, %{name: name, plays: plays},
        domain: AshUi.AshDomainFallback,
        authorize?: false
      )
      |> Ash.create!(domain: AshUi.AshDomainFallback)
    end

    :ok
  end

  defp mounted do
    Browse
    |> Ash.Seed.seed!(%{session_id: Ash.UUID.generate()})
    |> Ash.load!(AshUi.view_load(Browse), domain: AshUi.AshDomainFallback, authorize?: false)
  end

  defp run!(page, action, args) do
    page
    |> Ash.Changeset.for_update(action, args, domain: AshUi.AshDomainFallback, authorize?: false)
    |> Ash.update!(domain: AshUi.AshDomainFallback)
  end

  defp names(page), do: Enum.map(page.artists.results, & &1.name)

  # the dispatch as a bridge answers it: the action's result, refreshed by the reload contract
  defp dispatch(page, action, args) do
    {:ok, record} = Reload.after_dispatch(page, run!(page, action, args), :root, authorize?: false)
    record
  end

  test "the window depends on the attributes its arguments, sort and offset are taken from" do
    assert %{attributes: attributes} = Map.new(Reload.view_dependency_index(Browse))[:artists]
    assert Enum.sort(attributes) == [:offset, :query, :sort_by]
  end

  test "a change of any of them names the window; a draft does not" do
    for attribute <- [:query, :sort_by, :offset] do
      assert Reload.dependent_roots_for_attributes(Browse, [attribute]) == [:artists], "#{attribute}"
    end

    assert Reload.dependent_roots_for_attributes(Browse, [:draft]) == []
  end

  test "after a dispatch the window is the page's query, sort and offset" do
    page = mounted()
    assert names(page) == ["Ann", "Bob"]

    searched = dispatch(page, :set_query, %{query: "y"})
    assert names(searched) == ["Cyd"]

    sorted = dispatch(dispatch(searched, :set_query, %{query: ""}), :set_sort, %{sort_by: :"-plays"})
    assert names(sorted) == ["Bob", "Cyd"]

    paged = dispatch(sorted, :set_offset, %{offset: 2})
    assert names(paged) == ["Ann"]

    # a write the window does not read keeps the loaded page as it is
    typed = dispatch(paged, :type, %{draft: "x"})
    assert typed.artists == paged.artists
  end
end
