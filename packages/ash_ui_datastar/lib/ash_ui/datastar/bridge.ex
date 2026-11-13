defmodule AshUi.Datastar.Bridge do
  @moduledoc """
  Plain Plug mount, dispatch, and notification bridge for AshUi resources.

  Configure with `resources: [MyPage]` or `domains: [MyDomain]`. Resources are
  matched using their `route/2` declaration.

  `:session_id` may be a one-argument function or an MFA whose first argument
  is the connection. A binary result is used instead of the bridge cookie; a
  nil result falls back to the default cookie-backed identity.

  Generated bridge URLs use `conn.script_name` so forwarded mounts work. Set
  `:base_path` to override that generated prefix.
  """

  @behaviour Plug

  import Plug.Conn

  alias AshUi.Datastar.{FragmentRender, RenderTarget, SSE, Store}
  alias AshUi.EventBinding

  @cookie "ash_ui_session_id"
  @client_id_header "ash-ui-client-id"
  @dispatch_prefix "/_ash_ui/dispatch/"
  @updates_path "/_ash_ui/updates"
  @script_path "/_ash_ui/datastar.js"

  @impl Plug
  def init(opts) do
    resources =
      Keyword.get(opts, :resources, []) ++
        Enum.flat_map(Keyword.get(opts, :domains, []), &domain_resources/1)

    routes =
      resources
      |> Enum.uniq()
      |> Enum.flat_map(fn resource ->
        cond do
          not Code.ensure_loaded?(resource) ->
            []

          function_exported?(resource, :__ash_ui_routes__, 0) ->
            Enum.map(resource.__ash_ui_routes__(), &{resource, compile_route(&1)})

          function_exported?(resource, :__ash_ui_route__, 0) ->
            [{resource, compile_route(resource.__ash_ui_route__())}]

          true ->
            []
        end
      end)

    navigation_routes =
      resources
      |> Enum.uniq()
      |> Enum.flat_map(&AshUi.Location.routes/1)
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()

    view = Keyword.get(opts, :view, :view)

    # Compiled tables live in :persistent_term, NOT in the config: the config
    # rides into the session-owner transaction closure on every dispatch, and
    # persistent_term reads are zero-copy shared literals. init warms the
    # cache so first requests never pay a compile.
    routes
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.each(&cached_table(&1, view, navigation_routes))

    %{routes: routes, navigation_routes: navigation_routes, view: view, opts: opts}
  end

  @doc false
  # The core table memo (Patch.Compiler.cached_table/3) is the ONE cache —
  # this wrapper only fixes the datastar target and route variant.
  def cached_table(resource, view, navigation_routes) do
    AshUi.Patch.Compiler.cached_table(resource, view,
      target: AshUi.Datastar.RenderTarget,
      navigation_routes: navigation_routes
    )
  end

  @impl Plug
  def call(%Plug.Conn{method: "POST"} = conn, config) do
    measure_dispatch_layer(:total, fn ->
      path = relative_path(conn)

      if String.starts_with?(path, @dispatch_prefix) do
        key = path |> String.replace_prefix(@dispatch_prefix, "") |> URI.decode()
        dispatch(conn, key, config)
      else
        send_resp(conn, 404, "not found")
      end
    end)
  end

  def call(%Plug.Conn{method: "GET"} = conn, config) do
    case relative_path(conn) do
      @script_path -> serve_script(conn)
      @updates_path -> updates(conn, config)
      _mount_path -> mount(conn, config)
    end
  end

  def call(conn, _config), do: send_resp(conn, 404, "not found")

  defp mount(conn, %{
         routes: routes,
         navigation_routes: navigation_routes,
         view: view,
         opts: opts
       }) do
    case match_route(routes, relative_path(conn)) do
      {resource, path_params} ->
        conn = conn |> fetch_query_params() |> fetch_cookies()
        {session_id, identity_source} = mount_session_id(conn, opts)
        params = conn.query_params |> Map.delete("datastar") |> Map.merge(path_params)
        scope = request_scope(conn, opts, session_id)
        base_path = base_path(conn, opts)
        location = request_location(conn)

        # The session state is BUILT on the owner heap: record create, view
        # load, initial render, and the state put all run inside the session
        # transaction, so a 10k-row state is never constructed in the request
        # process and copied across. Only the document body (the response
        # payload) comes out.
        result =
          Store.transaction(session_id, fn ->
            with {:ok, record} <- mount_record(resource, params, scope),
                 {:ok, record} <- load_view(record, scope) do
              table = cached_table(resource, view, navigation_routes)

              {fragment, live} =
                FragmentRender.initial_render(
                  record,
                  table,
                  render_opts(scope, params, base_path, navigation_routes)
                )

              :ok =
                Store.put(session_id, %{
                  resource: resource,
                  view: view,
                  record: record,
                  table: table,
                  actor: scope.actor,
                  tenant: scope.tenant,
                  context: scope.context,
                  params: params,
                  navigation_routes: navigation_routes,
                  location: location,
                  errors: [],
                  live: live
                })

              {:ok, document(fragment, record, base_path, opts)}
            end
          end)

        case result do
          {:ok, body} ->
            measure_mount_layer(:emit_transport, fn ->
              conn
              |> maybe_put_session_cookie(session_id, identity_source)
              |> put_resp_header("cache-control", "no-store")
              |> put_resp_content_type("text/html")
              |> send_resp(200, body)
            end)

          {:error, reason} ->
            error(conn, 422, reason)
        end

      nil ->
        send_resp(conn, 404, "not found")
    end
  end

  # Conn IO stays in the REQUEST process — body read before the transaction,
  # response send after it. The transaction closure carries only small
  # values (key, signals, base path); the session state and the compiled
  # tables never cross the seam, and the owner returns the SSE event list,
  # not a sent conn.
  defp dispatch(conn, key, %{opts: opts} = config) do
    conn = fetch_cookies(conn)

    case request_session_id(conn, opts) do
      session_id when is_binary(session_id) ->
        case measure_dispatch_layer(:plug_signals, fn -> read_signals(conn) end) do
          {:ok, signals, conn} ->
            request = %{
              key: key,
              session_id: session_id,
              client_id: request_client_id(conn),
              signals: signals,
              base_path: base_path(conn, opts)
            }

            reply =
              Store.transaction(session_id, fn -> dispatch_session(request, config) end)

            respond_dispatch(conn, reply)

          {:error, reason} ->
            error(conn, 422, reason)
        end

      nil ->
        error(conn, 401, :missing_or_expired_session)
    end
  end

  defp respond_dispatch(conn, {:sse, events}),
    do: SSE.send_events(conn, events, protocol: protocol(conn))

  defp respond_dispatch(conn, {:plain, status, reason}), do: error(conn, status, reason)

  defp dispatch_session(request, config) do
    reply =
      case Store.get(request.session_id) do
        %{record: current} = state ->
          dispatch_current_session(request, state, current, config)

        nil ->
          {:plain, 401, :missing_or_expired_session}
      end

    case reply do
      {:sse, events} ->
        refresh_owner_notification_subscriptions(request.session_id)
        :ok = Store.broadcast(request.session_id, events, except: request.client_id)
        reply

      _plain ->
        reply
    end
  end

  defp dispatch_current_session(
         %{key: key, session_id: session_id} = request,
         state,
         current,
         %{opts: opts} = config
       ) do
    boundary = AshUi.Patch.Compiler.dispatch_boundary(key, state.table)
    reload_paths = AshUi.Patch.Compiler.dispatch_reload_paths(key, state.table)

    with params <- dispatch_params(request.signals, key),
         {:ok, %EventBinding{} = binding, target} <-
           measure_dispatch_layer(:binding_resolve, fn ->
             AshUi.Patch.Bindings.resolve(current, key, params,
               table: state.table,
               actor: state.actor,
               tenant: state.tenant,
               context: state.context,
               session_id: session_id
             )
           end),
         {:dispatch, _path, action, payload} <-
           measure_dispatch_layer(:binding_resolve, fn ->
             EventBinding.runtime_event(binding, params)
           end) do
      dispatch_ref = {:ash_ui_datastar_dispatch, session_id, make_ref()}

      echo_refs =
        register_notification_subscriptions(current, state, dispatch_ref, MapSet.new())

      action_result =
        measure_dispatch_layer(:action_run, fn ->
          run_dispatch_action(current, target, action, payload, state)
        end)

      notification_refs =
        case Store.notification_info(session_id) do
          %{refs: refs} -> refs
          nil -> MapSet.new()
        end

      echo = take_dispatch_echo(echo_refs, notification_refs)

      case action_result do
        {:ok, updated_owner} ->
          dispatch_success(
            request,
            state,
            current,
            updated_owner,
            boundary,
            reload_paths,
            echo,
            config
          )

        {:error, reason} ->
          dispatch_error(request, state, current, boundary, reason, opts)
      end
    else
      :error ->
        dispatch_error(request, state, current, boundary, {:unknown_target, key}, opts)

      :ignore ->
        {:plain, 409, :event_filter_rejected}

      {:error, reason} ->
        {:plain, 422, reason}

      other ->
        {:plain, 422, {:invalid_dispatch, other}}
    end
  end

  defp dispatch_success(
         %{session_id: session_id} = request,
         state,
         current,
         updated_owner,
         boundary,
         reload_paths,
         echo,
         config
       ) do
    case measure_dispatch_layer(:page_reload, fn ->
           refresh_after_dispatch(current, updated_owner, state, echo)
         end) do
      {:ok, updated} ->
        render_opts =
          state_render_opts(state, session_id, request.base_path)
          |> Keyword.put(:errors, [])

        # error nodes only exist where the previous failed dispatch rendered
        # them — force exactly those addresses to clear them, nothing else
        forced =
          if Map.get(state, :errors, []) == [] do
            []
          else
            Map.get(state, :error_addresses, List.wrap(boundary) ++ state.table.error_slots)
          end

        {location, location_events, location_kind} =
          location_events(updated, state, request.base_path)

        if location_kind == :navigate do
          measure_dispatch_layer(:navigation, fn ->
            navigate_dispatch(request, state, location, config)
          end)
        else
          changed =
            measure_dispatch_layer(:changed_addresses, fn ->
              dispatch_changed_addresses(
                state.table,
                current,
                updated,
                updated_owner,
                reload_paths,
                echo
              )
            end)

          {events, live} =
            FragmentRender.render(updated, changed, forced, state.table, state.live, render_opts)

          :ok =
            Store.put(session_id, %{
              state
              | record: updated,
                location: location,
                errors: [],
                live: live
            })

          {:sse, events ++ location_events}
        end

      {:error, reason} ->
        {:plain, 422, reason}
    end
  end

  defp dispatch_error(
         %{session_id: session_id} = request,
         state,
         current,
         boundary,
         reason,
         _opts
       ) do
    errors = AshUi.dispatch_errors(reason)

    # errors render at the page's error slots plus the failed dispatch's own
    # child boundary (entry-scoped for children inside keyed collections) —
    # never at unrelated child boundaries
    error_addresses = error_addresses(state.table, boundary, errors)

    render_opts =
      state_render_opts(state, session_id, request.base_path)
      |> Keyword.put(:errors, errors)

    {events, live} =
      FragmentRender.render(
        current,
        MapSet.new(error_addresses),
        [],
        state.table,
        state.live,
        render_opts
      )

    :ok =
      Store.put(
        session_id,
        state
        |> Map.put(:errors, errors)
        |> Map.put(:error_addresses, error_addresses)
        |> Map.put(:live, live)
      )

    {:sse, events}
  end

  # The action runs IN-PROCESS. A task seam here copies the current record
  # into the task heap and the result back out — O(loaded rows) both ways on
  # every dispatch — and the copies break the pointer identity that keeps
  # `preserve_loaded_values`/`changed_addresses` O(1) on unchanged
  # relationship lists. The request process is short-lived (its whole heap,
  # live snapshot included, dies at response), so the GC-isolation a task
  # bought is worth strictly less than the two copies it costs.
  defp run_dispatch_action(current, target, action, payload, state) do
    AshUi.Patch.Dispatch.run(current, target, action, payload,
      actor: state.actor,
      tenant: state.tenant,
      context: state.context
    )
  end

  # Keyed error surfaces are compile-indexed with a force marker because an
  # entry's error state is not part of its retained item vars. The marker is
  # relevant only when the failed action actually returned an error under the
  # collection field. Applying every keyed marker to every page-level error
  # turns an unrelated form validation into an all-entries re-render.
  defp error_addresses(table, boundary, errors) do
    slots = error_slots(table.slots)
    keyed_slots = Enum.filter(slots, &(&1.kind == :keyed_list))

    table.error_slots
    |> Enum.reject(fn
      {:force_entries, address} ->
        not keyed_error_path?(table, address, errors)

      address when is_binary(address) ->
        irrelevant_bound_address?(address, slots, errors) or
          (keyed_only_address?(address, keyed_slots, slots) and
             Enum.all?(keyed_slots_at(address, keyed_slots), fn slot ->
               not keyed_error_path?(table, slot.addr, errors)
             end))

      _marker ->
        false
    end)
    |> Kernel.++(List.wrap(boundary))
    |> Enum.uniq()
  end

  defp irrelevant_bound_address?(address, slots, errors) do
    claims = Enum.filter(slots, &(&1.errors? and &1.addr == address))

    fields =
      claims
      |> Enum.flat_map(&Map.get(&1.meta, :bound_fields, []))
      |> Enum.reject(&(&1 in [nil, :__fragment__, :__item__]))
      |> Enum.uniq()

    fields != [] and
      Enum.all?(claims, fn slot -> Map.get(slot.meta, :bound_fields, []) != [] end) and
      Enum.all?(error_fields(errors), &(&1 not in fields))
  end

  defp error_fields(errors) do
    errors
    |> List.wrap()
    |> Enum.flat_map(fn error ->
      path = List.wrap(Map.get(error, :path))
      [AshUi.Runtime.Errors.field(error) | path]
    end)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp keyed_only_address?(address, keyed_slots, slots) do
    keyed_slots_at(address, keyed_slots) != [] and
      not Enum.any?(slots, fn slot ->
        slot.kind != :keyed_list and slot.errors? and
          (slot.addr == address or Map.get(slot.meta, :owner_addr) == address)
      end)
  end

  defp keyed_slots_at(address, keyed_slots) do
    Enum.filter(keyed_slots, fn slot ->
      slot.addr == address or Map.get(slot.meta, :owner_addr) == address
    end)
  end

  defp error_slots(slots) do
    Enum.flat_map(slots, fn
      {_id, %{kind: :keyed_list, meta: %{item_slots: item_slots}} = slot} ->
        [slot | error_slots(item_slots)]

      {_id, slot} ->
        [slot]
    end)
  end

  defp keyed_error_path?(table, address, errors) do
    deps =
      case AshUi.Patch.Compiler.slot_path(table, address) do
        {:ok, %{kind: :keyed_list, deps: deps}, _ancestors} -> deps
        _missing -> []
      end

    Enum.any?(List.wrap(errors), fn error ->
      path = List.wrap(Map.get(error, :path))
      root = List.first(path) || AshUi.Runtime.Errors.field(error)
      root in deps
    end)
  end

  defp location_events(record, state, base_path) do
    case AshUi.Location.project(record, state.location,
           actor: state.actor,
           tenant: state.tenant,
           context: state.context
         ) do
      {:patch, target} ->
        browser_target = browser_target(base_path, target)

        {target,
         [
           SSE.execute_script("history.pushState({}, '', #{Jason.encode!(browser_target)})")
         ], :patch}

      {:navigate, target} ->
        {target, [], :navigate}

      :unchanged ->
        {state.location, [], :none}
    end
  end

  defp browser_target(base_path, "/" <> _rest = target), do: base_path <> target
  defp browser_target(_base_path, target), do: target

  defp navigate_dispatch(
         %{session_id: session_id, base_path: base_path},
         state,
         target,
         %{
           routes: routes,
           navigation_routes: navigation_routes,
           view: view,
           opts: opts
         }
       ) do
    uri = URI.parse(target)
    path = uri.path || "/"

    case match_route(routes, path) do
      {resource, path_params} ->
        params =
          uri.query
          |> case do
            query when is_binary(query) -> URI.decode_query(query)
            _none -> %{}
          end
          |> Map.merge(path_params)

        scope = %{actor: state.actor, tenant: state.tenant, context: state.context}

        with {:ok, record} <-
               measure_dispatch_layer(:navigation_page_mount, fn ->
                 mount_record(resource, params, scope)
               end),
             {:ok, record} <-
               measure_dispatch_layer(:navigation_view_load, fn ->
                 load_view(record, scope)
               end) do
          table = cached_table(resource, view, navigation_routes)

          {fragment, live} =
            measure_dispatch_layer(:navigation_render, fn ->
              FragmentRender.initial_render(
                record,
                table,
                render_opts(scope, params, base_path, navigation_routes)
              )
            end)

          :ok =
            Store.put(session_id, %{
              resource: resource,
              view: view,
              record: record,
              table: table,
              actor: state.actor,
              tenant: state.tenant,
              context: state.context,
              params: params,
              navigation_routes: navigation_routes,
              location: target,
              errors: [],
              live: live
            })

          browser_target = browser_target(base_path, target)

          document =
            measure_dispatch_layer(:navigation_document, fn ->
              document(fragment, record, base_path, opts)
            end)

          {:sse,
           [
             SSE.execute_script("history.pushState({}, '', #{Jason.encode!(browser_target)})"),
             SSE.patch_elements(document, meta: %{navigation: :redirect})
           ]}
        else
          {:error, reason} -> {:plain, 422, reason}
        end

      nil ->
        browser_target = browser_target(base_path, target)

        {:sse, [SSE.execute_script("window.location.assign(#{Jason.encode!(browser_target)})")]}
    end
  end

  defp state_render_opts(state, session_id, base_path) do
    [
      actor: state.actor,
      tenant: state.tenant,
      context: state.context,
      session_id: session_id,
      params: state.params,
      navigation_routes: Map.get(state, :navigation_routes),
      base_path: base_path,
      reuse_loaded_values?: true,
      errors: Map.get(state, :errors, [])
    ]
  end

  @doc false
  def notification_update(session_id, base_path, base_ref, notification_refs) do
    case Store.get(session_id) do
      nil ->
        {:error, :missing_or_expired_session}

      state ->
        scope = notification_reload_scope(notification_refs)

        with {:ok, updated} <-
               measure_dispatch_layer(:notification_reload, fn ->
                 reload(state.record, state, scope)
               end) do
          changed =
            AshUi.Patch.Runtime.changed_addresses(
              state.table,
              state.record,
              updated
            )

          {events, live} =
            FragmentRender.render(
              updated,
              changed,
              [],
              state.table,
              state.live,
              state_render_opts(state, session_id, base_path)
            )

          state = %{state | record: updated, live: live}
          :ok = Store.put(session_id, state)

          previous_refs =
            case Store.notification_info(session_id) do
              %{refs: refs} -> refs
              nil -> MapSet.new()
            end

          refs =
            register_notification_subscriptions(
              updated,
              state,
              base_ref,
              previous_refs,
              self()
            )

          {:ok, events, refs}
        end
    end
  end

  defp refresh_owner_notification_subscriptions(session_id) do
    case {Store.get(session_id), Store.notification_info(session_id)} do
      {%{record: record} = state, %{base_ref: base_ref, refs: refs}} ->
        refs =
          register_notification_subscriptions(
            record,
            state,
            base_ref,
            refs,
            self()
          )

        Store.put_notification_refs(session_id, refs)

      _missing_or_disconnected ->
        :ok
    end
  end

  # The stream process owns only its socket. The session owner owns connection
  # membership, one notification subscription set, the resource state, and the
  # differential snapshot. A connect receives one full-state event generated
  # on the owner heap; later diff events are generated once there and sent to
  # every attached stream.
  defp updates(conn, %{opts: opts}) do
    conn = fetch_cookies(conn)
    stream_pid = self()
    client_id = request_client_id(conn) || {:stream, stream_pid}
    base_path = base_path(conn, opts)

    with session_id when is_binary(session_id) <- request_session_id(conn, opts),
         {:ok, initial_events} <-
           Store.transaction(session_id, fn ->
             case Store.get(session_id) do
               %{record: record} = state ->
                 fragment =
                   FragmentRender.full_render(
                     record,
                     state.table,
                     state_render_opts(state, session_id, base_path)
                   )

                 if Store.client_count(session_id) == 0 do
                   base_ref = {:ash_ui_datastar, session_id, make_ref()}

                   refs =
                     register_notification_subscriptions(
                       record,
                       state,
                       base_ref,
                       MapSet.new(),
                       self()
                     )

                   :ok =
                     Store.configure_notifications(
                       session_id,
                       base_ref,
                       refs,
                       {__MODULE__, :notification_update, [session_id, base_path, base_ref]}
                     )
                 end

                 Store.attach(session_id, client_id, stream_pid)
                 {:ok, [SSE.patch_elements(fragment)]}

               nil ->
                 {:error, :missing_or_expired_session}
             end
           end) do
      conn =
        case SSE.open_stream(conn, protocol: protocol(conn)) do
          {:ok, conn, encoder} ->
            case write_events(conn, encoder, initial_events) do
              {:ok, conn, encoder} ->
                update_loop(conn, encoder, opts, 0)

              {:error, conn, encoder} ->
                SSE.close_stream(conn, encoder)
            end

          {:error, conn} ->
            conn
        end

      Store.detach(session_id, client_id, stream_pid)
      conn
    else
      _missing -> error(conn, 401, :missing_or_expired_session)
    end
  end

  defp update_loop(conn, encoder, opts, sent) do
    receive do
      {:ash_ui_datastar_events, events} ->
        # State is committed before delivery. A failed write removes only this
        # connection; the session and every other connection remain live.
        case write_events(conn, encoder, events) do
          {:ok, conn, encoder} ->
            sent = sent + 1

            if stream_limit?(sent, Keyword.get(opts, :updates_max_events, :infinity)) do
              SSE.close_stream(conn, encoder)
            else
              update_loop(conn, encoder, opts, sent)
            end

          {:error, conn, encoder} ->
            SSE.close_stream(conn, encoder)
        end
    after
      Keyword.get(opts, :updates_heartbeat, 15_000) ->
        case SSE.write_raw(conn, encoder, ": keepalive\n\n") do
          {:ok, conn, encoder} ->
            update_loop(conn, encoder, opts, sent)

          {:error, conn, encoder} ->
            SSE.close_stream(conn, encoder)
        end
    end
  end

  defp write_events(conn, encoder, events) do
    Enum.reduce_while(events, {:ok, conn, encoder}, fn event, {:ok, conn, encoder} ->
      case SSE.write_event(conn, encoder, event) do
        {:ok, conn, encoder} -> {:cont, {:ok, conn, encoder}}
        {:error, conn, encoder} -> {:halt, {:error, conn, encoder}}
      end
    end)
  end

  defp stream_limit?(_sent, :infinity), do: false
  defp stream_limit?(sent, limit) when is_integer(limit), do: sent >= limit

  # Ash action delivery is synchronous. Drain every hint belonging to this
  # dispatch before the diff, while preserving unrelated messages for the
  # owner's ordinary notification cycle.
  defp drain_notification_refs(refs, notification_refs, deferred \\ []) do
    receive do
      {:ash_ui_notification, ref, _event} = message ->
        if MapSet.member?(refs, ref) do
          drain_notification_refs(refs, MapSet.put(notification_refs, ref), deferred)
        else
          drain_notification_refs(refs, notification_refs, [message | deferred])
        end
    after
      0 ->
        deferred |> Enum.reverse() |> Enum.each(&send(self(), &1))
        notification_refs
    end
  end

  defp mount_record(resource, params, scope) do
    measure_mount_layer(:page_row_create, fn ->
      action = Ash.Resource.Info.action(resource, :mount, :create)
      names = Enum.map(action.arguments, &to_string(&1.name))

      changeset_opts =
        [
          actor: scope.actor,
          tenant: scope.tenant,
          context: scope.context,
          domain: domain(resource),
          upsert?: true
        ]
        |> maybe_put_upsert_identity(resource)

      changeset =
        measure_mount_layer(:page_row_changeset, fn ->
          Ash.Changeset.for_create(
            resource,
            :mount,
            Map.take(params, names),
            changeset_opts
          )
        end)

      measure_mount_layer(:page_row_persist, fn ->
        Ash.create(changeset, domain: domain(resource))
      end)
    end)
  end

  defp load_view(%resource{} = record, scope) do
    measure_mount_layer(:view_load_calc, fn ->
      case AshUi.view_load(resource) do
        [] ->
          {:ok, record}

        loads ->
          Ash.load(record, loads,
            actor: scope.actor,
            tenant: scope.tenant,
            context: scope.context,
            domain: domain(resource),
            lazy?: true,
            reuse_values?: true
          )
      end
    end)
  end

  # The action result is the fresh page state for page-row dispatches —
  # exactly the phoenix bridge's put_record semantics. The O(1) dispatch
  # contract lives in AshUi.Reload — the ONE policy module both
  # bridges call. Only a dispatch that targeted ANOTHER row (store child)
  # needs the page re-read.
  defp refresh_after_dispatch(%resource{} = current, %_{} = updated_owner, scope, echo) do
    if AshUi.Reload.same_row?(current, updated_owner) do
      AshUi.Reload.after_dispatch(current, updated_owner, echo,
        actor: scope.actor,
        tenant: scope.tenant,
        context: scope.context,
        domain: domain(resource),
        authorize?: true
      )
    else
      reload(current, scope)
    end
  end

  defp refresh_after_dispatch(current, _other_owner, scope, _echo),
    do: reload(current, scope)

  # The dispatch echo, datastar-shaped: the POST process holds transient
  # view-source subscriptions for exactly the action's duration, so the
  # action's synchronous write notifications land in this mailbox and name
  # the data that actually changed — the same reload contract the LiveView
  # bridge derives from its session subscriptions. `:root` when any echoed
  # subscription cannot name a narrower scope.
  defp take_dispatch_echo(echo_refs, owner_refs) do
    notified =
      echo_refs
      |> MapSet.union(owner_refs)
      |> drain_notification_refs(MapSet.new())

    scopes = notified |> Enum.map(&notification_reload_scope/1) |> Enum.uniq()

    Enum.each(echo_refs, &AshUi.Notification.MatchIndex.deregister/1)

    if :root in scopes, do: :root, else: Enum.filter(scopes, &is_list/1)
  end

  defp root_attributes_changed?(%resource{} = old, %resource{} = new) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.any?(fn attribute -> Map.get(old, attribute.name) != Map.get(new, attribute.name) end)
  end

  defp dispatch_changed_addresses(table, current, updated, updated_owner, reload_paths, echo) do
    reload_paths =
      reload_paths
      |> Enum.filter(&match?([root | _rest] when is_atom(root), &1))
      |> Enum.uniq()

    root_dispatch? = AshUi.Reload.same_row?(current, updated_owner)

    if root_dispatch? and reload_paths != [] and echo != :root and
         not root_attributes_changed?(current, updated) do
      # The echo names what the action's writes changed beyond the binding's
      # own paths (a relationship read again because the action wrote its
      # destination): the nodes that read those paths, or a root derived from
      # them, are changed too, wherever they sit on the page (as the LiveView
      # bridge's `put_record/5` widens its changed paths).
      echo_paths = Enum.filter(echo, &match?([root | _rest] when is_atom(root), &1))

      paths =
        (reload_paths ++
           echo_paths ++
           (current.__struct__
            |> AshUi.Reload.dependent_roots_for_paths(echo_paths)
            |> Enum.map(&[&1])))
        |> Enum.uniq()

      AshUi.Patch.Runtime.changed_addresses_for_paths(table, paths)
    else
      AshUi.Patch.Runtime.changed_addresses(table, current, updated)
    end
  end

  defp reload(%_{} = record, scope), do: reload(record, scope, :root)

  defp reload(%resource{} = record, scope, reload_scope) do
    with {:ok, reloaded} <-
           AshUi.reload_scope(record, reload_scope,
             actor: scope.actor,
             tenant: scope.tenant,
             context: scope.context,
             domain: domain(resource)
           ) do
      if reload_scope == :root do
        record
        |> AshUi.preserve_loaded_relationships(reloaded)
        |> load_view(scope)
      else
        {:ok, reloaded}
      end
    end
  end

  defp notification_reload_scope(%MapSet{} = refs) do
    refs
    |> Enum.map(&notification_reload_scope/1)
    |> Enum.uniq()
    |> case do
      [scope] -> scope
      _different_or_missing -> :root
    end
  end

  defp notification_reload_scope(ref) do
    case AshUi.Notification.MatchIndex.subscription(ref) do
      %{reload_scope: scope} -> scope
      _missing -> :root
    end
  end

  # A host endpoint's Plug.Parsers may have consumed the body already —
  # the parsed params are then the signal source (Phoenix embedding).
  defp read_signals(%Plug.Conn{body_params: %{"datastar" => signals}} = conn)
       when is_map(signals),
       do: {:ok, signals, conn}

  defp read_signals(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}} = conn),
    do: read_all_body(conn, "")

  defp read_signals(%Plug.Conn{body_params: signals} = conn) when is_map(signals),
    do: {:ok, signals, conn}

  defp read_signals(conn), do: read_all_body(conn, "")

  defp read_all_body(conn, acc) do
    case Plug.Conn.read_body(conn) do
      {:ok, body, conn} -> decode_signals(acc <> body, conn)
      {:more, body, conn} -> read_all_body(conn, acc <> body)
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_signals("", conn), do: {:ok, %{}, conn}

  defp decode_signals(body, conn) do
    case Jason.decode(body) do
      {:ok, %{"datastar" => signals}} when is_map(signals) -> {:ok, signals, conn}
      {:ok, %{} = signals} -> {:ok, signals, conn}
      {:ok, _other} -> {:error, :signals_must_be_an_object}
      {:error, error} -> {:error, error}
    end
  end

  defp dispatch_params(signals, key) do
    case Map.get(signals, key) do
      %{} = value -> Map.merge(signals, value)
      nil -> signals
      value -> Map.put(signals, "value", value)
    end
  end

  defp serve_script(conn) do
    datastar_path = Application.app_dir(:ash_ui_datastar, "priv/static/datastar.js")

    island_path =
      Application.app_dir(:ash_ui_datastar, "priv/static/ash_ui_island.js")

    conn
    |> put_private(:plug_skip_csrf_protection, true)
    |> put_resp_content_type("text/javascript")
    |> send_resp(200, [File.read!(datastar_path), "\n", File.read!(island_path)])
  end

  # The host owns the document shell: `document: {module, function}` in the
  # forward opts receives %{content, record, base_path, script_path} and
  # returns the complete HTML document (iodata or {:safe, iodata}). Without
  # it, the bridge serves its minimal self-contained page.
  defp document(fragment, record, base_path, opts) do
    document =
      case Keyword.get(opts, :document) do
        {module, function} ->
          case apply(module, function, [
                 %{
                   content: fragment,
                   record: record,
                   base_path: base_path,
                   script_path: bridge_path(base_path, @script_path)
                 }
               ]) do
            {:safe, iodata} -> iodata
            iodata -> iodata
          end

        nil ->
          page(fragment, base_path)
      end

    put_popstate_handler(document)
  end

  defp page(fragment, base_path) do
    script_path = bridge_path(base_path, @script_path)

    "<!doctype html><html><head><meta charset=\"utf-8\"><script type=\"module\" src=\"#{script_path}\"></script></head><body>#{fragment}</body></html>"
  end

  defp put_popstate_handler(document) do
    document = IO.iodata_to_binary(document)

    if String.contains?(document, "data-on:popstate__window") do
      document
    else
      attribute =
        AshUi.RenderTarget.Html.attributes_iodata(%{
          "data-on:popstate__window" => RenderTarget.popstate_expression()
        })
        |> IO.iodata_to_binary()

      case Regex.run(~r/<body(?=[\s>])/i, document, return: :index) do
        [{start, length}] ->
          offset = start + length
          <<head::binary-size(^offset), tail::binary>> = document
          head <> attribute <> tail

        nil ->
          document
      end
    end
  end

  # Segment-wise build: Regex.escape/1 does not escape ":", so an
  # escape-then-rewrite pass would leave :param segments literal.
  defp compile_route({path, _queries}) do
    segments = String.split(path, "/", trim: true)

    names =
      for <<prefix::binary-size(1), name::binary>> <- segments,
          prefix in [":", "*"],
          do: name

    pattern =
      Enum.map_join(segments, "/", fn
        ":" <> _name -> "([^/]+)"
        "*" <> _name -> "([^/]+)"
        literal -> Regex.escape(literal)
      end)

    {Regex.compile!("^/" <> pattern <> "$"), names}
  end

  defp match_route(routes, path) do
    Enum.find_value(routes, fn {resource, {regex, names}} ->
      case Regex.run(regex, path, capture: :all_but_first) do
        nil -> nil
        values -> {resource, names |> Enum.zip(values) |> Map.new()}
      end
    end)
  end

  defp domain_resources(domain) do
    if Code.ensure_loaded?(Ash.Domain.Info) and function_exported?(Ash.Domain.Info, :resources, 1),
      do: Ash.Domain.Info.resources(domain),
      else: []
  rescue
    _ -> []
  end

  defp maybe_put_upsert_identity(opts, resource) do
    case Enum.find(Ash.Resource.Info.identities(resource), &(:session_id in List.wrap(&1.keys))) do
      %{name: name} -> Keyword.put(opts, :upsert_identity, name)
      _none -> opts
    end
  end

  defp request_scope(conn, opts, session_id) do
    context = request_opt(conn, opts, :context, %{})

    unless is_map(context) do
      raise ArgumentError, ":context must be a map or a one-argument function returning a map"
    end

    actor =
      if Keyword.has_key?(opts, :actor),
        do: request_opt(conn, opts, :actor, nil),
        else: Map.get(context, :current_user)

    tenant =
      if Keyword.has_key?(opts, :tenant),
        do: request_opt(conn, opts, :tenant, nil),
        else: Map.get(context, :tenant)

    context =
      context
      |> Map.put(:session_id, session_id)
      |> Map.put(:ash_ui_mount_phase, :live)
      |> maybe_put_current_user(actor)
      |> Map.update(
        :shared,
        %{ash_ui_session_pid: Process.whereis(Store) || self()},
        fn
          shared when is_map(shared) ->
            Map.put(shared, :ash_ui_session_pid, Process.whereis(Store) || self())

          _other ->
            %{ash_ui_session_pid: Process.whereis(Store) || self()}
        end
      )

    %{actor: actor, tenant: tenant, context: context}
  end

  defp request_opt(conn, opts, key, default) do
    case Keyword.get(opts, key, default) do
      fun when is_function(fun, 1) -> fun.(conn)
      value -> value
    end
  end

  defp maybe_put_current_user(context, nil), do: context
  defp maybe_put_current_user(context, actor), do: Map.put_new(context, :current_user, actor)

  defp render_opts(scope, params, base_path, navigation_routes) do
    [
      actor: scope.actor,
      tenant: scope.tenant,
      context: scope.context,
      session_id: Map.get(scope.context, :session_id),
      params: params,
      navigation_routes: navigation_routes,
      base_path: base_path,
      reuse_loaded_values?: true
    ]
  end

  defp mount_session_id(conn, opts) do
    case extracted_session_id(conn, opts) do
      session_id when is_binary(session_id) -> {session_id, :external}
      nil -> {conn.cookies[@cookie] || AshUi.Session.generated_session_id(), :cookie}
    end
  end

  defp request_session_id(conn, opts),
    do: extracted_session_id(conn, opts) || conn.cookies[@cookie]

  defp request_client_id(conn) do
    case get_req_header(conn, @client_id_header) do
      [client_id | _rest]
      when is_binary(client_id) and byte_size(client_id) > 0 and byte_size(client_id) <= 128 ->
        client_id

      _missing_or_invalid ->
        nil
    end
  end

  defp extracted_session_id(conn, opts) do
    result =
      case Keyword.fetch(opts, :session_id) do
        :error ->
          nil

        {:ok, fun} when is_function(fun, 1) ->
          fun.(conn)

        {:ok, {module, function, args}}
        when is_atom(module) and is_atom(function) and is_list(args) ->
          apply(module, function, [conn | args])

        {:ok, extractor} ->
          raise ArgumentError,
                ":session_id must be a one-argument function or an {module, function, args} MFA, got: #{inspect(extractor)}"
      end

    if is_binary(result) or is_nil(result) do
      result
    else
      raise ArgumentError,
            ":session_id extractor must return a binary or nil, got: #{inspect(result)}"
    end
  end

  defp maybe_put_session_cookie(conn, _session_id, :external), do: conn

  defp maybe_put_session_cookie(conn, session_id, :cookie),
    do: put_resp_cookie(conn, @cookie, session_id, http_only: true, same_site: "Lax", path: "/")

  defp relative_path(%Plug.Conn{path_info: []}), do: "/"
  defp relative_path(%Plug.Conn{path_info: parts}), do: "/" <> Enum.join(parts, "/")

  defp request_location(conn) do
    query = conn.query_params |> Map.delete("datastar") |> URI.encode_query()

    case query do
      "" -> relative_path(conn)
      query -> relative_path(conn) <> "?" <> query
    end
  end

  defp base_path(conn, opts) do
    case Keyword.fetch(opts, :base_path) do
      {:ok, path} when is_binary(path) -> normalize_base_path(path)
      {:ok, path} -> raise ArgumentError, ":base_path must be a binary, got: #{inspect(path)}"
      :error -> normalize_base_path("/" <> Enum.join(conn.script_name, "/"))
    end
  end

  defp normalize_base_path(path) do
    path = path |> String.trim() |> String.trim_trailing("/")

    cond do
      path in ["", "/"] -> ""
      String.starts_with?(path, "/") -> path
      true -> "/" <> path
    end
  end

  defp bridge_path(base_path, path), do: base_path <> path

  # `pid` is the DELIVERY process. The spec builders stamp `self()`, which is
  # correct for in-request registration (the dispatch echo) but not when the
  # registration runs inside the session-owner transaction on behalf of the
  # updates stream — the stream passes its own pid and the specs are
  # remapped here, at the single registration point.
  defp register_notification_subscriptions(record, state, base_ref, previous_refs, pid \\ nil) do
    subscriptions =
      case notification_subscriptions(record, state, base_ref) do
        subscriptions when is_nil(pid) ->
          subscriptions

        subscriptions ->
          Map.new(subscriptions, fn {ref, spec} -> {ref, Map.put(spec, :pid, pid)} end)
      end

    refs = subscriptions |> Map.keys() |> MapSet.new()

    previous_refs
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

    refs
  end

  defp notification_subscriptions(record, state, base_ref) do
    root_ref = notification_ref(base_ref, record, :root)

    root =
      {root_ref,
       notification_subscription(
         record.__struct__,
         primary_key_values(record),
         nil,
         record,
         state,
         :root
       )}

    relationships =
      relationship_subscriptions(
        record,
        state,
        base_ref,
        [],
        MapSet.new(),
        AshUi.view_load(record.__struct__)
      )

    [root | relationships]
    |> AshUi.Notification.MatchIndex.compact_subscriptions(base_ref)
    |> Map.new()
  end

  defp relationship_subscriptions(
         %resource{} = record,
         state,
         base_ref,
         prefix,
         seen,
         load_spec
       ) do
    identity = {resource, record_identity(record)}

    if MapSet.member?(seen, identity) do
      []
    else
      seen = MapSet.put(seen, identity)

      derived_read_subscriptions(record, state, base_ref, prefix, load_spec) ++
        loaded_relationship_subscriptions(record, state, base_ref, prefix, seen, load_spec)
    end
  end

  # "Whatever a page reads, it subscribes to": the rows a loaded calculation
  # or aggregate derives from are hidden internal loads the walk below never
  # sees (AshUi.Notification.DerivedReads).
  defp derived_read_subscriptions(record, state, base_ref, prefix, load_spec) do
    record
    |> AshUi.Notification.DerivedReads.edges(load_spec, prefix)
    |> Enum.map(fn edge ->
      {notification_ref(base_ref, record, edge.key),
       notification_subscription(
         edge.resource,
         edge.attrs,
         edge.filter,
         edge.parent,
         state,
         edge.reload_scope
       )}
    end)
  end

  defp loaded_relationship_subscriptions(
         %resource{} = record,
         state,
         base_ref,
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
          ref = notification_ref(base_ref, record, path)
          child_load = relationship_child_load(load_spec, relationship.name)

          subscription =
            notification_subscription(
              relationship.destination,
              relationship_index_attrs(record, relationship),
              Map.get(relationship, :filter),
              record,
              state,
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
                    state,
                    base_ref,
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

  # The walk goes under a record whose load loads a relationship, or a
  # calculation or aggregate that derives from other rows: the record's
  # derived-read subscriptions are taken when it is walked
  # (`derived_read_subscriptions/5`), so a record loaded with derived fields
  # alone (a page's portfolio and its risk count) is walked too.
  defp recurse_notification_relationships?(resource, {:known, load}) do
    Enum.any?(load, fn
      {field, _nested} -> walked_field?(resource, field)
      field when is_atom(field) -> walked_field?(resource, field)
      _other -> false
    end)
  end

  defp walked_field?(resource, field) do
    not is_nil(Ash.Resource.Info.relationship(resource, field)) or
      AshUi.Reload.derived_reads(resource, field) != []
  end

  defp notification_subscription(resource, attrs, filter, parent, state, reload_scope) do
    %{
      pid: self(),
      resource: resource,
      attrs: attrs,
      filter: notification_filter(filter, state),
      parent: notification_filter_parent(filter, parent),
      reload_scope: reload_scope,
      tenant: state.tenant,
      domain: domain(resource)
    }
  end

  # The filter as the page's read applied it: its templates (`^actor(...)`,
  # `^tenant()`, `^context(...)`) filled with the session's scope. Left as
  # templates, `Ash.Filter.Runtime` resolves `{:_actor, _}` to `:unknown`, so a
  # relationship or aggregate filtered on the actor never matched a notification
  # and the page kept the value it read before the action.
  defp notification_filter(filter, _state) when filter in [nil, []], do: filter

  defp notification_filter(filter, state) do
    Ash.Expr.fill_template(filter,
      actor: Map.get(state, :actor),
      tenant: Map.get(state, :tenant),
      context: Map.get(state, :context) || %{}
    )
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

  defp notification_ref(base_ref, record, edge) do
    {base_ref, record.__struct__, record_identity(record), edge}
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

  defp protocol(conn) do
    case get_http_protocol(conn) do
      protocol when protocol in [:"HTTP/1.0", :"HTTP/1.1"] -> :http1
      _other -> :http2
    end
  end

  defp measure_dispatch_layer(layer, fun) when is_atom(layer) and is_function(fun, 0) do
    started = System.monotonic_time()

    :telemetry.execute(
      [:ash_ui, :datastar, :dispatch, :layer, :start],
      %{},
      %{layer: layer}
    )

    try do
      fun.()
    after
      :telemetry.execute(
        [:ash_ui, :datastar, :dispatch, :layer],
        %{duration: System.monotonic_time() - started},
        %{layer: layer}
      )
    end
  end

  defp measure_mount_layer(layer, fun) when is_atom(layer) and is_function(fun, 0) do
    started = System.monotonic_time()

    :telemetry.execute(
      [:ash_ui, :mount, :layer, :start],
      %{},
      %{adapter: :datastar, layer: layer}
    )

    try do
      fun.()
    after
      :telemetry.execute(
        [:ash_ui, :mount, :layer],
        %{duration: System.monotonic_time() - started},
        %{adapter: :datastar, layer: layer}
      )
    end
  end

  defp domain(resource), do: Ash.Resource.Info.domain(resource) || AshUi.AshDomainFallback

  defp error(conn, status, reason) do
    body = Jason.encode!(%{error: inspect(reason)})
    conn |> put_resp_content_type("application/json") |> send_resp(status, body)
  end
end
