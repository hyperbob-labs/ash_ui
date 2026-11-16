defmodule AshUi.Phoenix.TemplateFilterSubscriptionsTest do
  @moduledoc """
  A relationship filter may use Ash templates (`^tenant()`, `^actor(...)`).
  Ash fills them when it loads the relationship, so the page renders the right
  rows. The notification subscription must match against the same filled
  filter: a foreign write that the relationship would load must notify the
  page and repaint it.

  Every case goes through the real connected mount (no hand-registered
  subscriptions) with `tenant: "org-a"`, and writes a row in that tenant that
  the declared filter selects.
  """

  use ExUnit.Case, async: false

  alias AshUi.Notification.MatchIndex

  defmodule Card do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      notifiers: [AshUi.Notifier],
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:group, :uuid, allow_nil?: false, public?: true)
      attribute(:org_id, :string, allow_nil?: false, public?: true)
      attribute(:title, :string, allow_nil?: false, public?: true)
    end

    actions do
      defaults([:read, create: :*])
    end
  end

  defmodule TenantCard do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      notifiers: [AshUi.Notifier],
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    multitenancy do
      strategy(:attribute)
      attribute(:org_id)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:group, :uuid, allow_nil?: false, public?: true)
      attribute(:org_id, :string, allow_nil?: false, public?: true)
      attribute(:title, :string, allow_nil?: false, public?: true)
    end

    actions do
      defaults([:read, create: :*])
    end
  end

  defmodule TenantPage do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:group, :uuid, allow_nil?: false, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    relationships do
      has_many :cards, AshUi.Phoenix.TemplateFilterSubscriptionsTest.Card do
        source_attribute(:group)
        destination_attribute(:group)
        filter(expr(org_id == ^tenant()))
      end
    end

    actions do
      defaults([:read, :destroy])

      create :mount do
        argument(:group, :uuid, allow_nil?: false)
        change(set_attribute(:group, arg(:group)))
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(each(cards, :card, [key: card.id], [text(card.title)]))
      )
    end
  end

  defmodule MultitenantPage do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:group, :uuid, allow_nil?: false, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    relationships do
      has_many :cards, AshUi.Phoenix.TemplateFilterSubscriptionsTest.TenantCard do
        source_attribute(:group)
        destination_attribute(:group)
        filter(expr(org_id == ^tenant()))
      end
    end

    actions do
      defaults([:read, :destroy])

      create :mount do
        argument(:group, :uuid, allow_nil?: false)
        change(set_attribute(:group, arg(:group)))
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(each(cards, :card, [key: card.id], [text(card.title)]))
      )
    end
  end

  defmodule ActorPage do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:group, :uuid, allow_nil?: false, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    relationships do
      has_many :cards, AshUi.Phoenix.TemplateFilterSubscriptionsTest.Card do
        source_attribute(:group)
        destination_attribute(:group)
        filter(expr(org_id == ^actor(:org_id)))
      end
    end

    actions do
      defaults([:read, :destroy])

      create :mount do
        argument(:group, :uuid, allow_nil?: false)
        change(set_attribute(:group, arg(:group)))
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(each(cards, :card, [key: card.id], [text(card.title)]))
      )
    end
  end

  # The page renders only an aggregate, so the relationship is never on the
  # record and the subscription comes from the derived-read walk.
  defmodule AggregatePage do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:group, :uuid, allow_nil?: false, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    relationships do
      has_many :cards, AshUi.Phoenix.TemplateFilterSubscriptionsTest.Card do
        source_attribute(:group)
        destination_attribute(:group)
        filter(expr(org_id == ^tenant()))
      end
    end

    actions do
      defaults([:read, :destroy])

      create :mount do
        argument(:group, :uuid, allow_nil?: false)
        change(set_attribute(:group, arg(:group)))
      end
    end

    aggregates do
      count(:card_count, :cards)
    end

    calculations do
      calculate(:view, AshUi.Type.RenderTree, expr(text(card_count)))
    end
  end

  @resources [Card, TenantCard, TenantPage, MultitenantPage, ActorPage, AggregatePage]

  setup do
    MatchIndex.reset()
    on_exit(fn -> Enum.each(@resources, &Ash.DataLayer.Ets.stop/1) end)
    :ok
  end

  defp create!(resource, attrs) do
    resource
    |> Ash.Changeset.for_create(:create, attrs,
      domain: AshUi.AshDomainFallback,
      tenant: attrs.org_id
    )
    |> Ash.create!()
  end

  # The connected mount path: a transport pid makes `connected?/1` true and
  # the `$callers` entry resolves the session pid to this process, so the
  # mount registers its subscriptions exactly as a live LiveView does.
  defp mount!(page, group, opts) do
    Process.put(:"$callers", [self()])

    socket = %Phoenix.LiveView.Socket{
      transport_pid: self(),
      assigns: %{__changed__: %{}},
      private: %{}
    }

    {:ok, socket} =
      AshUi.Phoenix.mount(
        page,
        %{"group" => group},
        %{"ash_ui_session_id" => Ash.UUID.generate()},
        socket,
        [otp_app: :ash_ui_phoenix] ++ opts
      )

    socket
  end

  defp deliver!(socket) do
    assert_receive {:ash_ui_notification, _ref, _event} = notification, 500
    {:noreply, socket} = AshUi.Phoenix.runtime_handle_info(notification, socket)
    socket.assigns.ash_ui_record
  end

  defp titles(record), do: record.cards |> Enum.map(& &1.title) |> Enum.sort()

  test "a ^tenant() relationship filter notifies on a write in the session's tenant" do
    group = Ash.UUID.generate()
    create!(Card, %{group: group, org_id: "org-a", title: "first"})

    socket = mount!(TenantPage, group, tenant: "org-a")
    assert titles(socket.assigns.ash_ui_record) == ["first"]

    create!(Card, %{group: group, org_id: "org-a", title: "second"})
    assert titles(deliver!(socket)) == ["first", "second"]
  end

  test "a ^tenant() relationship filter on an attribute-multitenant destination notifies" do
    group = Ash.UUID.generate()
    create!(TenantCard, %{group: group, org_id: "org-a", title: "first"})

    socket = mount!(MultitenantPage, group, tenant: "org-a")
    assert titles(socket.assigns.ash_ui_record) == ["first"]

    create!(TenantCard, %{group: group, org_id: "org-a", title: "second"})
    assert titles(deliver!(socket)) == ["first", "second"]
  end

  test "a ^actor() relationship filter notifies on a write the actor's filter selects" do
    group = Ash.UUID.generate()
    create!(Card, %{group: group, org_id: "org-a", title: "first"})

    socket = mount!(ActorPage, group, tenant: "org-a", actor: %{org_id: "org-a"})
    assert titles(socket.assigns.ash_ui_record) == ["first"]

    create!(Card, %{group: group, org_id: "org-a", title: "second"})
    assert titles(deliver!(socket)) == ["first", "second"]
  end

  test "an aggregate over a ^tenant()-filtered relationship notifies" do
    group = Ash.UUID.generate()
    create!(Card, %{group: group, org_id: "org-a", title: "first"})

    socket = mount!(AggregatePage, group, tenant: "org-a")
    assert socket.assigns.ash_ui_record.card_count == 1

    create!(Card, %{group: group, org_id: "org-a", title: "second"})
    assert deliver!(socket).card_count == 2
  end
end
