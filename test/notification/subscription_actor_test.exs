defmodule AshUi.Notification.SubscriptionActorTest do
  # Fork option: a match-index subscription may carry its session's `actor`,
  # and its filter is then evaluated as that actor (leanbob correspondence:
  # `MatchIndex.Subscription.actor`). The case is leanbob's
  # DisclosureRegister: a desk's approver queue filters revisions through the
  # revision's staff roles, a relationship whose own filter keeps the actor's
  # rows only. Evaluated with no actor that relationship loads empty, so the
  # queue's subscription never matched a new revision (upstream's behaviour,
  # kept for a subscription without the key).
  use ExUnit.Case, async: false

  require Ash.Expr

  alias AshUi.Notification.MatchIndex

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(AshUi.Notification.SubscriptionActorTest.StaffRole)
      resource(AshUi.Notification.SubscriptionActorTest.Revision)
    end
  end

  defmodule StaffRole do
    use Ash.Resource,
      domain: Domain,
      data_layer: Ash.DataLayer.Ets,
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:desk_id, :string, public?: true)
      attribute(:user_id, :string, public?: true)
      attribute(:role, :string, public?: true)
    end

    actions do
      defaults([:read, create: :*])
    end
  end

  defmodule Revision do
    use Ash.Resource,
      domain: Domain,
      data_layer: Ash.DataLayer.Ets,
      validate_domain_inclusion?: false,
      notifiers: [AshUi.Notifier]

    ets do
      private?(true)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:desk_id, :string, public?: true)
      attribute(:title, :string, public?: true)
    end

    relationships do
      # the reader's own roles on the revision's desk
      has_many(:staff_roles, StaffRole) do
        source_attribute(:desk_id)
        destination_attribute(:desk_id)
        filter(expr(user_id == ^actor(:id)))
      end
    end

    actions do
      defaults([:read, create: :*])
    end
  end

  setup do
    MatchIndex.reset()
    Ash.DataLayer.Ets.stop(StaffRole)
    Ash.DataLayer.Ets.stop(Revision)
    :ok
  end

  test "a filter through a relationship that compares the actor matches as the subscription's actor, and misses without one" do
    desk = "desk-#{System.unique_integer([:positive])}"
    approver = %{id: "approver-#{System.unique_integer([:positive])}"}

    Ash.create!(StaffRole, %{desk_id: desk, user_id: approver.id, role: "approver"},
      domain: Domain
    )

    # the approver queue's subscription: revisions of the desk on which the reader approves
    queue = %{
      pid: self(),
      resource: Revision,
      attrs: [desk_id: desk],
      filter: Ash.Expr.expr(exists(staff_roles, role == "approver")),
      tenant: nil,
      domain: Domain
    }

    with_actor = {:subscription_actor_test, :with_actor}
    without_actor = {:subscription_actor_test, :without_actor}
    MatchIndex.register(with_actor, Map.put(queue, :actor, approver))
    MatchIndex.register(without_actor, queue)

    Ash.create!(Revision, %{desk_id: desk, title: "Q3 notice"}, domain: Domain)

    assert_receive {:ash_ui_notification, ^with_actor, _event}
    refute_received {:ash_ui_notification, ^without_actor, _event}
  end
end
