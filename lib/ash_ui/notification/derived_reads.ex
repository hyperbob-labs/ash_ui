defmodule AshUi.Notification.DerivedReads do
  @moduledoc """
  Subscription edges for what a rendered record DERIVES: "whatever a page
  reads, it subscribes to".

  The relationship walk in each transport adapter subscribes a page to the
  relationships actually loaded on its record. A calculation or aggregate
  the view renders reads more than that: Ash loads its dependencies as hidden
  internal loads, so those rows never appear on the record and the walk
  never sees them. This module turns the declaration-derived read set
  (`AshUi.Reload.derived_reads/2`, the same derivation the reload
  contract narrows with) into subscription edges for one loaded record:

    * the first hop of a relationship read, taken from the loaded record, is
      key-matched on `destination_attribute = record[source_attribute]` and
      carries the relationship filter with the record as `parent` — the same
      precision the relationship walk registers;
    * later hops, and aggregates over unrelated resources, have no derivable
      key and subscribe at resource level (`attrs: []`);
    * a first hop the record already has loaded, with nothing beyond it, is
      left to the walk at the root, whose reload of that relationship already
      recomputes every dependent root (`Reload.dependent_roots_for_paths/2`).

  Each edge reloads `prefix ++ [field]`: the derived value itself, recomputed
  by Ash with its hidden dependencies, instead of materializing the
  relationship on the record.
  """

  # `key` names the derived field by its path from the page row
  # (`prefix ++ [field]`): an adapter's subscription ref is the record and the
  # key, and one record the page loads under two paths needs a subscription,
  # and a reload scope, under each.
  @type edge :: %{
          key: term(),
          resource: module(),
          attrs: keyword(),
          filter: term(),
          parent: struct() | nil,
          reload_scope: [atom()]
        }

  @doc """
  The derived-read subscription edges of `record`, whose view load at this
  level is `load_spec`, reached through relationship path `prefix`.
  """
  @spec edges(struct(), term(), [atom()]) :: [edge()]
  def edges(%resource{} = record, load_spec, prefix) when is_list(prefix) do
    load_spec
    |> List.wrap()
    |> Enum.flat_map(fn
      {field, _nested} when is_atom(field) -> [field]
      field when is_atom(field) -> [field]
      _other -> []
    end)
    |> Enum.uniq()
    |> Enum.filter(&derived_field_loaded?(record, resource, &1))
    |> Enum.flat_map(fn field ->
      resource
      |> AshUi.Reload.derived_reads(field)
      |> Enum.flat_map(&read_edges(record, resource, field, &1, prefix))
    end)
  end

  defp derived_field_loaded?(record, resource, field) do
    derived? =
      not is_nil(Ash.Resource.Info.calculation(resource, field)) or
        not is_nil(Ash.Resource.Info.aggregate(resource, field))

    derived? and not match?(%Ash.NotLoaded{}, Map.get(record, field, %Ash.NotLoaded{}))
  end

  defp read_edges(_record, _resource, field, {:resource, source} = read, prefix) do
    [resource_edge(field, read, 0, source, prefix)]
  end

  defp read_edges(record, resource, field, [head | rest] = read, prefix) do
    case Ash.Resource.Info.relationship(resource, head) do
      nil ->
        []

      relationship ->
        covered_by_walk? =
          prefix == [] and rest == [] and
            not match?(%Ash.NotLoaded{}, Map.get(record, head, %Ash.NotLoaded{}))

        first =
          if covered_by_walk? do
            []
          else
            [
              %{
                key: {:derived_read, prefix ++ [field], read, 0},
                resource: relationship.destination,
                attrs: index_attrs(record, relationship),
                filter: Map.get(relationship, :filter),
                parent: record,
                reload_scope: prefix ++ [field]
              }
            ]
          end

        first ++ later_hops(relationship.destination, rest, field, read, 1, prefix)
    end
  end

  defp read_edges(_record, _resource, _field, _read, _prefix), do: []

  defp later_hops(_resource, [], _field, _read, _depth, _prefix), do: []

  defp later_hops(resource, [name | rest], field, read, depth, prefix) do
    case Ash.Resource.Info.relationship(resource, name) do
      nil ->
        []

      %{destination: destination} ->
        [
          resource_edge(field, read, depth, destination, prefix)
          | later_hops(destination, rest, field, read, depth + 1, prefix)
        ]
    end
  end

  defp resource_edge(field, read, depth, resource, prefix) do
    %{
      key: {:derived_read, prefix ++ [field], read, depth},
      resource: resource,
      attrs: [],
      filter: nil,
      parent: nil,
      reload_scope: prefix ++ [field]
    }
  end

  # The relationship walk's key-match rule, applied to the first hop.
  defp index_attrs(_record, %{no_attributes?: true}), do: []

  defp index_attrs(record, relationship) do
    with source when is_atom(source) <- Map.get(relationship, :source_attribute),
         destination when is_atom(destination) <- Map.get(relationship, :destination_attribute),
         value when not is_nil(value) <- Map.get(record, source) do
      [{destination, value}]
    else
      _unindexed -> []
    end
  end
end
