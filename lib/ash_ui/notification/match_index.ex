defmodule AshUi.Notification.MatchIndex do
  @moduledoc false

  # Supervised owner of the notification match index.
  #
  # ETS tables owned by this process (supervised via
  # AshUi.Application), readable from any process:
  #
  #   @triples (bag):  {dest_resource, dest_attr, parent_value} => subscription_ref
  #   @subs   (set):   subscription_ref =>
  #                    {subscription, triple_keys, indexed_attributes}
  #
  # The dispatch hot path (called synchronously in the writer's process
  # post-commit) does keyed :ets.lookup on @triples — O(matching
  # subscriptions), never a table scan. Registration, deregistration, and
  # transport handoff are direct ETS operations. Only compact pid/ref monitor
  # bookkeeping enters the GenServer, so a large loaded page can neither
  # inflate its heap nor put it on the blocking mount path. Session-pid
  # monitors live in this process's state, so a session crash still
  # deregisters its subscriptions without unsupervised spawns.

  use GenServer
  require Logger

  @triples __MODULE__.Triples
  @subs __MODULE__.Subs
  @resource_attrs __MODULE__.ResourceAttrs
  @handoffs __MODULE__.Handoffs
  @handoff_order __MODULE__.HandoffOrder
  @handoff_ttl_ms 5_000
  @max_handoffs 1_024
  @owner_audit_interval_ms 1_000
  @max_owner_mailbox 256

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    table_options = [:public, :named_table, read_concurrency: true, write_concurrency: true]
    :ets.new(@triples, [:bag | table_options])
    :ets.new(@subs, [:set | table_options])
    :ets.new(@resource_attrs, [:bag | table_options])
    :ets.new(@handoffs, [:set | table_options])
    :ets.new(@handoff_order, [:ordered_set | table_options])
    Process.send_after(self(), :audit_session_owners, @owner_audit_interval_ms)

    {:ok,
     %{
       monitors: %{},
       pid_monitors: %{},
       subscription_monitors: %{},
       session_rows: %{},
       session_monitors: %{},
       session_owners: %{},
       owner_sessions: %{},
       owner_monitors: %{}
     }}
  end

  ## Public API

  def reset do
    call_if_running(:reset, :ok)
  end

  def register(subscription_ref, subscription) when is_map(subscription) do
    register_many([{subscription_ref, subscription}])
  end

  def register_many(subscriptions) when is_list(subscriptions) do
    if Process.whereis(__MODULE__) do
      tracked =
        Enum.map(subscriptions, fn {subscription_ref, subscription} ->
          subscription =
            subscription
            |> Map.put(:subscription_ref, subscription_ref)
            |> parse_subscription_filter()
            |> compact_filter_parent()

          replace_subscription(subscription_ref, subscription)
          {subscription_ref, Map.get(subscription, :pid)}
        end)

      GenServer.cast(__MODULE__, {:track_subscriptions, tracked})
    end

    :ok
  end

  # Collapse many subscriptions for the same unfiltered relationship edge
  # into one subscription with an indexed value set. This preserves exact ETS
  # candidate lookup while avoiding one registry row per loaded parent.
  def compact_subscriptions(subscriptions, ref_prefix) when is_list(subscriptions) do
    subscriptions
    |> Enum.group_by(fn {ref, subscription} ->
      if compactable_subscription?(subscription) do
        {:compact, Map.drop(subscription, [:attrs]), Enum.map(subscription.attrs, &elem(&1, 0))}
      else
        {:single, ref}
      end
    end)
    |> Enum.map(fn
      {{:compact, _subscription, _attr_names}, [{ref, subscription}]} ->
        {ref, subscription}

      {{:compact, _subscription, attr_names}, entries} ->
        {_ref, subscription} = hd(entries)

        attrs =
          Enum.map(attr_names, fn attr ->
            values =
              entries
              |> Enum.map(fn {_ref, subscription} -> Keyword.fetch!(subscription.attrs, attr) end)
              |> Enum.uniq()

            {attr, {:one_of, values}}
          end)

        ref =
          {ref_prefix, :indexed_relationship, subscription.resource, subscription.reload_scope,
           attr_names}

        {ref, %{subscription | attrs: attrs}}

      {{:single, _ref}, [entry]} ->
        entry
    end)
  end

  def deregister(subscription_ref) do
    if Process.whereis(__MODULE__) do
      delete_subscription(subscription_ref)
      GenServer.cast(__MODULE__, {:untrack_subscription, subscription_ref})
    end

    :ok
  end

  def reregister(subscription_ref, subscription) when is_map(subscription) do
    register(subscription_ref, subscription)
  end

  def lookup(destination_resource, destination_attribute, parent_value) do
    @triples
    |> ets_lookup({destination_resource, destination_attribute, parent_value})
    |> Enum.map(fn {_key, ref} -> ref end)
    |> Enum.uniq()
    |> Enum.flat_map(fn ref ->
      case subscription(ref) do
        nil -> []
        subscription -> [%{subscription_ref: ref, subscription: subscription}]
      end
    end)
  end

  def subs_for(destination_resource) do
    @subs
    |> ets_tab2list()
    |> Enum.filter(fn {_ref, {subscription, _keys, _attrs}} ->
      Map.get(subscription, :resource) == destination_resource
    end)
    |> Enum.map(fn {ref, {subscription, _keys, _attrs}} ->
      {ref, subscription}
    end)
  end

  def subscription(subscription_ref) do
    case ets_lookup(@subs, subscription_ref) do
      [{^subscription_ref, {subscription, _keys, _attrs}}] -> subscription
      _other -> nil
    end
  end

  def loads(destination_resource) when is_atom(destination_resource) do
    destination_resource
    |> subs_for()
    |> Enum.flat_map(fn {_ref, subscription} -> List.wrap(Map.get(subscription, :load, [])) end)
    |> Enum.uniq()
  end

  # One-shot, short-lived transfer between two transport phases that share a
  # durable session identity (for example a static document render and its
  # connected process). The key/value vocabulary is deliberately neutral: the
  # adapter owns what is handed off, while this supervised session runtime owns
  # bounded lifetime and race-free take semantics.
  def put_session_handoff(key, value) do
    if Process.whereis(__MODULE__) do
      now = System.monotonic_time(:millisecond)
      order_key = {now, System.unique_integer([:monotonic, :positive])}

      case :ets.take(@handoffs, key) do
        [{^key, previous_order_key, _previous_value}] ->
          :ets.delete(@handoff_order, previous_order_key)

        _missing ->
          :ok
      end

      :ets.insert(@handoffs, {key, order_key, value})
      :ets.insert(@handoff_order, {order_key, key})
      prune_handoffs(now)
    end

    :ok
  end

  def take_session_handoff(key) do
    case :ets.take(@handoffs, key) do
      [{^key, {stored_at, _ordinal} = order_key, value}] ->
        :ets.delete(@handoff_order, order_key)

        if System.monotonic_time(:millisecond) - stored_at <= @handoff_ttl_ms,
          do: value

      _missing ->
        nil
    end
  end

  # Crash-path session-row GC: adapters explicitly identify the process that
  # owns a session. Calls from another boundary (for example AshLua) inherit
  # the registered owner by session id. A short-lived action caller must never
  # steal ownership and sweep live browser state on exit.
  def track_session_rows(resource, session_id, pid, tenant)
      when is_atom(resource) and is_binary(session_id) and (is_pid(pid) or is_nil(pid)) do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:track_session_rows, resource, session_id, pid, tenant})
    end

    :ok
  end

  def track_session_rows(_resource, _session_id, _pid, _tenant), do: :ok

  # The transport owns the browser session, while `owner_pid` owns the loaded
  # page record and any process-local data-layer snapshots/folds. Monitoring
  # both lets transport death hard-stop a Bridge that is too busy to consume
  # its ordinary shutdown message.
  def track_session_owner(session_pid, owner_pid)
      when is_pid(session_pid) and is_pid(owner_pid) do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:track_session_owner, session_pid, owner_pid})
    end

    :ok
  end

  def track_session_owner(_session_pid, _owner_pid), do: :ok

  def release_session_owner(session_pid, owner_pid)
      when is_pid(session_pid) and is_pid(owner_pid) do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:release_session_owner, session_pid, owner_pid})
    end

    :ok
  end

  def release_session_owner(_session_pid, _owner_pid), do: :ok

  @doc false
  def audit_session_owners do
    call_if_running(:audit_session_owners, :ok)
  end

  @doc false
  def session_owner_mailbox_limit, do: @max_owner_mailbox

  def dispatch(%Ash.Notifier.Notification{} = notification) do
    resource = notification.resource
    new_record = notification.data
    # bulk atomics carry the OriginalDataNotAvailable sentinel (lane 5):
    # an unknown before-image means "anything may have changed" — nil
    # over-delivers and reload stays the correctness path
    old_record =
      if notification.action.type == :create do
        # A create has no durable before-image. The Ash changeset carries its
        # initialized empty struct in `data`; treating attribute defaults on
        # that value as an old row makes mutually exclusive relationship
        # filters both fire for the first insert.
        nil
      else
        case get_in(notification, [Access.key(:changeset), Access.key(:data)]) do
          %Ash.Changeset.OriginalDataNotAvailable{} -> nil
          data -> data
        end
      end

    notification_tenant = notification_tenant(notification)

    event = %{
      type: notification.action.type,
      new: new_record,
      old: old_record,
      resource: resource,
      notification: notification,
      tenant: notification_tenant
    }

    resource
    |> candidate_entries(new_record, old_record)
    |> Enum.uniq_by(& &1.subscription_ref)
    |> Enum.filter(fn entry ->
      subscription = entry.subscription

      tenant_visible?(subscription, notification_tenant) and
        safe_stage2_hit?(subscription, new_record, old_record)
    end)
    |> Enum.map(fn entry ->
      subscription = entry.subscription
      send(subscription.pid, {:ash_ui_notification, entry.subscription_ref, event})
      {entry.subscription_ref, subscription}
    end)
  end

  ## GenServer callbacks

  @impl true
  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@triples)
    :ets.delete_all_objects(@subs)
    :ets.delete_all_objects(@resource_attrs)
    :ets.delete_all_objects(@handoffs)
    :ets.delete_all_objects(@handoff_order)
    Enum.each(state.monitors, fn {ref, _info} -> Process.demonitor(ref, [:flush]) end)
    Enum.each(state.session_monitors, fn {_pid, ref} -> Process.demonitor(ref, [:flush]) end)
    Enum.each(state.owner_monitors, fn {_pid, ref} -> Process.demonitor(ref, [:flush]) end)

    {:reply, :ok,
     state
     |> Map.merge(%{
       monitors: %{},
       pid_monitors: %{},
       subscription_monitors: %{},
       session_rows: %{},
       session_monitors: %{},
       session_owners: %{},
       owner_sessions: %{},
       owner_monitors: %{}
     })}
  end

  def handle_call(:audit_session_owners, _from, state) do
    {:reply, :ok, audit_session_owners(state)}
  end

  @impl true
  def handle_cast({:track_subscriptions, subscriptions}, state) do
    state =
      Enum.reduce(subscriptions, state, fn {subscription_ref, pid}, state ->
        state = untrack_subscription(subscription_ref, state)

        if is_pid(pid) do
          {monitor_ref, state} = ensure_subscription_monitor(state, pid)

          state
          |> update_in(
            [:monitors, monitor_ref, :subscriptions],
            &MapSet.put(&1, subscription_ref)
          )
          |> put_in([:subscription_monitors, subscription_ref], monitor_ref)
        else
          state
        end
      end)

    {:noreply, state}
  end

  def handle_cast({:untrack_subscription, subscription_ref}, state) do
    {:noreply, untrack_subscription(subscription_ref, state)}
  end

  def handle_cast({:track_session_rows, resource, session_id, pid, tenant}, state) do
    pid = pid || session_owner(state.session_rows, session_id)

    if is_pid(pid) do
      {:noreply, track_session_pair(state, {resource, session_id, tenant}, pid)}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:track_session_owner, session_pid, owner_pid}, state) do
    session_owners =
      Map.update(state.session_owners, session_pid, MapSet.new([owner_pid]), fn owners ->
        MapSet.put(owners, owner_pid)
      end)

    owner_sessions =
      Map.update(state.owner_sessions, owner_pid, MapSet.new([session_pid]), fn sessions ->
        MapSet.put(sessions, session_pid)
      end)

    state = %{state | session_owners: session_owners, owner_sessions: owner_sessions}
    state = ensure_session_monitor(state, session_pid)

    state =
      if Map.has_key?(state.owner_monitors, owner_pid) do
        state
      else
        put_in(state.owner_monitors[owner_pid], Process.monitor(owner_pid))
      end

    {:noreply, state}
  end

  def handle_cast({:release_session_owner, session_pid, owner_pid}, state) do
    {:noreply, detach_session_owner(state, session_pid, owner_pid)}
  end

  defp track_session_pair(state, pair, pid) do
    # Latest owner wins: a pair re-tracked by a newer pid (disconnected
    # HTTP render -> connected transport) moves — the old owner's death
    # must not sweep rows the live session still uses.
    state =
      update_in(state.session_rows, fn session_rows ->
        Map.new(session_rows, fn {owner, rows} ->
          if owner == pid, do: {owner, rows}, else: {owner, MapSet.delete(rows, pair)}
        end)
      end)

    rows = MapSet.put(Map.get(state.session_rows, pid, MapSet.new()), pair)
    state = put_in(state.session_rows[pid], rows)

    ensure_session_monitor(state, pid)
  end

  @impl true
  def handle_info(:audit_session_owners, state) do
    state = audit_session_owners(state)
    Process.send_after(self(), :audit_session_owners, @owner_audit_interval_ms)
    {:noreply, state}
  end

  def handle_info({:DOWN, monitor_ref, :process, pid, _reason}, state) do
    session_down? = Map.get(state.session_monitors, pid) == monitor_ref
    owner_down? = Map.get(state.owner_monitors, pid) == monitor_ref
    {info, monitors} = Map.pop(state.monitors, monitor_ref)
    state = %{state | monitors: monitors, pid_monitors: Map.delete(state.pid_monitors, pid)}

    state =
      case info do
        %{pid: ^pid, subscriptions: subscriptions} ->
          Enum.reduce(subscriptions, state, fn subscription_ref, state ->
            delete_subscription(subscription_ref)
            update_in(state.subscription_monitors, &Map.delete(&1, subscription_ref))
          end)

        _other ->
          state
      end

    state = if session_down?, do: terminate_session_owners(pid, state), else: state
    state = if owner_down?, do: expire_owner_sessions(state, pid), else: state

    state =
      if session_down? or Map.has_key?(state.session_rows, pid) do
        sweep_session_rows(pid, state)
      else
        state
      end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  ## Internals

  defp ensure_session_monitor(state, pid) do
    if Map.has_key?(state.session_monitors, pid) do
      state
    else
      put_in(state.session_monitors[pid], Process.monitor(pid))
    end
  end

  defp audit_session_owners(state) do
    candidates =
      state.owner_monitors
      |> Map.keys()

    Enum.reduce(candidates, state, fn pid, state ->
      case Process.info(pid, :message_queue_len) do
        {:message_queue_len, length} when length > @max_owner_mailbox ->
          Process.exit(pid, :kill)

          state
          |> expire_owner_sessions(pid)
          |> cleanup_owner_subscriptions(pid)

        _within_bound_or_dead ->
          state
      end
    end)
  end

  defp terminate_session_owners(session_pid, state) do
    state.session_owners
    |> Map.get(session_pid, MapSet.new())
    |> Enum.reduce(state, fn owner_pid, state ->
      if owner_pid != self() and Process.alive?(owner_pid), do: Process.exit(owner_pid, :kill)
      detach_session_owner(state, session_pid, owner_pid)
    end)
  end

  defp expire_owner_sessions(state, owner_pid) do
    sessions = Map.get(state.owner_sessions, owner_pid, MapSet.new())

    state =
      Enum.reduce(sessions, state, fn session_pid, state ->
        detach_session_owner(state, session_pid, owner_pid)
      end)

    remove_owner_monitor(state, owner_pid)
  end

  defp detach_session_owner(state, session_pid, owner_pid) do
    session_owners =
      case Map.get(state.session_owners, session_pid) do
        nil ->
          state.session_owners

        owners ->
          owners = MapSet.delete(owners, owner_pid)

          if MapSet.size(owners) == 0,
            do: Map.delete(state.session_owners, session_pid),
            else: Map.put(state.session_owners, session_pid, owners)
      end

    owner_sessions =
      case Map.get(state.owner_sessions, owner_pid) do
        nil ->
          state.owner_sessions

        sessions ->
          sessions = MapSet.delete(sessions, session_pid)

          if MapSet.size(sessions) == 0,
            do: Map.delete(state.owner_sessions, owner_pid),
            else: Map.put(state.owner_sessions, owner_pid, sessions)
      end

    state = %{state | session_owners: session_owners, owner_sessions: owner_sessions}

    if Map.has_key?(owner_sessions, owner_pid) do
      state
    else
      remove_owner_monitor(state, owner_pid)
    end
  end

  defp remove_owner_monitor(state, owner_pid) do
    case Map.pop(state.owner_monitors, owner_pid) do
      {nil, owner_monitors} ->
        %{state | owner_monitors: owner_monitors}

      {monitor_ref, owner_monitors} ->
        Process.demonitor(monitor_ref, [:flush])
        %{state | owner_monitors: owner_monitors}
    end
  end

  defp cleanup_owner_subscriptions(state, owner_pid) do
    state.monitors
    |> Enum.filter(fn {_ref, monitor} -> monitor.pid == owner_pid end)
    |> Enum.flat_map(fn {_ref, monitor} -> MapSet.to_list(monitor.subscriptions) end)
    |> Enum.each(&delete_subscription/1)

    state
  end

  defp sweep_session_rows(pid, state) do
    {rows, session_rows} = Map.pop(state.session_rows, pid)
    {monitor_ref, session_monitors} = Map.pop(state.session_monitors, pid)
    if monitor_ref, do: Process.demonitor(monitor_ref, [:flush])

    rows
    |> Kernel.||(MapSet.new())
    |> Enum.group_by(
      fn {_resource, session_id, tenant} -> {session_id, tenant} end,
      fn {resource, _session_id, _tenant} -> resource end
    )
    |> Enum.each(fn {{session_id, tenant}, resources} ->
      # Backstop GC over the dead session's own UI-state rows; the
      # orderly adapter teardown is the primary cleanup path.
      AshUi.Session.cleanup_session(resources, session_id,
        authorize?: false,
        tenant: tenant
      )
    end)

    %{state | session_rows: session_rows, session_monitors: session_monitors}
  end

  defp session_owner(session_rows, session_id) do
    Enum.find_value(session_rows, fn {pid, rows} ->
      if Enum.any?(rows, fn {_resource, tracked_session_id, _tenant} ->
           tracked_session_id == session_id
         end),
         do: pid
    end)
  end

  defp prune_handoffs(now) do
    case :ets.first(@handoff_order) do
      {stored_at, _ordinal} = order_key
      when now - stored_at > @handoff_ttl_ms ->
        prune_handoff(order_key)
        prune_handoffs(now)

      order_key when order_key != :"$end_of_table" ->
        if :ets.info(@handoffs, :size) > @max_handoffs do
          prune_handoff(order_key)
          prune_handoffs(now)
        else
          :ok
        end

      :"$end_of_table" ->
        :ok
    end
  end

  defp prune_handoff(order_key) do
    case ets_lookup(@handoff_order, order_key) do
      [{^order_key, key}] ->
        :ets.delete(@handoff_order, order_key)

        case ets_lookup(@handoffs, key) do
          [{^key, ^order_key, _value}] -> :ets.delete(@handoffs, key)
          _newer_or_taken -> :ok
        end

      _missing ->
        :ok
    end
  end

  defp untrack_subscription(subscription_ref, state) do
    case Map.pop(state.subscription_monitors, subscription_ref) do
      {nil, subscription_monitors} ->
        %{state | subscription_monitors: subscription_monitors}

      {monitor_ref, subscription_monitors} ->
        case Map.get(state.monitors, monitor_ref) do
          %{pid: pid, subscriptions: subscriptions} = monitor ->
            subscriptions = MapSet.delete(subscriptions, subscription_ref)

            if MapSet.size(subscriptions) == 0 do
              Process.demonitor(monitor_ref, [:flush])

              %{
                state
                | monitors: Map.delete(state.monitors, monitor_ref),
                  pid_monitors: Map.delete(state.pid_monitors, pid),
                  subscription_monitors: subscription_monitors
              }
            else
              %{
                state
                | monitors:
                    Map.put(state.monitors, monitor_ref, %{monitor | subscriptions: subscriptions}),
                  subscription_monitors: subscription_monitors
              }
            end

          _missing_monitor ->
            %{state | subscription_monitors: subscription_monitors}
        end
    end
  end

  defp replace_subscription(subscription_ref, subscription) do
    delete_subscription(subscription_ref)

    resource = Map.fetch!(subscription, :resource)

    triple_keys =
      subscription
      |> Map.get(:attrs, [])
      |> Enum.flat_map(fn
        {_attr, nil} ->
          []

        {attr, {:one_of, values}} when is_list(values) ->
          Enum.map(values, &{resource, attr, &1})

        {attr, value} ->
          [{resource, attr, value}]
      end)
      |> case do
        [] -> [{resource, :*, :*}]
        keys -> keys
      end

    resource_attrs = indexed_attributes(triple_keys)

    Enum.each(triple_keys, fn key -> :ets.insert(@triples, {key, subscription_ref}) end)

    Enum.each(resource_attrs, fn attr ->
      :ets.insert(@resource_attrs, {resource, attr, subscription_ref})
    end)

    :ets.insert(@subs, {subscription_ref, {subscription, triple_keys, resource_attrs}})
  end

  defp indexed_attributes(triple_keys) do
    triple_keys
    |> Enum.map(fn {_resource, attr, _value} -> attr end)
    |> Enum.reject(&(&1 == :*))
    |> Enum.uniq()
  end

  defp delete_subscription(subscription_ref) do
    case ets_lookup(@subs, subscription_ref) do
      [{^subscription_ref, {subscription, triple_keys, resource_attrs}}] ->
        Enum.each(triple_keys, fn key ->
          :ets.delete_object(@triples, {key, subscription_ref})
        end)

        Enum.each(resource_attrs, fn attr ->
          :ets.delete_object(
            @resource_attrs,
            {Map.fetch!(subscription, :resource), attr, subscription_ref}
          )
        end)

        :ets.delete(@subs, subscription_ref)

      _other ->
        :ok
    end
  end

  defp ensure_subscription_monitor(state, pid) do
    case Map.get(state.pid_monitors, pid) do
      monitor_ref when is_reference(monitor_ref) ->
        {monitor_ref, state}

      nil ->
        monitor_ref = Process.monitor(pid)

        state =
          state
          |> put_in([:monitors, monitor_ref], %{pid: pid, subscriptions: MapSet.new()})
          |> put_in([:pid_monitors, pid], monitor_ref)

        {monitor_ref, state}
    end
  end

  defp compactable_subscription?(subscription) do
    Map.get(subscription, :filter) in [nil, []] and
      is_nil(Map.get(subscription, :parent)) and
      match?([_first | _rest], Map.get(subscription, :attrs, [])) and
      Enum.all?(subscription.attrs, fn
        {attr, value} when is_atom(attr) -> not is_nil(value) and not match?({:one_of, _}, value)
        _other -> false
      end)
  end

  defp compact_filter_parent(%{filter: filter, parent: %resource{} = parent} = subscription)
       when filter not in [nil, []] do
    parent_refs =
      Ash.Filter.flat_map(filter, fn
        %Ash.Query.Parent{expr: expression} -> Ash.Filter.list_refs(expression)
        _other -> []
      end)

    case direct_parent_attribute_names(parent_refs, resource) do
      {:ok, []} ->
        Map.put(subscription, :parent, nil)

      {:ok, attribute_names} ->
        values = parent |> Map.from_struct() |> Map.take(attribute_names)
        Map.put(subscription, :parent, struct(resource, values))

      :error ->
        subscription
    end
  end

  defp compact_filter_parent(subscription), do: subscription

  defp parse_subscription_filter(%{filter: %Ash.Filter{}} = subscription), do: subscription

  defp parse_subscription_filter(%{filter: filter} = subscription) when filter in [nil, []],
    do: subscription

  defp parse_subscription_filter(%{filter: filter, resource: resource} = subscription) do
    case Ash.Filter.parse(resource, filter) do
      {:ok, parsed} -> Map.put(subscription, :filter, parsed)
      {:error, _reason} -> subscription
    end
  end

  defp parse_subscription_filter(subscription), do: subscription

  defp direct_parent_attribute_names(refs, resource) do
    Enum.reduce_while(refs, {:ok, []}, fn
      %Ash.Query.Ref{relationship_path: [], attribute: %{name: name}}, {:ok, names} ->
        if Ash.Resource.Info.attribute(resource, name) do
          {:cont, {:ok, [name | names]}}
        else
          {:halt, :error}
        end

      %Ash.Query.Ref{relationship_path: [], attribute: name}, {:ok, names}
      when is_atom(name) ->
        if Ash.Resource.Info.attribute(resource, name) do
          {:cont, {:ok, [name | names]}}
        else
          {:halt, :error}
        end

      _ref, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, names} -> {:ok, Enum.uniq(names)}
      :error -> :error
    end
  end

  defp candidate_entries(resource, new_record, old_record) do
    records = Enum.reject([new_record, old_record], &is_nil/1)

    indexed =
      resource
      |> subscribed_attributes()
      |> Enum.flat_map(fn attr ->
        records
        |> Enum.map(&Map.get(&1, attr))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.flat_map(fn value -> lookup(resource, attr, value) end)
      end)

    indexed ++ lookup(resource, :*, :*)
  end

  # The set of attributes any live subscription indexes for this
  # resource — small (bounded by declared relationships), maintained as a
  # separate live-subscription index so dispatch never copies subscription
  # parent records while discovering attribute names.
  defp subscribed_attributes(resource) do
    @resource_attrs
    |> ets_lookup(resource)
    |> Enum.map(fn {^resource, attr, _subscription_ref} -> attr end)
    |> Enum.uniq()
  end

  defp ets_lookup(table, key) do
    :ets.lookup(table, key)
  rescue
    ArgumentError -> []
  end

  defp ets_tab2list(table) do
    :ets.tab2list(table)
  rescue
    ArgumentError -> []
  end

  defp call_if_running(message, default) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, message)
    else
      default
    end
  end

  defp notification_tenant(notification) do
    get_in(notification, [Access.key(:changeset), Access.key(:tenant)]) ||
      get_in(notification, [Access.key(:changeset), Access.key(:context), :tenant]) ||
      get_in(notification, [Access.key(:changeset), Access.key(:context), "tenant"])
  end

  # A notification whose changeset carries NO tenant (background/queue-worker
  # writes such as AshQueue trigger actions) must OVER-deliver, never
  # under-deliver: the subscriber reloads through its own tenant-scoped,
  # policy-checked read, so a spurious hint costs one reload while a dropped
  # hint is a permanently stale page (notifications are latency hints; reload
  # is the correctness path). Tenant-tagged writes still match exactly.
  defp tenant_visible?(subscription, notification_tenant) do
    Map.has_key?(subscription, :tenant) and
      (is_nil(notification_tenant) or Map.get(subscription, :tenant) == notification_tenant)
  end

  defp safe_stage2_hit?(subscription, new_record, old_record) do
    case stage2_hit?(subscription, new_record, old_record) do
      {:error, error} ->
        Logger.warning(
          "AshUi notification filter evaluation failed open " <>
            "for #{inspect(Map.get(subscription, :resource))} " <>
            "subscription #{inspect(Map.get(subscription, :subscription_ref))}: #{inspect(error)}"
        )

        true

      hit? when is_boolean(hit?) ->
        hit?
    end
  rescue
    # broad rescue: an evaluator defect must not abort the notification batch;
    # fail open because the policy-checked reload is the correctness boundary.
    exception ->
      Logger.warning(
        "AshUi notification filter evaluation failed open " <>
          "for #{inspect(Map.get(subscription, :resource))} " <>
          "subscription #{inspect(Map.get(subscription, :subscription_ref))}: " <>
          Exception.message(exception)
      )

      true
  end

  defp stage2_hit?(%{filter: nil}, _new_record, _old_record), do: true
  defp stage2_hit?(%{filter: []}, _new_record, _old_record), do: true

  defp stage2_hit?(%{filter: %Ash.Filter{} = filter} = subscription, new_record, old_record) do
    domain =
      Map.get(subscription, :domain) ||
        AshUi.AshDomainFallback.ensure!(Map.fetch!(subscription, :resource))

    [new_record, old_record]
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce_while(false, fn record, _matched? ->
      case Ash.Filter.Runtime.filter_matches(
             domain,
             [record],
             filter,
             stage2_options(subscription)
           ) do
        {:ok, [_record]} -> {:halt, true}
        {:ok, []} -> {:cont, false}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp stage2_hit?(_subscription, _new_record, _old_record), do: true

  # Fork option (leanbob correspondence: `MatchIndex.Subscription.actor`): a
  # subscription may carry its session's `actor`, and the filter is then
  # evaluated as that actor. `filter_matches` loads the relationships the
  # filter walks with it, so a relationship whose own filter compares the actor
  # (a viewer's own role rows) loads as the page's read loaded it. Without it
  # that relationship loads empty and the filter never matches. A
  # subscription without the key is evaluated exactly as upstream evaluates it.
  defp stage2_options(subscription) do
    options = [parent: Map.get(subscription, :parent)]

    case Map.fetch(subscription, :actor) do
      {:ok, actor} -> Keyword.put(options, :actor, actor)
      :error -> options
    end
  end
end
