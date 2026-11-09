defmodule AshUi.Phoenix do
  @moduledoc """
  Primary Phoenix integration for routed AshUi resources.

  The `routes/1` macro discovers route declarations from Ash domains and mounts
  each resource through the shared LiveView host. At runtime this module
  creates or upserts the page's `:mount` action with the transport session,
  caches its compiled patch table, renders the current resource row, routes
  binding keys to Ash actions, reloads notification-backed relationships, and
  reconciles the resource's URL projection.

  Host applications keep ownership of their endpoint, router, session,
  authentication, and static assets. Authored UI remains in resource
  `:view` calculations; Phoenix supplies transport only.
  """

  use Phoenix.Component

  require Logger

  import Phoenix.LiveView,
    only: [
      attach_hook: 4,
      connected?: 1,
      render_with: 2
    ]

  alias AshUi.EventBinding
  alias AshUi.Phoenix.RenderTarget

  @dispatch_event "ash_ui:dispatch"
  @route_patch_event "ash_ui:route-params-patch"

  defmacro routes(opts) do
    routes = AshUi.Phoenix.Router.__routes_ast__(opts, __CALLER__)

    case Keyword.get(opts, :live_session, :ash_ui) do
      false ->
        routes

      live_session_name ->
        session =
          Keyword.get(
            opts,
            :session,
            {AshUi.Phoenix.LiveSession, :generate_session,
             [Keyword.get(opts, :session_opts, [])]}
          )

        live_session_opts =
          [session: session]
          |> maybe_put_live_session_opt(:on_mount, Keyword.get(opts, :on_mount))

        quote do
          live_session unquote(live_session_name), unquote(Macro.escape(live_session_opts)) do
            unquote(routes)
          end
        end
    end
  end

  defp maybe_put_live_session_opt(opts, _key, nil), do: opts
  defp maybe_put_live_session_opt(opts, key, value), do: Keyword.put(opts, key, value)

  @spec mount(module(), map(), map(), Phoenix.LiveView.Socket.t(), keyword()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def mount(resource, params, session, socket, opts \\ [])
      when is_atom(resource) and is_map(params) and is_map(session) and is_list(opts) do
    socket = assign(socket, :ash_ui_otp_app, otp_app(socket, opts))
    socket = assign(socket, :ash_ui_after_event, Keyword.get(opts, :after_event))

    context = opts |> Keyword.get(:context, %{}) |> Map.new()
    actor = Keyword.get(opts, :actor, Map.get(context, :current_user))

    tenant =
      case Keyword.fetch(opts, :tenant) do
        {:ok, tenant} ->
          tenant

        :error ->
          Map.get(context, :tenant) ||
            if is_map(actor) do
              Map.get(actor, :tenant) || Map.get(actor, "tenant")
            end
      end

    session_id = live_session_id(session, socket)
    connected? = connected?(socket)
    view = Keyword.get(opts, :view, :view)
    transport_pid = if connected?, do: session_pid(socket)

    if transport_pid do
      # The registry, rather than the Bridge mailbox, observes transport
      # death. This lets it hard-stop a Bridge whose queue can no longer
      # drain and releases process-owned store snapshots/folds promptly.
      AshUi.Notification.MatchIndex.track_session_owner(transport_pid, self())
    end

    {record, page_title, action_effects} =
      mount_record_for_phase!(resource, view, params, session_id, actor,
        context: context,
        tenant: tenant,
        # A disconnected render is a short-lived HTTP process, not the
        # browser session owner. The connected transport claims the row after
        # consuming the one-shot handoff.
        session_pid: transport_pid,
        # LiveView runs mount twice per fresh navigation (static render,
        # then live attach). Actions that must run once per navigation key
        # off this declared transport fact.
        mount_phase: if(connected?, do: :live, else: :static),
        connected?: connected?
      )

    _table = AshUi.Patch.Compiler.cached_table(resource, view, target: RenderTarget)

    socket =
      socket
      |> assign(:ash_ui_resource, resource)
      |> assign(:ash_ui_view, view)
      |> assign(:ash_ui_session_id, session_id)
      |> assign(:ash_ui_session_pid, transport_pid)
      |> assign(:ash_ui_actor, actor)
      |> assign(:ash_ui_tenant, tenant)
      |> assign(:ash_ui_context, context)
      |> assign(:ash_ui_record, record)
      |> assign(:ash_ui_changed, :all)
      |> assign(:ash_ui_errors, [])
      |> assign(:ash_ui_params, params)
      |> assign(:ash_ui_connected?, connected?)
      |> assign_page_title(record, page_title)
      |> maybe_register_notifications()
      |> install_bridge_runtime()
      |> maybe_push_action_effects(action_effects, connected?)

    {:ok, socket}
  rescue
    error in [Ash.Error.Forbidden, Ash.Error.Invalid, Ash.Error.Unknown] ->
      Logger.error(
        "AshUi mount failed for #{inspect(resource)}\n" <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      {:ok,
       socket
       |> assign(:ash_ui_record, nil)
       |> assign(:ash_ui_mount_error, "This view could not be opened.")}
  end

  # The page row: session-instance upsert through the resource's own mount
  # action — route/query params bind by declared argument name; session_id
  # arrives via changeset context (the AshUi.Session seam).
  defp mount_record!(resource, params, session_id, actor, opts) do
    effect_ref = make_ref()

    context =
      opts
      |> Keyword.get(:context, %{})
      |> session_context(session_id, opts)
      |> put_action_effect_sink(effect_ref)

    opts = Keyword.put(opts, :context, context)

    record =
      resource
      |> mount_record_unloaded!(params, session_id, actor, opts)
      |> load_view_deps!(
        actor: actor,
        tenant: Keyword.get(opts, :tenant),
        context: context
      )

    {record, take_action_effects(effect_ref)}
  end

  defp mount_record_for_phase!(resource, view, params, session_id, actor, opts) do
    connected? = Keyword.get(opts, :connected?, true)
    handoff_key = mount_handoff_key(resource, view, params, session_id, actor, opts)
    effect_ref = make_ref()

    context =
      opts
      |> Keyword.get(:context, %{})
      |> session_context(session_id, opts)
      |> put_action_effect_sink(effect_ref)

    opts = Keyword.put(opts, :context, context)

    {record, page_title, action_effects} =
      case connected? && AshUi.Notification.MatchIndex.take_session_handoff(handoff_key) do
        %{
          record: %{__struct__: ^resource} = static,
          page_title: page_title,
          action_effects: action_effects
        } ->
          # The static phase already upserted and loaded the durable
          # session-scoped row. Its one-shot handoff is the connected phase's
          # mount result; rerunning even an "unloaded" mount action repeats
          # action-owned reads/effects and defeats that row identity.
          AshUi.Notification.MatchIndex.track_session_rows(
            resource,
            session_id,
            Keyword.get(opts, :session_pid),
            Keyword.get(opts, :tenant)
          )

          {static, page_title, action_effects}

        _missing_or_static_phase ->
          record =
            resource
            |> mount_record_unloaded!(params, session_id, actor, opts)
            |> load_view_deps!(
              actor: actor,
              tenant: Keyword.get(opts, :tenant),
              context: context
            )

          {record,
           calculate_page_title(record,
             actor: actor,
             tenant: Keyword.get(opts, :tenant),
             context: Keyword.get(opts, :context, %{})
           ), take_action_effects(effect_ref)}
      end

    unless connected? do
      AshUi.Notification.MatchIndex.put_session_handoff(handoff_key, %{
        record: record,
        page_title: page_title,
        action_effects: action_effects
      })
    end

    {record, page_title, action_effects}
  end

  defp mount_record_unloaded!(resource, params, session_id, actor, opts) do
    measure_mount_layer(:page_row_create, fn ->
      args = mount_args(resource, params)
      context = session_context(Keyword.get(opts, :context, %{}), session_id, opts)

      changeset =
        measure_mount_layer(:page_row_changeset, fn ->
          Ash.Changeset.for_create(resource, :mount, args,
            actor: actor,
            tenant: Keyword.get(opts, :tenant),
            context: context,
            domain: page_domain(resource),
            upsert?: true,
            upsert_identity: session_identity_name!(resource)
          )
        end)

      measure_mount_layer(:page_row_persist, fn ->
        Ash.create!(changeset, domain: page_domain(resource))
      end)
    end)
  end

  defp mount_handoff_key(resource, view, params, session_id, actor, opts) do
    {
      :ash_ui_mount,
      session_id,
      resource,
      view,
      params,
      actor,
      Keyword.get(opts, :tenant)
    }
  end

  defp session_context(context, session_id, opts) do
    context
    |> Map.new()
    |> Map.put(:session_id, session_id)
    |> Map.put(:ash_ui_mount_phase, Keyword.get(opts, :mount_phase, :live))
    |> Map.update(
      :shared,
      %{ash_ui_session_pid: Keyword.get(opts, :session_pid)},
      fn
        shared when is_map(shared) ->
          Map.put(shared, :ash_ui_session_pid, Keyword.get(opts, :session_pid))

        _other ->
          %{ash_ui_session_pid: Keyword.get(opts, :session_pid)}
      end
    )
  end

  defp action_context(socket, dispatch_ref \\ nil) do
    context =
      session_context(
        socket.assigns[:ash_ui_context] || %{},
        socket.assigns[:ash_ui_session_id],
        session_pid: session_pid(socket)
      )

    if dispatch_ref do
      context
      |> Map.put(:ash_ui_dispatch_ref, dispatch_ref)
      |> put_action_effect_sink(dispatch_ref)
      |> Map.update(:shared, %{ash_ui_dispatch_ref: dispatch_ref}, fn
        shared when is_map(shared) -> Map.put(shared, :ash_ui_dispatch_ref, dispatch_ref)
        _other -> %{ash_ui_dispatch_ref: dispatch_ref}
      end)
    else
      context
    end
  end

  defp put_action_effect_sink(context, effect_ref) do
    context
    |> Map.put(:ash_ui_action_effect_pid, self())
    |> Map.put(:ash_ui_action_effect_ref, effect_ref)
    |> Map.update(
      :shared,
      %{
        ash_ui_action_effect_pid: self(),
        ash_ui_action_effect_ref: effect_ref
      },
      fn
        shared when is_map(shared) ->
          shared
          |> Map.put(:ash_ui_action_effect_pid, self())
          |> Map.put(:ash_ui_action_effect_ref, effect_ref)

        _other ->
          %{
            ash_ui_action_effect_pid: self(),
            ash_ui_action_effect_ref: effect_ref
          }
      end
    )
  end

  defp session_identity_name!(resource) do
    case Enum.find(Ash.Resource.Info.identities(resource), fn identity ->
           :session_id in List.wrap(Map.get(identity, :keys, []))
         end) do
      %{name: name} -> name
      _none -> raise ArgumentError, "#{inspect(resource)} has no session-scoped identity"
    end
  end

  defp mount_args(resource, params) do
    names =
      resource
      |> declared_mount_input_names()
      |> Enum.map(&to_string/1)
      |> Enum.uniq()

    Map.take(params, names)
  end

  defp declared_mount_input_names(resource) do
    route_names =
      resource
      |> AshUi.Location.routes()
      |> Enum.flat_map(fn {path, query_names} ->
        route_path_param_names(path) ++ List.wrap(query_names)
      end)

    explicit_mount_names =
      Spark.Dsl.Extension.get_persisted(
        resource,
        :ash_ui_explicit_mount_arguments,
        []
      )

    route_names ++ explicit_mount_names
  end

  defp route_path_param_names(path) when is_binary(path) do
    ~r/(^|\/)[:*]([A-Za-z_][A-Za-z0-9_]*)(?=\/|$)/
    |> Regex.scan(path, capture: :all_but_first)
    |> Enum.map(fn [_slash, name] -> name end)
  end

  defp page_domain(resource) do
    Ash.Resource.Info.domain(resource) || AshUi.AshDomainFallback
  end

  # The :view calculation's derived dependency set (relationships, nested
  # loads) — the record must carry it before any render, or view-read
  # relationships stay NotLoaded.
  defp load_view_deps!(%resource{} = record, opts) when is_list(opts) do
    measure_mount_layer(:view_load_calc, fn ->
      case AshUi.view_load(resource) do
        [] ->
          record

        loads ->
          load_opts =
            [
              actor: Keyword.get(opts, :actor),
              tenant: Keyword.get(opts, :tenant),
              context: Keyword.get(opts, :context, %{}),
              domain: page_domain(resource),
              authorize?: true,
              lazy?: true,
              reuse_values?: true
            ]

          {relationship_loads, view_field_loads} =
            Enum.split_with(loads, fn
              {relationship, _nested} when is_atom(relationship) ->
                not is_nil(Ash.Resource.Info.relationship(resource, relationship))

              relationship when is_atom(relationship) ->
                not is_nil(Ash.Resource.Info.relationship(resource, relationship))

              _other ->
                false
            end)

          record =
            case relationship_loads do
              [] -> record
              _relationships -> Ash.load!(record, relationship_loads, load_opts)
            end

          Ash.load!(record, view_field_loads, load_opts)
      end
    end)
  end

  defp live_session_id(session, _socket) do
    session["ash_ui_session_id"] || AshUi.Session.generated_session_id()
  end

  @spec runtime_handle_params(map(), String.t() | map() | nil, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def runtime_handle_params(params, uri, socket) when is_map(params) do
    socket = put_current_location(socket, uri)
    current = socket.assigns[:ash_ui_record]

    destination =
      socket.assigns[:live_action] ||
        case current do
          %resource{} -> resource
          _missing -> nil
        end

    if projected_location_callback?(socket) and is_struct(current, destination) do
      {:noreply,
       socket
       |> assign(:ash_ui_pending_location, nil)
       |> assign(:ash_ui_params, params)}
    else
      case {
        current,
        socket.assigns[:ash_ui_params],
        destination
      } do
        {%resource{} = _record, ^params, resource} ->
          # The hook receives the initial handle_params callback immediately
          # after mount. The mount action already produced this exact row;
          # running it again would duplicate action-owned mount effects.
          {:noreply, socket}

        {%resource{} = record, _previous_params, resource} ->
          {updated, action_effects} =
            resource
            |> mount_record!(
              params,
              socket.assigns.ash_ui_session_id,
              socket.assigns[:ash_ui_actor],
              tenant: socket.assigns[:ash_ui_tenant],
              context: socket.assigns[:ash_ui_context] || %{},
              session_pid: session_pid(socket)
            )

          {:noreply,
           socket
           |> put_record(record, updated, params)
           |> push_action_effects(action_effects)}

        {%_{} = _record, _previous_params, resource}
        when is_atom(resource) and not is_nil(resource) ->
          {updated, action_effects} =
            resource
            |> mount_record!(
              params,
              socket.assigns.ash_ui_session_id,
              socket.assigns[:ash_ui_actor],
              tenant: socket.assigns[:ash_ui_tenant],
              context: socket.assigns[:ash_ui_context] || %{},
              session_pid: session_pid(socket)
            )

          view = socket.assigns[:ash_ui_view] || :view
          _table = AshUi.Patch.Compiler.cached_table(resource, view, target: RenderTarget)

          {:noreply,
           socket
           |> assign(:ash_ui_resource, resource)
           |> assign(:ash_ui_record, updated)
           |> assign(:ash_ui_changed, :all)
           |> assign(:ash_ui_errors, [])
           |> assign(:ash_ui_params, params)
           |> assign_page_title(updated)
           |> register_notifications()
           |> push_action_effects(action_effects)}

        _missing ->
          {:noreply, socket}
      end
    end
  end

  @spec runtime_handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def runtime_handle_event("ash_ui:dispatch:" <> binding_key, params, socket)
      when is_map(params) do
    params =
      params
      |> normalize_dispatch_params()
      |> Map.put("binding", binding_key)

    dispatch_binding(params, socket)
  end

  def runtime_handle_event(@dispatch_event, params, socket) when is_map(params) do
    dispatch_binding(normalize_dispatch_params(params), socket)
  end

  def runtime_handle_event(@route_patch_event, params, socket) when is_map(params) do
    runtime_handle_params(route_patch_params(params), nil, socket)
  end

  def runtime_handle_event(_event, _params, socket), do: {:noreply, socket}

  defp put_current_location(socket, uri) when is_binary(uri) do
    parsed = URI.parse(uri)

    location =
      if parsed.query in [nil, ""], do: parsed.path, else: parsed.path <> "?" <> parsed.query

    assign(socket, :ash_ui_location, location)
  end

  defp put_current_location(socket, _uri), do: socket

  defp projected_location_callback?(socket) do
    case socket.assigns[:ash_ui_pending_location] do
      pending when is_binary(pending) ->
        normalize_location(pending) == socket.assigns[:ash_ui_location]

      _none ->
        false
    end
  end

  defp normalize_location(uri) when is_binary(uri) do
    parsed = URI.parse(uri)
    if parsed.query in [nil, ""], do: parsed.path, else: parsed.path <> "?" <> parsed.query
  end

  # Registration-free dispatch: resolve the binding key against the CURRENT
  # record, assemble the action payload (evaluated action_input + typed
  # event payload fields), run the action on the row, derive the changed
  # set from old/new.
  defp dispatch_binding(params, socket) do
    case dispatch_binding_key(params) do
      nil ->
        target = Map.get(params, "action", Map.get(params, :action))

        Logger.warning(
          "AshUi dispatch rejected a client-named action without a compiled binding"
        )

        handle_dispatch_result(
          {:error, {:unknown_target, target}},
          socket,
          :unknown_target,
          %{}
        )

      _binding_key ->
        dispatch_event_binding(params, socket)
    end
  end

  defp dispatch_event_binding(params, socket) do
    with %_{} = record <- socket.assigns[:ash_ui_record],
         binding_key when is_binary(binding_key) and binding_key != "" <-
           dispatch_binding_key(params),
         {:ok, %EventBinding{} = binding, target} <-
           AshUi.Patch.Bindings.resolve(record, binding_key, params,
             table: current_table(socket),
             actor: socket.assigns[:ash_ui_actor],
             tenant: socket.assigns[:ash_ui_tenant],
             context: socket.assigns[:ash_ui_context] || %{},
             session_id: socket.assigns[:ash_ui_session_id]
           ) do
      # transport metadata never reaches the action input
      params =
        Map.drop(params, [
          "binding",
          :binding,
          "phx-value-binding",
          :"phx-value-binding",
          "data-ash-ui-binding",
          "value-binding"
        ])

      case EventBinding.runtime_event(binding, params) do
        :ignore ->
          {:noreply, socket}

        {:dispatch, _path, action, payload} ->
          table = current_table(socket)

          run_bound_action(
            socket,
            target,
            action,
            payload,
            AshUi.Patch.Compiler.dispatch_boundary(binding_key, table),
            AshUi.Patch.Compiler.dispatch_reload_paths(binding_key, table)
          )
      end
    else
      # An unresolvable key is an ordinary unknown-target error and MUST
      # surface as page error state (§5) — never a silent no-op that
      # leaves the control looking dead.
      :error ->
        Logger.warning(
          "AshUi dispatch could not resolve binding #{inspect(params["binding"])}"
        )

        handle_dispatch_result(
          {:error, {:unknown_target, params["binding"]}},
          socket,
          :unknown_target,
          %{}
        )

      _other ->
        {:noreply, socket}
    end
  end

  # ONE dispatch call — Dispatch.run is backing-blind. Root writes flow
  # through put_record's diff; a bound result is refreshed according to the
  # owner returned by Dispatch below.
  defp run_bound_action(socket, {:root}, action, payload, _boundary, reload_paths),
    do: run_page_action(socket, action, payload, reload_paths)

  defp run_bound_action(socket, target, action, payload, boundary, reload_paths)
       when is_atom(action) do
    dispatch_ref = make_ref()

    result =
      measure_action(socket, socket.assigns.ash_ui_record.__struct__, action, fn ->
        AshUi.Patch.Dispatch.run(
          socket.assigns.ash_ui_record,
          target,
          action,
          payload,
          actor: socket.assigns[:ash_ui_actor],
          tenant: socket.assigns[:ash_ui_tenant],
          context: action_context(socket, dispatch_ref)
        )
      end)

    # Notification-derived paths are DATA facts (the dispatch echo of the
    # action's own writes); compiler event paths are RENDER scope only. Data
    # reloads key off the former, differential re-render addressing off both.
    data_paths = take_dispatch_reload_paths(dispatch_ref)
    action_effects = take_action_effects(dispatch_ref)
    render_paths = reload_paths ++ data_paths

    case result do
      {:ok, updated_owner} ->
        refresh_after_bound_action(
          push_action_effects(socket, action_effects),
          updated_owner,
          action,
          payload,
          boundary,
          dispatch_ref,
          {render_paths, data_paths}
        )

      {:error, reason} ->
        handle_dispatch_result({:error, reason}, socket, action, payload)
    end
  end

  defp run_bound_action(socket, _target, _action, _payload, _boundary, _reload_paths),
    do: {:noreply, socket}

  # Embedded dispatch returns the freshly persisted parent, just as a root
  # action does. Reuse it and load only its view dependencies; only a target
  # backed by another row still needs the page re-read below.
  defp refresh_after_bound_action(
         socket,
         %_{} = updated_owner,
         action,
         payload,
         boundary,
         dispatch_ref,
         {render_paths, data_paths}
       ) do
    current = socket.assigns.ash_ui_record

    if AshUi.Reload.same_row?(current, updated_owner) do
      socket =
        socket
        |> clear_dispatch_errors()
        |> run_after_event(action, payload, updated_owner)

      updated = refresh_page_action_record!(socket, updated_owner, data_paths)

      socket =
        socket
        |> put_record(
          current,
          updated,
          socket.assigns[:ash_ui_params],
          render_paths
        )
        |> invalidate_boundary(boundary)

      {:noreply, socket}
    else
      reload_after_bound_action(socket, action, payload, boundary, dispatch_ref)
    end
  end

  defp refresh_after_bound_action(
         socket,
         _other_owner,
         action,
         payload,
         boundary,
         dispatch_ref,
         _reload_paths
       ),
       do: reload_after_bound_action(socket, action, payload, boundary, dispatch_ref)

  # A dispatch to a child target wrote THAT instance's state — the bridge
  # knows, so the owning boundary re-renders synchronously (no waiting on
  # the notification round trip). The boundary is the page-space child
  # slot whose subtree owns the binding key's chain head.
  defp reload_after_bound_action(socket, action, payload, boundary, _dispatch_ref) do
    case AshUi.reload(socket.assigns.ash_ui_record,
           actor: socket.assigns[:ash_ui_actor],
           tenant: socket.assigns[:ash_ui_tenant],
           context: action_context(socket),
           domain: page_domain(socket.assigns.ash_ui_record.__struct__),
           authorize?: true
         ) do
      {:ok, reloaded} ->
        record =
          load_view_deps!(reloaded,
            actor: socket.assigns[:ash_ui_actor],
            tenant: socket.assigns[:ash_ui_tenant],
            context: action_context(socket)
          )

        socket =
          socket
          |> put_record(
            socket.assigns.ash_ui_record,
            record,
            socket.assigns[:ash_ui_params]
          )
          |> clear_dispatch_errors()
          |> invalidate_boundary(boundary)

        {:noreply, run_after_event(socket, action, payload)}

      {:error, reason} ->
        handle_dispatch_result({:error, reason}, socket, action, payload)
    end
  end

  defp invalidate_boundary(socket, boundary) when boundary in [nil, []], do: socket

  defp invalidate_boundary(socket, addrs) when is_list(addrs) do
    table = current_table(socket)

    addrs = Enum.map(addrs, &invalidation_address(table, &1))

    changed =
      case socket.assigns[:ash_ui_changed] do
        %MapSet{} = pending -> MapSet.union(pending, MapSet.new(addrs))
        _other -> MapSet.new(addrs)
      end

    assign(socket, :ash_ui_changed, changed)
  end

  defp invalidation_address(_table, {:entry, _addr, _key} = marker), do: marker

  defp invalidation_address(%AshUi.Patch.Table{} = table, addr) do
    case AshUi.Patch.Compiler.slot_path(table, addr) do
      {:ok, slot, _keyed_ancestors} -> Map.get(slot.meta, :owner_addr, slot.addr)
      _missing -> addr
    end
  end

  defp invalidation_address(_table, addr), do: addr

  defp run_page_action(socket, action, payload, reload_paths) when is_atom(action) do
    case socket.assigns[:ash_ui_record] do
      %_{} = record ->
        payload = action_payload(record.__struct__, action, payload)
        dispatch_ref = make_ref()

        result =
          measure_action(socket, record.__struct__, action, fn ->
            AshUi.Patch.Dispatch.run(record, {:root}, action, payload,
              actor: socket.assigns[:ash_ui_actor],
              tenant: socket.assigns[:ash_ui_tenant],
              context: action_context(socket, dispatch_ref)
            )
          end)

        data_paths = take_dispatch_reload_paths(dispatch_ref)
        action_effects = take_action_effects(dispatch_ref)
        render_paths = reload_paths ++ data_paths

        socket =
          if match?({:ok, _value}, result),
            do: push_action_effects(socket, action_effects),
            else: socket

        case {Ash.Resource.Info.action(record.__struct__, action), result} do
          {%{type: :action}, {:ok, _record}} ->
            reload_after_bound_action(socket, action, payload, nil, dispatch_ref)

          {_action, result} ->
            handle_dispatch_result(
              result,
              socket,
              action,
              payload,
              dispatch_ref,
              {render_paths, data_paths}
            )
        end

      _missing ->
        {:noreply, socket}
    end
  end

  defp run_page_action(socket, _action, _payload, _reload_paths), do: {:noreply, socket}

  defp action_payload(resource, action, payload)
       when is_atom(resource) and is_atom(action) and is_map(payload) do
    Map.take(payload, MapSet.to_list(Ash.Resource.Info.action_inputs(resource, action)))
  end

  defp action_payload(payload, resource, action) when is_map(payload),
    do: action_payload(resource, action, payload)

  defp measure_action(socket, resource, action, fun)
       when is_atom(resource) and is_atom(action) and is_function(fun, 0) do
    started = System.monotonic_time()

    try do
      result = fun.()
      duration = System.monotonic_time() - started
      outcome = if match?({:ok, _value}, result), do: :ok, else: :error

      emit_action_timing(socket, resource, action, outcome, duration)
      result
    catch
      kind, reason ->
        duration = System.monotonic_time() - started
        emit_action_timing(socket, resource, action, :exception, duration)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp emit_action_timing(socket, resource, action, outcome, duration) do
    metadata = %{
      action: action,
      adapter: :phoenix,
      outcome: outcome,
      resource: resource,
      session_id: socket.assigns[:ash_ui_session_id]
    }

    :telemetry.execute(
      [:ash_ui, :phoenix, :action],
      %{duration: duration},
      metadata
    )
  end

  # The O(1) dispatch contract lives in AshUi.Reload — the ONE policy
  # module both bridges call. This wrapper only supplies the transport's
  # scope and raises on reload failure (LiveView error surface).
  defp refresh_page_action_record!(socket, %_{} = updated, data_paths) do
    case AshUi.Reload.after_dispatch(
           socket.assigns.ash_ui_record,
           updated,
           data_paths,
           actor: socket.assigns[:ash_ui_actor],
           tenant: socket.assigns[:ash_ui_tenant],
           context: action_context(socket),
           domain: page_domain(updated.__struct__),
           authorize?: true
         ) do
      {:ok, record} -> record
      {:error, reason} -> raise reason
    end
  end

  defp root_attributes_changed?(%resource{} = old, %resource{} = new) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.any?(fn attribute -> Map.get(old, attribute.name) != Map.get(new, attribute.name) end)
  end

  defp take_dispatch_reload_paths(dispatch_ref, acc \\ []) do
    receive do
      {:ash_ui_notification, subscription_ref,
       %{
         notification: %{
           changeset: %{context: %{ash_ui_dispatch_ref: ^dispatch_ref}}
         }
       }} ->
        take_dispatch_reload_paths(
          dispatch_ref,
          put_notification_reload_path(acc, subscription_ref)
        )

      {:ash_ui_notification, subscription_ref,
       %{
         notification: %{
           changeset: %{
             context: %{shared: %{ash_ui_dispatch_ref: ^dispatch_ref}}
           }
         }
       }} ->
        take_dispatch_reload_paths(
          dispatch_ref,
          put_notification_reload_path(acc, subscription_ref)
        )
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp take_action_effects(effect_ref, acc \\ []) do
    receive do
      {:ash_ui_action_effect, ^effect_ref, %AshUi.ActionEffect{} = effect} ->
        take_action_effects(effect_ref, [effect | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp push_action_effects(socket, effects) when is_list(effects) do
    Enum.reduce(effects, socket, fn %AshUi.ActionEffect{} = effect, socket ->
      Phoenix.LiveView.push_event(
        socket,
        AshUi.ActionEffect.event_name(effect),
        AshUi.ActionEffect.payload(effect)
      )
    end)
  end

  defp maybe_push_action_effects(socket, effects, true), do: push_action_effects(socket, effects)
  defp maybe_push_action_effects(socket, _effects, false), do: socket

  defp put_notification_reload_path(acc, subscription_ref) do
    case notification_reload_scope(subscription_ref) do
      :root -> acc
      path when is_list(path) -> [path | acc]
    end
  end

  defp handle_dispatch_result(result, socket, action, payload),
    do: handle_dispatch_result(result, socket, action, payload, nil, {[], []})

  defp handle_dispatch_result(
         {:ok, updated},
         socket,
         action,
         payload,
         _dispatch_ref,
         {render_paths, data_paths}
       ) do
    socket =
      socket
      |> clear_dispatch_errors()
      |> run_after_event(action, payload, updated)

    updated = refresh_page_action_record!(socket, updated, data_paths)

    socket =
      socket
      |> put_record(
        socket.assigns.ash_ui_record,
        updated,
        socket.assigns[:ash_ui_params],
        render_paths
      )
      |> reconcile_location(updated)

    {:noreply, socket}
  end

  # Errors SURFACE as page error state — a failed dispatch must never be a
  # silent no-op that leaves the control looking dead. Child boundaries
  # re-render too: the failing action may have committed writes to OTHER
  # session rows before erroring (a transient notice row is the canonical case),
  # and children resolve their rows fresh at render.
  defp handle_dispatch_result(
         {:error, reason},
         socket,
         action,
         _payload,
         _dispatch_ref,
         _reload_paths
       ) do
    Logger.warning("AshUi dispatch #{inspect(action)} failed: #{inspect(reason)}")

    changed =
      case {error_slot_addresses(socket), child_boundary_addresses(socket)} do
        {%MapSet{} = errors, %MapSet{} = children} -> MapSet.union(errors, children)
        {errors, _children} -> errors
      end

    socket =
      socket
      |> assign(:ash_ui_errors, dispatch_error_list(reason))
      |> assign(:ash_ui_changed, changed)

    {:noreply, socket}
  end

  # A failed action's Ash error class distributes through the patch cycle:
  # field-path'd entries reach field-name-bound elements (aria-invalid +
  # message), everything re-renders through exactly the error slots.
  defp dispatch_error_list(reason), do: AshUi.dispatch_errors(reason)

  defp error_slot_addresses(socket) do
    case current_table(socket) do
      %AshUi.Patch.Table{error_slots: addrs} -> MapSet.new(addrs)
      _missing -> :all
    end
  end

  defp child_boundary_addresses(socket) do
    case current_table(socket) do
      %AshUi.Patch.Table{} = table ->
        for {_id, %{kind: :child} = slot} <-
              AshUi.Patch.Table.root_slots(table),
            into: MapSet.new(),
            do: Map.get(slot.meta, :owner_addr, slot.addr)

      _missing ->
        :all
    end
  end

  defp current_table(socket) do
    case socket.assigns[:ash_ui_resource] do
      nil ->
        nil

      resource ->
        view = socket.assigns[:ash_ui_view] || :view
        AshUi.Patch.Compiler.cached_table(resource, view, target: RenderTarget)
    end
  end

  # Errors are per-dispatch transients: a successful dispatch clears them
  # and re-renders their slots clean.
  defp clear_dispatch_errors(socket) do
    case socket.assigns[:ash_ui_errors] do
      errors when errors in [nil, []] ->
        socket

      _present ->
        invalidated =
          [error_slot_addresses(socket), child_boundary_addresses(socket)]
          |> Enum.reduce(MapSet.new(), fn
            %MapSet{} = addrs, acc -> MapSet.union(acc, addrs)
            :all, _acc -> :all
          end)

        changed =
          case {socket.assigns[:ash_ui_changed], invalidated} do
            {%MapSet{} = changed, %MapSet{} = addrs} -> MapSet.union(changed, addrs)
            {_other, addrs} -> addrs
          end

        socket
        |> assign(:ash_ui_errors, [])
        |> assign(:ash_ui_changed, changed)
    end
  end

  # The browser location is a projection of route-declared state (DESIGN
  # §8): the route template filled from the CURRENT row, unless the
  # declared location expression projects elsewhere. Patch within the
  # page's own template; navigate outside it. Mount/handle_params are the
  # inverse direction, so reconciliation converges in one hop.
  @doc false
  def reconcile_location(%{redirected: nil} = socket, %_{} = record) do
    case socket.assigns[:ash_ui_location] do
      current when is_binary(current) ->
        preserved_query_params =
          (socket.assigns[:ash_ui_context] || %{})
          |> Map.get(:shared, %{})
          |> Map.get(:ash_ui_preserved_query_params, %{})

        case AshUi.Location.project(record, current,
               actor: socket.assigns[:ash_ui_actor],
               tenant: socket.assigns[:ash_ui_tenant],
               context: socket.assigns[:ash_ui_context] || %{},
               preserve_query_params: preserved_query_params
             ) do
          {:patch, target} ->
            socket
            |> assign(:ash_ui_pending_location, target)
            |> Phoenix.LiveView.push_patch(to: target)

          {:navigate, target} ->
            if AshUi.Location.navigation_kind(
                 AshUi.Location.navigation_routes(record.__struct__),
                 target
               ) == :patch do
              socket
              |> assign(:ash_ui_pending_location, target)
              |> Phoenix.LiveView.push_patch(to: target)
            else
              Phoenix.LiveView.push_navigate(socket, to: target)
            end

          :unchanged ->
            socket
        end

      _missing ->
        socket
    end
  end

  def reconcile_location(socket, _record), do: socket

  defp run_after_event(socket, action, payload),
    do: run_after_event(socket, action, payload, socket.assigns[:ash_ui_record])

  defp run_after_event(socket, action, payload, record) do
    case socket.assigns[:ash_ui_after_event] do
      callback when is_function(callback, 4) ->
        callback.(action, payload, socket, record)

      {module, function, extra_args} when is_atom(module) and is_atom(function) ->
        apply(module, function, [
          action,
          payload,
          socket,
          record | extra_args
        ])

      _none ->
        socket
    end
  end

  # Notifications are latency hints; reload is the correctness path. A
  # background action may inherit the dispatch ref of the event that created
  # its durable intent, so a later notification with that ref is new work, not
  # a duplicate of the synchronous dispatch reload.
  # Unrelated mailbox traffic belongs to the host LiveView and is untouched.
  @spec runtime_handle_info(term(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def runtime_handle_info({:ash_ui_notification, _ref, _event} = notification, socket) do
    notification
    |> collect_notifications([])
    |> reload_notification_batch(socket)
    |> drain_notification_batches()
  end

  def runtime_handle_info(_message, socket), do: {:noreply, socket}

  defp collect_notifications(notification, acc) do
    acc = [notification | acc]

    receive do
      {:ash_ui_notification, _ref, _event} = next ->
        collect_notifications(next, acc)
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp reload_notification_batch(notifications, socket) do
    reload_scope =
      notifications
      |> Enum.map(fn {:ash_ui_notification, ref, _event} ->
        notification_reload_scope(ref)
      end)
      |> then(fn scopes ->
        if :root in scopes do
          :root
        else
          Enum.uniq(scopes)
        end
      end)

    measure_notification_reload(socket, reload_scope, notifications, fn ->
      case socket.assigns[:ash_ui_record] do
        %_{} = record ->
          opts =
            [
              actor: socket.assigns[:ash_ui_actor],
              tenant: socket.assigns[:ash_ui_tenant],
              context: action_context(socket),
              domain: page_domain(record.__struct__),
              authorize?: true
            ]

          reload_result =
            case reload_scope do
              :root -> AshUi.reload_scope(record, :root, opts)
              paths -> AshUi.reload_dependencies(record, paths, opts)
            end

          case reload_result do
            {:ok, reloaded} ->
              reloaded =
                if reload_scope == :root do
                  record
                  |> AshUi.preserve_loaded_relationships(reloaded)
                  |> load_view_deps!(
                    actor: socket.assigns[:ash_ui_actor],
                    tenant: socket.assigns[:ash_ui_tenant],
                    context: action_context(socket)
                  )
                else
                  reloaded
                end

              {:noreply,
               socket
               |> put_record(
                 record,
                 reloaded,
                 socket.assigns[:ash_ui_params],
                 if(is_list(reload_scope), do: reload_scope, else: [])
               )
               |> reconcile_location(reloaded)}

            {:error, reason} ->
              handle_dispatch_result({:error, reason}, socket, :notification_reload, %{})
          end

        _missing ->
          {:noreply, socket}
      end
    end)
  end

  # MatchIndex invalidations are latency hints for durable facts, and one
  # publication commonly writes several related facts in one worker turn.
  # Consume only notifications already waiting, reload all of their distinct
  # relationship paths in one Ash load, and let LiveView render the accumulated
  # changed-address set once. There is no debounce or timer here: an isolated
  # notification still renders immediately.
  defp drain_notification_batches({:noreply, socket}) do
    receive do
      {:ash_ui_notification, _ref, _event} = notification ->
        notification
        |> collect_notifications([])
        |> reload_notification_batch(socket)
        |> drain_notification_batches()
    after
      0 -> {:noreply, socket}
    end
  end

  defp measure_notification_reload(socket, reload_scope, notifications, fun)
       when is_function(fun, 0) do
    started = System.monotonic_time()

    try do
      fun.()
    after
      :telemetry.execute(
        [:ash_ui, :phoenix, :notification, :reload],
        %{duration: System.monotonic_time() - started},
        %{
          adapter: :phoenix,
          notification_count: length(notifications),
          notification_kinds:
            Enum.map(notifications, fn
              {:ash_ui_notification, _ref,
               %{resource: resource, notification: %{action: %{name: name}}}} ->
                {resource, name}

              _other ->
                nil
            end),
          reload_scope: reload_scope,
          resource: socket.assigns.ash_ui_record.__struct__,
          session_id: socket.assigns[:ash_ui_session_id]
        }
      )
    end
  end

  defp notification_reload_scope(ref) do
    case AshUi.Notification.MatchIndex.subscription(ref) do
      %{reload_scope: scope} -> scope
      _missing -> :root
    end
  end

  @spec runtime_terminate(term(), Phoenix.LiveView.Socket.t()) :: :ok
  # Session rows outlive an individual LiveView because routed navigation can
  # replace the Bridge on the same transport. Orderly teardown only releases
  # this owner; transport death is what sweeps all session rows.
  def runtime_terminate(_reason, socket) do
    if session_pid = socket.assigns[:ash_ui_session_pid] do
      AshUi.Notification.MatchIndex.release_session_owner(session_pid, self())
    end

    :ok
  end

  # The pid whose lifetime IS the session: the websocket transport when
  # connected (survives push_navigate), the caller otherwise.
  defp session_pid(socket) do
    if connected?(socket) do
      Phoenix.LiveView.transport_pid(socket) || self()
    else
      self()
    end
  end

  defp put_record(socket, %_{} = old, %_{} = new, params),
    do: put_record(socket, old, new, params, [])

  defp put_record(socket, %_{} = old, %_{} = new, params, changed_paths) do
    resource = new.__struct__
    view = socket.assigns[:ash_ui_view] || :view
    table = AshUi.Patch.Compiler.cached_table(resource, view, target: RenderTarget)

    changed =
      if changed_paths != [] and not root_attributes_changed?(old, new) do
        changed_paths =
          changed_paths
          |> Kernel.++(
            resource
            |> AshUi.Reload.dependent_roots_for_paths(changed_paths)
            |> Enum.map(&[&1])
          )
          |> Enum.uniq()

        AshUi.Patch.Runtime.changed_addresses_for_paths(table, changed_paths)
      else
        AshUi.Patch.Runtime.changed_addresses(table, old, new)
      end

    # Renders are not one-per-transition: a push_patch from handle_event
    # defers rendering past handle_params, so pending changed sets
    # ACCUMULATE until the after_render hook consumes them.
    changed =
      case socket.assigns[:ash_ui_changed] do
        %MapSet{} = pending -> MapSet.union(pending, changed)
        _all_or_nil -> changed
      end

    socket
    |> assign(:ash_ui_record, new)
    |> assign(:ash_ui_changed, changed)
    |> assign(:ash_ui_params, params)
    |> assign_page_title(new)
    |> register_notifications()
  end

  defp assign_page_title(socket, %_{} = record),
    do: assign_page_title(socket, record, :calculate)

  defp assign_page_title(socket, %_{} = record, :calculate) do
    assign_page_title(
      socket,
      record,
      calculate_page_title(record,
        actor: socket.assigns[:ash_ui_actor],
        tenant: socket.assigns[:ash_ui_tenant],
        context: socket.assigns[:ash_ui_context] || %{}
      )
    )
  end

  defp assign_page_title(socket, %_{} = _record, :none), do: socket

  defp assign_page_title(socket, %_{} = _record, {:ok, title}),
    do: assign(socket, :page_title, title)

  defp assign_page_title(socket, %_{} = _record, {:error, reason}),
    do: assign(socket, :ash_ui_errors, dispatch_error_list(reason))

  defp calculate_page_title(%resource{} = record, opts) do
    case Ash.Resource.Info.calculation(resource, :page_title) do
      nil ->
        :none

      _calculation ->
        Ash.calculate(record, :page_title,
          actor: Keyword.get(opts, :actor),
          tenant: Keyword.get(opts, :tenant),
          context: Keyword.get(opts, :context, %{}),
          domain: page_domain(resource),
          reuse_values?: true
        )
    end
  end

  defp register_notifications(socket) do
    case socket.assigns[:ash_ui_record] do
      %_{} = record ->
        subscriptions = notification_subscriptions(record, socket)
        refs = subscriptions |> Map.keys() |> MapSet.new()
        previous = socket.assigns[:ash_ui_notification_refs] || MapSet.new()

        previous
        |> MapSet.difference(refs)
        |> Enum.each(&AshUi.Notification.MatchIndex.deregister/1)

        changed_subscriptions =
          Enum.reject(subscriptions, fn {ref, subscription} ->
            case AshUi.Notification.MatchIndex.subscription(ref) do
              %{subscription_ref: ^ref} = existing ->
                Map.delete(existing, :subscription_ref) == subscription

              _missing ->
                false
            end
          end)

        AshUi.Notification.MatchIndex.register_many(changed_subscriptions)

        assign(socket, :ash_ui_notification_refs, refs)

      _missing ->
        socket
    end
  end

  # A disconnected render has no process capable of consuming refreshes.
  # Its loaded record is handed to the connected phase instead; subscriptions
  # begin only once the session-owned LiveView exists.
  defp maybe_register_notifications(socket) do
    if socket.assigns[:ash_ui_connected?] do
      register_notifications(socket)
    else
      socket
    end
  end

  defp notification_subscriptions(record, socket) do
    root_ref = notification_ref(record, :root)

    root =
      {root_ref,
       notification_subscription(
         record.__struct__,
         primary_key_values(record),
         nil,
         record,
         socket,
         :root
       )}

    relationships =
      relationship_subscriptions(
        record,
        socket,
        [],
        MapSet.new(),
        AshUi.view_load(record.__struct__)
      )

    [root | relationships]
    |> AshUi.Notification.MatchIndex.compact_subscriptions({
      :ash_ui_phoenix,
      self()
    })
    |> Map.new()
  end

  defp relationship_subscriptions(%resource{} = record, socket, prefix, seen, load_spec) do
    identity = {resource, record_identity(record)}

    if MapSet.member?(seen, identity) do
      []
    else
      seen = MapSet.put(seen, identity)

      derived_read_subscriptions(record, socket, prefix, load_spec) ++
        loaded_relationship_subscriptions(record, socket, prefix, seen, load_spec)
    end
  end

  # "Whatever a page reads, it subscribes to": the rows a loaded calculation
  # or aggregate derives from are hidden internal loads the walk below never
  # sees (AshUi.Notification.DerivedReads).
  defp derived_read_subscriptions(record, socket, prefix, load_spec) do
    record
    |> AshUi.Notification.DerivedReads.edges(load_spec, prefix)
    |> Enum.map(fn edge ->
      {notification_ref(record, edge.key),
       notification_subscription(
         edge.resource,
         edge.attrs,
         edge.filter,
         edge.parent,
         socket,
         edge.reload_scope
       )}
    end)
  end

  defp loaded_relationship_subscriptions(
         %resource{} = record,
         socket,
         prefix,
         seen,
         load_spec
       ) do
    resource
    |> Ash.Resource.Info.relationships()
    |> Enum.flat_map(fn relationship ->
      case Map.get(record, relationship.name) do
        %Ash.NotLoaded{} ->
          []

        loaded ->
          path = prefix ++ [relationship.name]
          ref = notification_ref(record, path)
          child_load = relationship_child_load(load_spec, relationship.name)

          subscription =
            notification_subscription(
              relationship.destination,
              relationship_index_attrs(record, relationship),
              Map.get(relationship, :filter),
              record,
              socket,
              path
            )

          nested =
            if recurse_notification_relationships?(relationship.destination, child_load) do
              children =
                case List.wrap(loaded) do
                  [] when relationship.cardinality == :one ->
                    with source when is_atom(source) <- relationship.source_attribute,
                         destination when is_atom(destination) <-
                           relationship.destination_attribute,
                         value when not is_nil(value) <- Map.get(record, source) do
                      child = struct(relationship.destination, %{destination => value})

                      child =
                        Enum.reduce(
                          Ash.Resource.Info.relationships(relationship.destination),
                          child,
                          &Map.put(&2, &1.name, nil)
                        )

                      [child]
                    else
                      _unaddressable -> []
                    end

                  children ->
                    children
                end

              children
              |> Enum.flat_map(fn
                %_{} = child ->
                  relationship_subscriptions(
                    child,
                    socket,
                    path,
                    seen,
                    child_load_spec(child_load)
                  )

                _other ->
                  []
              end)
            else
              []
            end

          [{ref, subscription} | nested]
      end
    end)
  end

  defp relationship_child_load(load_spec, relationship_name) do
    load_spec
    |> List.wrap()
    |> Enum.find_value(:unknown, fn
      {^relationship_name, nested} -> {:known, List.wrap(nested)}
      ^relationship_name -> {:known, []}
      _other -> nil
    end)
  end

  defp child_load_spec({:known, load}), do: load
  defp child_load_spec(:unknown), do: []

  defp recurse_notification_relationships?(_resource, :unknown), do: true

  defp recurse_notification_relationships?(resource, {:known, load}) do
    Enum.any?(load, fn
      {field, _nested} -> not is_nil(Ash.Resource.Info.relationship(resource, field))
      field when is_atom(field) -> not is_nil(Ash.Resource.Info.relationship(resource, field))
      _other -> false
    end)
  end

  defp notification_subscription(resource, attrs, filter, parent, socket, reload_scope) do
    tenant = socket.assigns[:ash_ui_tenant]

    filter =
      filter &&
        Ash.Expr.fill_template(filter,
          actor: socket.assigns[:ash_ui_actor],
          tenant: tenant && Ash.ToTenant.to_tenant(tenant, resource),
          context: socket.assigns[:ash_ui_context] || %{}
        )

    %{
      pid: self(),
      resource: resource,
      attrs: attrs,
      filter: filter,
      parent: notification_filter_parent(filter, parent),
      reload_scope: reload_scope,
      tenant: socket.assigns[:ash_ui_tenant],
      domain: Ash.Resource.Info.domain(resource) || AshUi.AshDomainFallback
    }
  end

  defp notification_filter_parent(filter, _parent) when filter in [nil, []], do: nil
  defp notification_filter_parent(_filter, parent), do: parent

  defp relationship_index_attrs(_record, %{no_attributes?: true}), do: []

  defp relationship_index_attrs(record, relationship) do
    with source when is_atom(source) <- Map.get(relationship, :source_attribute),
         destination when is_atom(destination) <- Map.get(relationship, :destination_attribute),
         value when not is_nil(value) <- Map.get(record, source) do
      [{destination, value}]
    else
      _unindexed -> []
    end
  end

  defp notification_ref(record, edge) do
    {:ash_ui_phoenix, self(), record.__struct__, record_identity(record), edge}
  end

  defp primary_key_values(%resource{} = record) do
    resource
    |> Ash.Resource.Info.primary_key()
    |> Enum.map(&{&1, Map.get(record, &1)})
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp record_identity(%_resource{} = record) do
    case primary_key_values(record) do
      [] -> :erlang.phash2(record)
      values -> List.to_tuple(Enum.map(values, &elem(&1, 1)))
    end
  end

  attr(:ash_ui_record, :any, default: nil)
  attr(:ash_ui_changed, :any, default: :all)
  attr(:ash_ui_mount_error, :string, default: nil)

  # Differential render: statics + changed dynamics straight from the
  # compiled patch table. There is no tree, no previous tree, no diffing.
  def render_shell(assigns) do
    measure_mount_layer(:initial_render_materialize, fn ->
      mount_error = assigns[:ash_ui_mount_error]

      case assigns[:ash_ui_record] do
        %_{} = record ->
          view = assigns[:ash_ui_view] || :view

          table =
            AshUi.Patch.Compiler.cached_table(record.__struct__, view,
              target: RenderTarget
            )

          build = fn ->
            AshUi.Phoenix.LiveRender.build(
              record,
              assigns[:ash_ui_changed] || :all,
              table: table,
              view: view,
              actor: assigns[:ash_ui_actor],
              tenant: assigns[:ash_ui_tenant],
              context: assigns[:ash_ui_context] || %{},
              session_id: assigns[:ash_ui_session_id],
              params: assigns[:ash_ui_params] || %{},
              errors: assigns[:ash_ui_errors] || []
            )
          end

          build
          |> mount_render(assigns, record, view)
          |> put_page_error_surface(assigns[:ash_ui_errors] || [])

        _missing when is_binary(mount_error) ->
          %Phoenix.LiveView.Rendered{
            static: [
              ~s(<div data-ash-ui-page-root=""><div part="wb_error" data-ash-ui-error="mount" role="alert">),
              "</div></div>"
            ],
            dynamic: fn _track ->
              [
                AshUi.RenderTarget.Html.html_escape(mount_error)
              ]
            end,
            fingerprint: :erlang.phash2(:ash_ui_mount_error),
            root: true
          }

        _missing ->
          %Phoenix.LiveView.Rendered{
            static: ["<div></div>"],
            dynamic: fn _track -> [] end,
            fingerprint: 0,
            root: true
          }
      end
    end)
  end

  defp put_page_error_surface(%Phoenix.LiveView.Rendered{} = rendered, errors) do
    case statics_with_page_error_slot(rendered.static) do
      {:ok, statics} ->
        dynamic = rendered.dynamic

        %{
          rendered
          | static: statics,
            dynamic: fn track_changes? ->
              dynamic.(track_changes?) ++ [page_error_iodata(errors)]
            end,
            fingerprint: :erlang.phash2({rendered.fingerprint, :ash_ui_page_error})
        }

      :error ->
        wrap_page_error_surface(rendered, errors)
    end
  end

  defp statics_with_page_error_slot([first_static | _rest] = statics) do
    with [root_tag] <-
           Regex.run(~r/\A\s*<([A-Za-z][A-Za-z0-9:_-]*)\b/, first_static, capture: :all_but_first),
         {static_prefix, [static_suffix]} <- Enum.split(statics, -1),
         closing_tag = "</#{root_tag}>",
         [_first | _rest] = matches <- :binary.matches(static_suffix, closing_tag),
         {close_at, _length} <- List.last(matches) do
      before_close = binary_part(static_suffix, 0, close_at)
      close_and_after = binary_part(static_suffix, close_at, byte_size(static_suffix) - close_at)
      {:ok, static_prefix ++ [before_close, close_and_after]}
    else
      _other -> :error
    end
  end

  defp statics_with_page_error_slot(_statics), do: :error

  defp wrap_page_error_surface(rendered, errors) do
    %Phoenix.LiveView.Rendered{
      static: [~s(<div data-ash-ui-page-root="">), "", "</div>"],
      dynamic: fn _track_changes? -> [rendered, page_error_iodata(errors)] end,
      fingerprint: :erlang.phash2({rendered.fingerprint, :ash_ui_page_error_wrapper}),
      root: true
    }
  end

  defp page_error_iodata([]), do: []

  defp page_error_iodata(errors) do
    messages =
      errors
      |> Enum.map(&AshUi.dispatch_error_message/1)
      |> Enum.uniq()
      |> Enum.join(" ")

    [
      ~s(<div part="wb_error" data-ash-ui-error="page" role="alert">),
      AshUi.RenderTarget.Html.html_escape(messages),
      "</div>"
    ]
  end

  defp mount_render(build, assigns, record, view) do
    if (assigns[:ash_ui_changed] || :all) == :all do
      key =
        {:ash_ui_mount_render, assigns[:ash_ui_session_id], record.__struct__, view,
         assigns[:ash_ui_params] || %{}, assigns[:ash_ui_actor],
         assigns[:ash_ui_tenant]}

      if assigns[:ash_ui_connected?] do
        # The static phase froze the exact initial render under this mount
        # identity. Check the one-shot handoff before building a second 10k-row
        # Rendered tree; the previous version discarded that duplicate build
        # only after paying its full construction cost.
        AshUi.Notification.MatchIndex.take_session_handoff(key) || build.()
      else
        rendered = build.()
        frozen = AshUi.Phoenix.LiveRender.freeze(rendered)
        AshUi.Notification.MatchIndex.put_session_handoff(key, frozen)
        frozen
      end
    else
      build.()
    end
  end

  defp measure_mount_layer(layer, fun) when is_atom(layer) and is_function(fun, 0) do
    started = System.monotonic_time()

    :telemetry.execute(
      [:ash_ui, :mount, :layer, :start],
      %{},
      %{adapter: :phoenix, layer: layer}
    )

    try do
      fun.()
    after
      :telemetry.execute(
        [:ash_ui, :mount, :layer],
        %{duration: System.monotonic_time() - started},
        %{adapter: :phoenix, layer: layer}
      )
    end
  end

  # Static render of a VALUE (embedded) resource: bind context keys to the
  # resource's public attributes by name, render through the public
  # AshUi.render/3 contract, and emit static HTML.
  def render_resource(resource_module, context \\ %{}, opts \\ [])
      when is_atom(resource_module) and is_map(context) and is_list(opts) do
    attribute_names =
      resource_module
      |> Ash.Resource.Info.public_attributes()
      |> Enum.map(& &1.name)

    input = Map.take(context, attribute_names ++ Enum.map(attribute_names, &Atom.to_string/1))

    opts = Keyword.put(opts, :target, RenderTarget)

    case AshUi.render(resource_module, input, opts) do
      {:ok, tree} ->
        AshUi.RenderTarget.Html.render_static(tree, target: RenderTarget)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def render_resource!(resource_module, context \\ %{}, opts \\ []) do
    case render_resource(resource_module, context, opts) do
      {:safe, _iodata} = safe ->
        safe

      {:error, reason} ->
        raise ArgumentError,
              "could not render AshUi resource #{inspect(resource_module)}: #{inspect(reason)}"
    end
  end

  def configured_resource!(otp_app, key) when is_atom(key) do
    otp_app
    |> blueprint_phoenix_config()
    |> Keyword.fetch!(key)
  end

  def configured_resource(otp_app, key) when is_atom(key) do
    otp_app
    |> blueprint_phoenix_config()
    |> Keyword.get(key)
  end

  def telemetry_child_spec(name) when is_atom(name) do
    telemetry_name = Module.concat([Macro.camelize(to_string(name)), AshUiTelemetry])

    Supervisor.child_spec(
      {AshUi.Phoenix.Telemetry, name: telemetry_name},
      id: {AshUi.Phoenix.Telemetry, name}
    )
  end

  def otp_app(conn_or_socket_or_assigns, opts \\ [])

  def otp_app(_conn_or_socket_or_assigns, opts) when is_list(opts) do
    Keyword.get(opts, :otp_app) ||
      Application.get_env(:ash_ui_phoenix, :otp_app)
  end

  defp install_bridge_runtime(socket) do
    if Map.has_key?(socket.private || %{}, :lifecycle) do
      socket
      |> attach_hook(:ash_ui_handle_params, :handle_params, fn params, uri, socket ->
        {:noreply, updated_socket} = runtime_handle_params(params, uri, socket)
        {:halt, updated_socket}
      end)
      |> attach_hook(:ash_ui_handle_event, :handle_event, fn event, params, socket ->
        if blueprint_event?(event) do
          {:noreply, updated_socket} = runtime_handle_event(event, params, socket)
          {:halt, updated_socket}
        else
          {:cont, socket}
        end
      end)
      |> attach_hook(:ash_ui_handle_info, :handle_info, fn message, socket ->
        case message do
          {:ash_ui_notification, _ref, _event} ->
            {:noreply, updated_socket} = runtime_handle_info(message, socket)
            {:halt, updated_socket}

          _other ->
            {:cont, socket}
        end
      end)
      |> attach_hook(:ash_ui_after_render, :after_render, fn socket ->
        case socket.assigns[:ash_ui_changed] do
          %MapSet{map: map} when map_size(map) == 0 -> socket
          _pending -> Phoenix.Component.assign(socket, :ash_ui_changed, MapSet.new())
        end
      end)
      |> render_with(&render_shell/1)
    else
      socket
    end
  end

  def client_dispatch_params(binding, args \\ %{})

  def client_dispatch_params(%EventBinding{} = binding, args) when is_map(args) do
    %{"binding" => EventBinding.binding_key([], binding)}
    |> Map.merge(stringify_keys(args))
  end

  defp blueprint_phoenix_config(nil), do: []

  defp blueprint_phoenix_config(otp_app) when is_atom(otp_app) do
    Application.get_env(otp_app, __MODULE__, [])
  end

  defp blueprint_phoenix_config(_otp_app), do: []

  defp dispatch_binding_key(params) when is_map(params) do
    Map.get(params, "binding") ||
      Map.get(params, :binding) ||
      Map.get(params, "phx-value-binding") ||
      Map.get(params, :"phx-value-binding") ||
      Map.get(params, "data-ash-ui-binding") ||
      Map.get(params, :"data-ash-ui-binding")
  end

  defp blueprint_event?("ash_ui:dispatch:" <> _binding), do: true
  defp blueprint_event?(@dispatch_event), do: true
  defp blueprint_event?(@route_patch_event), do: true
  defp blueprint_event?(_event), do: false

  # LiveView serializes phx-change inputs as a form map plus the complete
  # "_target" path. Its input metadata callback does not run on that form
  # transport, so recover only the targeted leaf for typed event(:value)
  # bindings. The form map itself never becomes an action argument.
  defp normalize_dispatch_params(%{"_target" => target} = params)
       when not is_map_key(params, "value") do
    case List.wrap(target) do
      [field | _rest] = path when is_binary(field) ->
        value =
          Enum.reduce_while(path, params, fn segment, current ->
            if is_map(current) do
              {:cont, Map.get(current, segment)}
            else
              {:halt, nil}
            end
          end)

        case value do
          value when not is_nil(value) and not is_map(value) -> Map.put(params, "value", value)
          _missing_or_non_leaf -> params
        end

      _other ->
        params
    end
  end

  defp normalize_dispatch_params(params), do: params

  defp route_patch_params(%{"_target" => _target} = params), do: Map.delete(params, "_target")
  defp route_patch_params(params), do: params

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
