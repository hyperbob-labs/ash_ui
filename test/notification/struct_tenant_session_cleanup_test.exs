defmodule AshUi.Notification.StructTenantSessionCleanupTest do
  # Session-row cleanup with a tenant that is a struct implementing
  # `Ash.ToTenant` rather than a string.
  use ExUnit.Case, async: false

  alias AshUi.Notification.MatchIndex
  require Ash.Query

  defmodule Org do
    defstruct [:id]
  end

  defimpl Ash.ToTenant, for: Org do
    def to_tenant(%{id: id}, _resource), do: "org_#{id}"
  end

  defmodule TenantProbe do
    use Ash.Resource,
      domain: nil,
      validate_domain_inclusion?: false,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi]

    ets do
      private?(false)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:session_id, :uuid, allow_nil?: false, public?: true)
      attribute(:subject, :string, allow_nil?: false, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id, :subject],
        pre_check_with: AshUi.AshDomainFallback
      )
    end

    calculations do
      calculate(:view, AshUi.Type.RenderTree, expr(section(:root, [], [text(subject)])))
    end

    actions do
      defaults([:read, :destroy])

      create :mount do
        accept([:subject])
      end
    end
  end

  test "transport death with a struct tenant keeps the index and other subscriptions alive" do
    MatchIndex.reset()
    tenant = %Org{id: 1}
    %{transport: transport, owner: owner} = start_bridge(tenant)
    domain = AshUi.AshDomainFallback.ensure!(TenantProbe)
    survivor = {:survivor_subscription, make_ref()}

    MatchIndex.register(survivor, %{
      pid: self(),
      resource: TenantProbe,
      attrs: [subject: "survivor"],
      filter: nil,
      parent: nil,
      reload_scope: [],
      tenant: nil,
      domain: domain
    })

    assert_eventually(fn ->
      Map.has_key?(:sys.get_state(MatchIndex).session_rows, transport) and
        MatchIndex.subscription(survivor) != nil
    end)

    index = Process.whereis(MatchIndex)
    index_ref = Process.monitor(index)
    owner_ref = Process.monitor(owner)
    Process.exit(transport, :kill)

    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 5_000
    refute_receive {:DOWN, ^index_ref, :process, ^index, _reason}, 500
    assert Process.whereis(MatchIndex) == index
    assert MatchIndex.subscription(survivor) != nil

    MatchIndex.dispatch(%Ash.Notifier.Notification{
      resource: TenantProbe,
      action: %{type: :update},
      data: %TenantProbe{
        id: Ash.UUID.generate(),
        session_id: Ash.UUID.generate(),
        subject: "survivor"
      }
    })

    assert_receive {:ash_ui_notification, ^survivor, _event}, 1_000
  end

  test "transport death sweeps session rows from a struct tenant's table" do
    MatchIndex.reset()
    tenant = %Org{id: 2}
    %{transport: transport, owner: owner, session_id: session_id} = start_bridge(tenant)
    domain = AshUi.AshDomainFallback.ensure!(TenantProbe)
    owner_ref = Process.monitor(owner)

    assert_eventually(fn -> rows_for_session(domain, session_id, tenant) != [] end)
    Process.exit(transport, :kill)

    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 5_000
    assert_eventually(fn -> rows_for_session(domain, session_id, tenant) == [] end)
  end

  test "cleanup_session/3 destroys session rows for a struct tenant" do
    tenant = %Org{id: 3}
    domain = AshUi.AshDomainFallback.ensure!(TenantProbe)
    session_id = mount!(tenant)
    assert [_row] = rows_for_session(domain, session_id, tenant)

    assert :ok =
             AshUi.Session.cleanup_session(TenantProbe, session_id,
               authorize?: false,
               tenant: tenant
             )

    assert [] == rows_for_session(domain, session_id, tenant)
  end

  test "sweep_sessions/3 destroys dead session rows for a struct tenant" do
    tenant = %Org{id: 4}
    domain = AshUi.AshDomainFallback.ensure!(TenantProbe)
    session_id = mount!(tenant)
    assert [_row] = rows_for_session(domain, session_id, tenant)

    assert :ok = AshUi.Session.sweep_sessions(TenantProbe, [], authorize?: false, tenant: tenant)

    assert [] == rows_for_session(domain, session_id, tenant)
  end

  defp start_bridge(tenant) do
    session_id = Ash.UUID.generate()
    parent = self()
    transport = spawn(fn -> receive do: (:close -> :ok) end)

    owner =
      spawn(fn ->
        MatchIndex.track_session_owner(transport, self())
        mount!(tenant, session_id, %{shared: %{ash_ui_session_pid: transport}})
        send(parent, {:bridge_ready, self()})

        receive do
          :release -> :ok
        end
      end)

    assert_receive {:bridge_ready, ^owner}, 5_000
    %{transport: transport, owner: owner, session_id: session_id}
  end

  defp mount!(tenant, session_id \\ Ash.UUID.generate(), context \\ %{}) do
    TenantProbe
    |> Ash.Changeset.for_create(:mount, %{subject: "session"},
      context: Map.put(context, :session_id, session_id),
      tenant: tenant,
      authorize?: false,
      domain: AshUi.AshDomainFallback.ensure!(TenantProbe)
    )
    |> Ash.create!(authorize?: false)

    session_id
  end

  defp rows_for_session(domain, session_id, tenant) do
    TenantProbe
    |> Ash.Query.filter(session_id == ^session_id)
    |> Ash.Query.set_tenant(tenant)
    |> Ash.read!(authorize?: false, domain: domain)
  end

  defp assert_eventually(fun, attempts \\ 100)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(fun, 0), do: assert(fun.())
end
