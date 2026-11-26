defmodule AshUi.Session do
  @moduledoc false

  import Ash.Expr
  require Ash.Query

  @spec session_id_from(term()) :: String.t() | nil
  def session_id_from(value), do: session_id_from_opts(context_to_opts(value))

  @spec generated_session_id() :: String.t()
  def generated_session_id do
    Ash.UUID.generate()
  end

  def data_layer_context(resource, row_or_rows, _opts \\ []) when is_atom(resource) do
    rows = List.wrap(row_or_rows)

    %{
      data_layer: %{
        data: %{resource => rows},
        ash_ui: %{
          rows: rows,
          row: List.first(rows)
        }
      }
    }
  end

  @spec prepare_changeset(Ash.Changeset.t()) :: Ash.Changeset.t()
  def prepare_changeset(%Ash.Changeset{} = changeset) do
    restore_string_defaults(changeset)
  end

  @spec cleanup_session(module() | [module()], String.t(), keyword()) :: :ok | {:error, term()}
  def cleanup_session(resources, session_id, opts \\ [])

  def cleanup_session(_resources, session_id, _opts)
      when not is_binary(session_id) or session_id == "",
      do: :ok

  def cleanup_session(resources, session_id, opts) do
    resources
    |> List.wrap()
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn resource, :ok ->
      case cleanup_resource_session(resource, session_id, opts) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  @spec sweep_sessions(module() | [module()], [String.t()] | MapSet.t(), keyword()) ::
          :ok | {:error, term()}
  def sweep_sessions(resources, live_session_ids, opts \\ []) do
    live_session_ids = MapSet.new(live_session_ids)

    resources
    |> List.wrap()
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn resource, :ok ->
      with {:ok, rows} <- read_ets_rows(resource, opts),
           dead_session_ids <-
             rows
             |> Enum.map(&Map.get(&1, :session_id))
             |> Enum.filter(
               &(is_binary(&1) and &1 != "" and not MapSet.member?(live_session_ids, &1))
             )
             |> Enum.uniq(),
           :ok <- cleanup_dead_sessions(resource, dead_session_ids, opts) do
        {:cont, :ok}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp cleanup_resource_session(resource, session_id, opts) do
    domain = Keyword.get(opts, :domain) || AshUi.AshDomainFallback.ensure!(resource)
    tenant = Keyword.get(opts, :tenant)
    actor = Keyword.get(opts, :actor)
    context = %{private: %{actor: actor}}
    ash_query = resource |> Ash.Query.new() |> Ash.Query.filter(expr(session_id == ^session_id))

    query =
      resource
      |> Ash.DataLayer.Ets.resource_to_query(domain)
      |> then(fn query ->
        with {:ok, query} <- Ash.DataLayer.Ets.set_context(resource, query, context),
             {:ok, query} <- maybe_set_ets_tenant(resource, query, tenant),
             {:ok, query} <- Ash.DataLayer.Ets.filter(query, ash_query.filter, resource) do
          {:ok, query}
        end
      end)

    with {:ok, query} <- query do
      Ash.DataLayer.Ets.destroy_query(
        query,
        cleanup_changeset(resource, domain, tenant, actor),
        resource,
        return_records?: false
      )
    end
  end

  defp read_ets_rows(resource, opts) do
    read_opts =
      [
        authorize?: false,
        domain: Keyword.get(opts, :domain) || AshUi.AshDomainFallback.ensure!(resource)
      ]
      |> maybe_put_kw(:tenant, Keyword.get(opts, :tenant))

    Ash.read(resource, read_opts)
  end

  defp cleanup_dead_sessions(_resource, [], _opts), do: :ok

  defp cleanup_dead_sessions(resource, [session_id | rest], opts) do
    with :ok <- cleanup_resource_session(resource, session_id, opts) do
      cleanup_dead_sessions(resource, rest, opts)
    end
  end

  defp cleanup_changeset(resource, domain, tenant, actor) do
    tenant = tenant && Ash.ToTenant.to_tenant(tenant, resource)

    %Ash.Changeset{
      resource: resource,
      domain: domain,
      action: %{
        name: :__ash_ui_cleanup_session__,
        type: :destroy,
        notifiers: []
      },
      action_type: :destroy,
      tenant: tenant,
      to_tenant: tenant,
      context: %{private: %{actor: actor}},
      data: %{}
    }
  end

  defp restore_string_defaults(%Ash.Changeset{} = changeset) do
    attributes_by_name =
      changeset.resource
      |> Ash.Resource.Info.attributes()
      |> Enum.map(&{&1.name, &1})
      |> Map.new()

    {restored_attributes, restored_fields} =
      Enum.reduce(changeset.attributes, {changeset.attributes, MapSet.new()}, fn {name, value},
                                                                                 {acc, restored} ->
        case {Map.get(attributes_by_name, name), value} do
          {%{type: type, allow_nil?: false} = attribute, nil}
          when type in [:string, Ash.Type.String] ->
            replacement =
              case attribute.default do
                default when is_binary(default) -> default
                _other -> current_string(changeset.data, name)
              end

            if is_binary(replacement) do
              {Map.put(acc, name, replacement), MapSet.put(restored, name)}
            else
              {acc, restored}
            end

          _other ->
            {acc, restored}
        end
      end)

    retained_errors =
      Enum.reject(changeset.errors, fn
        %Ash.Error.Changes.Required{field: field} -> MapSet.member?(restored_fields, field)
        _other -> false
      end)

    %{
      changeset
      | attributes: restored_attributes,
        errors: retained_errors,
        valid?: retained_errors == []
    }
  end

  defp current_string(data, name) do
    case Map.get(data, name) do
      current when is_binary(current) -> current
      _other -> nil
    end
  end

  defp session_id_from_opts(opts) when is_list(opts) do
    context = Keyword.get(opts, :context, %{}) || %{}

    session =
      Keyword.get(opts, :session) || blueprint_session(context) || Map.get(context, :session) ||
        %{}

    first_present([
      Keyword.get(opts, :session_id),
      map_get(context, :session_id),
      map_get(context, "session_id"),
      map_get(session, :session_id),
      map_get(session, "session_id"),
      map_get(session, :id),
      map_get(session, "id")
    ])
  end

  defp context_to_opts(context) when is_map(context) do
    [context: context, session: blueprint_session(context) || Map.get(context, :session)]
  end

  defp context_to_opts(_context), do: []

  defp blueprint_session(context) when is_map(context) do
    get_in(context, [:ash_ui, :session]) ||
      get_in(context, ["ash_ui", "session"])
  end

  defp blueprint_session(_context), do: nil

  defp first_present(values) do
    Enum.find(values, &(is_binary(&1) and &1 != ""))
  end

  defp map_get(map, key) when is_map(map), do: Map.get(map, key)
  defp map_get(_map, _key), do: nil

  defp maybe_set_ets_tenant(_resource, query, nil), do: {:ok, query}

  defp maybe_set_ets_tenant(resource, query, tenant),
    do: Ash.DataLayer.Ets.set_tenant(resource, query, Ash.ToTenant.to_tenant(tenant, resource))

  defp maybe_put_kw(opts, _key, nil), do: opts
  defp maybe_put_kw(opts, key, value), do: Keyword.put(opts, key, value)
end
