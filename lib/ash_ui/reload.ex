defmodule AshUi.Reload do
  @moduledoc """
  The O(1) dispatch reload contract — the ONE canonical policy for what a
  bridge reloads after a dispatch. Every transport bridge calls
  `after_dispatch/4`; none owns a private copy of the policy, so a new
  target cannot drift from it.

  The contract:

    * Data reloads are exactly (a) the notification ECHO — the action's own
      synchronous write notifications, scoped to the view dependency they
      touched — and (b) the view roots whose declared read depends on a root
      attribute the action changed (`dependent_roots_for_attributes/2`).
    * Compiler event paths (a binding's each source and render deps) are
      RENDER scope only — they address the differential re-render and never
      justify a data read: entry rows did not change unless a notification
      says so.
    * A `:root`-scoped echo is the page row's own write notification. The
      dispatch result is already the authoritative fresh root row, so it
      adds no data reload (the historical drift: one bridge dropped it, the
      other answered with a full view reload).
    * Unaffected dependencies keep their already-loaded values
      (`AshUi.preserve_loaded_values/2`).

  Dependency narrowing derives from declarations, never from code:

    * A declarative relationship depends on its `source_attribute` and any
      root attribute referenced through `parent(...)` in its filter. A
      `has_many` window also depends on the attributes its read action's
      arguments are bound from, its `sort_by` and its `offset` or `after`.
    * A `manual` relationship's read is opaque; it conservatively depends on
      every attribute unless the declaration names its dependency set:
      `manual {MyRel, depends_on: [:sort_by, :q]}` (an empty list is a valid
      declaration: the read depends on no root attribute).
    * An expression calculation depends on the root attributes its expression
      references (through other calculations transitively) and is invalidated
      by data changes on any relationship path it references.
    * A module calculation declares its dependencies through `load/3`; when
      that cannot be read it conservatively depends on everything.
    * An aggregate depends on its relationship path's first edge exactly like
      a declarative relationship, and is invalidated by data changes on that
      path.
  """

  @type dep :: :all | %{attributes: MapSet.t(atom()), relationships: MapSet.t(atom())}

  @doc """
  True when the dispatch result is the same session row the page renders —
  the case where the action result IS the fresh page state and the narrowed
  refresh applies. Any other row needs the page re-read.
  """
  @spec same_row?(struct(), struct()) :: boolean()
  def same_row?(%_{} = current, %_{} = updated) do
    updated.__struct__ == current.__struct__ and
      AshUi.Patch.Keys.entry_key(updated, 0) ==
        AshUi.Patch.Keys.entry_key(current, 0)
  end

  @doc """
  The canonical post-dispatch refresh. `current` is the rendered page record,
  `updated` the same-row action result, `echo` the dispatch's notification
  echo (`:root` or a list of `:root`/relationship-path entries). Returns the
  record to render from, with unaffected loaded values preserved and only the
  affected dependencies re-read.
  """
  @spec after_dispatch(struct(), struct(), :root | [term()], keyword()) ::
          {:ok, struct()} | {:error, term()}
  def after_dispatch(%resource{} = current, %resource{} = updated, echo, opts \\ []) do
    echo_paths =
      echo
      |> List.wrap()
      |> Enum.filter(&match?([root | _rest] when is_atom(root), &1))
      |> Enum.uniq()

    dependent_paths =
      resource
      |> dependent_roots_for_attributes(changed_attributes(current, updated))
      |> Enum.map(&[&1])

    to_reload = Enum.uniq(echo_paths ++ dependent_paths)
    record = AshUi.preserve_loaded_values(current, updated)

    if to_reload == [] do
      {:ok, record}
    else
      AshUi.reload_dependencies(record, to_reload, reload_opts(resource, opts))
    end
  end

  @doc """
  Root attributes whose value differs between the rendered record and the
  action result — the attribute-diff half of the reload contract.
  """
  @spec changed_attributes(struct(), struct()) :: [atom()]
  def changed_attributes(%resource{} = current, %resource{} = updated) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.map(& &1.name)
    |> Enum.filter(fn name -> Map.get(current, name) != Map.get(updated, name) end)
  end

  @doc """
  The top-level view dependencies whose value can change when the given root
  attributes change, per the declaration-derived dependency index.
  """
  @spec dependent_roots_for_attributes(module(), [atom()]) :: [atom()]
  def dependent_roots_for_attributes(_resource, []), do: []

  def dependent_roots_for_attributes(resource, changed_attributes) do
    changed = MapSet.new(changed_attributes)

    for {root, dep} <- view_dependency_index(resource),
        dep == :all or not MapSet.disjoint?(dep.attributes, changed) do
      root
    end
  end

  @doc """
  The top-level view roots invalidated by a DATA change on the given
  relationship paths: calculations and aggregates whose declared dependencies
  traverse a changed path. This is what keeps a derived root (a flattened
  rows calculation over `:messages`, an aggregate over `:albums`) fresh when
  the change arrives as a notification rather than a root-attribute write.
  """
  @spec dependent_roots_for_paths(module(), [[atom()] | atom()]) :: [atom()]
  def dependent_roots_for_paths(_resource, []), do: []

  def dependent_roots_for_paths(resource, paths) do
    heads =
      paths
      |> Enum.map(fn
        [head | _rest] -> head
        head when is_atom(head) -> head
      end)
      |> MapSet.new()

    for {root, dep} <- view_dependency_index(resource),
        not MapSet.member?(heads, root),
        match?(%{relationships: _}, dep) and not MapSet.disjoint?(dep.relationships, heads) do
      root
    end
  end

  @doc false
  # Declaration-derived dependencies of every top-level view dependency,
  # memoized alongside the other compile-time contracts in
  # `AshUi.Compiled`. List-shaped to keep view_load order
  # deterministic in every consumer.
  @spec view_dependency_index(module()) :: [{atom(), dep()}]
  def view_dependency_index(resource),
    do: AshUi.Compiled.reload_dependency_index(resource)

  @doc false
  # The uncached index build — called only through the Compiled memo above.
  @spec build_dependency_index(module()) :: [{atom(), dep()}]
  def build_dependency_index(resource), do: build_index(resource)

  defp reload_opts(resource, opts) do
    opts
    |> Keyword.put_new(
      :domain,
      Ash.Resource.Info.domain(resource) || AshUi.AshDomainFallback
    )
    |> Keyword.put_new(:authorize?, true)
  end

  @doc """
  What a derived view field READS, from the same declaration-derived
  dependency derivation the reload index uses: every relationship path a
  calculation or aggregate traverses (through `load/3`, DSL `load:`,
  expression references, aggregate paths and nested calculations or
  aggregates), and `{:resource, module}` for an aggregate over an unrelated
  resource. This is the subscription side of "whatever a page reads, it
  subscribes to": Ash loads these dependencies as hidden internal loads, so
  they never appear on the rendered record for a relationship walk to see.

  An undeclarable dependency (a raising `load/3`, an expression Ash cannot
  walk) contributes nothing beyond what was already derived.
  """
  @spec derived_reads(module(), atom()) :: [[atom()] | {:resource, module()}]
  def derived_reads(resource, field) when is_atom(resource) and is_atom(field),
    do: AshUi.Compiled.derived_reads(resource, field)

  @doc false
  # The uncached read-set build — called only through the Compiled memo above.
  @spec build_derived_reads(module(), atom()) :: [[atom()] | {:resource, module()}]
  def build_derived_reads(resource, field) do
    resource
    |> field_dep(field, MapSet.new([{resource, field}]))
    |> Map.fetch!(:reads)
    |> Enum.sort()
  end

  defp build_index(resource) do
    resource
    |> AshUi.view_load()
    |> Enum.map(fn
      {root, _nested} -> root
      root when is_atom(root) -> root
    end)
    |> Enum.uniq()
    |> Enum.map(fn root -> {root, project(root_dep(resource, root))} end)
  end

  # The derivation tracks three components: root attributes, first-edge
  # relationships, and full read paths. The public index keeps its historical
  # shape: any unknown attribute or relationship component is `:all`.
  defp project(%{attributes: :all}), do: :all
  defp project(%{relationships: :all}), do: :all

  defp project(%{attributes: attributes, relationships: relationships}),
    do: %{attributes: attributes, relationships: relationships}

  defp none, do: %{attributes: MapSet.new(), relationships: MapSet.new(), reads: MapSet.new()}

  # Unknown attribute/relationship dependence; reads contribute nothing.
  defp unknown, do: %{attributes: :all, relationships: :all, reads: MapSet.new()}

  defp attributes_dep(names), do: %{none() | attributes: MapSet.new(names)}

  defp root_dep(resource, root) do
    case Ash.Resource.Info.relationship(resource, root) do
      nil ->
        field_dep(resource, root, MapSet.new([{resource, root}]))

      %{manual: manual} when not is_nil(manual) ->
        manual_dep(manual)

      relationship ->
        declared_relationship_dep(relationship)
    end
  end

  # A no_attributes? relationship joins through nothing — its filter's
  # parent() refs, and its window's source attributes, are the entire
  # attribute dependency.
  defp declared_relationship_dep(relationship) do
    source =
      if Map.get(relationship, :no_attributes?), do: nil, else: relationship.source_attribute

    [source | parent_attribute_refs(relationship.filter)]
    |> Enum.concat(window_attribute_refs(Map.get(relationship, :window)))
    |> Enum.reject(&is_nil/1)
    |> attributes_dep()
  end

  # A window (`has_many ... window`) reads its relationship's action with
  # arguments, a sort and a position taken from the source record: the
  # attributes its arguments are bound from (`parent:`), its `sort_by`, and
  # its `offset` or `after` cursor.
  defp window_attribute_refs(nil), do: []

  defp window_attribute_refs(window) do
    [window.sort_by, window.offset, window.after | Enum.map(window.arguments, & &1.parent)]
  end

  defp manual_dep({_module, opts}) when is_list(opts) do
    case Keyword.get(opts, :depends_on) do
      attributes when is_list(attributes) ->
        if Enum.all?(attributes, &is_atom/1) do
          attributes_dep(attributes)
        else
          %{none() | attributes: :all}
        end

      _undeclared ->
        %{none() | attributes: :all}
    end
  end

  defp manual_dep(_module_only), do: %{none() | attributes: :all}

  defp field_dep(resource, field, seen) do
    cond do
      calculation = Ash.Resource.Info.calculation(resource, field) ->
        calculation_dep(resource, calculation, seen)

      aggregate = Ash.Resource.Info.aggregate(resource, field) ->
        aggregate_dep(resource, aggregate, seen)

      Ash.Resource.Info.attribute(resource, field) ->
        attributes_dep([field])

      true ->
        unknown()
    end
  end

  defp calculation_dep(resource, %{calculation: calculation} = calc_struct, seen) do
    # The DSL-declared `load([...])` lives on the calculation STRUCT, not on
    # the {module, opts} tuple — anonymous-function calcs (module
    # Ash.Resource.Calculation.Function) declare their whole dependency set
    # there. Without merging it, a function calc over a relationship registers
    # no relationship deps and dependent_roots_for_paths never invalidates it
    # (the transcript-window class of live-update failure).
    declared = loads_dep(resource, List.wrap(Map.get(calc_struct, :load) || []), seen)

    computed =
      case calculation do
        {Ash.Resource.Calculation.Expression, opts} ->
          expression_dep(resource, Keyword.get(opts, :expr), seen)

        {module, opts} when is_atom(module) ->
          module_calculation_dep(resource, module, opts, seen)

        _opaque ->
          unknown()
      end

    merge_dep(declared, computed)
  end

  defp calculation_dep(_resource, _other, _seen), do: unknown()

  defp expression_dep(_resource, nil, _seen), do: unknown()

  defp expression_dep(resource, expr, seen) do
    refs =
      try do
        Ash.Filter.list_refs(expr)
      rescue
        # broad rescue: an expression template Ash cannot walk must degrade
        # to the conservative dependency, never abort the dispatch.
        _unwalkable -> :error
      end

    case refs do
      :error ->
        unknown()

      refs ->
        exists_paths = exists_paths(expr)

        base = %{
          attributes: MapSet.new(parent_attribute_refs(expr)),
          relationships: MapSet.new(exists_paths, &hd/1),
          reads: MapSet.new(exists_paths)
        }

        Enum.reduce(refs, base, fn ref, acc -> merge_dep(acc, ref_dep(resource, ref, seen)) end)
    end
  end

  defp ref_dep(resource, %{relationship_path: [head | _rest] = path} = ref, seen)
       when is_atom(head) do
    %{
      none()
      | relationships: MapSet.new([head]),
        reads: MapSet.new([path | destination_reads(resource, path, ref_name(ref), seen)])
    }
  end

  defp ref_dep(resource, %{relationship_path: []} = ref, seen) do
    name = ref_name(ref)

    cond do
      is_nil(name) ->
        unknown()

      Ash.Resource.Info.attribute(resource, name) ->
        attributes_dep([name])

      Ash.Resource.Info.relationship(resource, name) ->
        %{none() | relationships: MapSet.new([name]), reads: MapSet.new([[name]])}

      MapSet.member?(seen, {resource, name}) ->
        none()

      true ->
        field_dep(resource, name, MapSet.put(seen, {resource, name}))
    end
  end

  defp ref_dep(_resource, _ref, _seen), do: unknown()

  defp ref_name(%{attribute: %{name: name}}) when is_atom(name), do: name
  defp ref_name(%{attribute: name}) when is_atom(name), do: name
  defp ref_name(_ref), do: nil

  # What a calculation/aggregate on a relationship's DESTINATION reads, as
  # paths from the owning resource. Only the reads carry across the hop: the
  # destination's own attributes are not root attributes.
  defp destination_reads(resource, path, field, seen) do
    with destination when not is_nil(destination) <- path_destination(resource, path),
         true <- is_atom(field) and not is_nil(field),
         false <- MapSet.member?(seen, {destination, field}),
         true <-
           not is_nil(Ash.Resource.Info.calculation(destination, field)) or
             not is_nil(Ash.Resource.Info.aggregate(destination, field)) do
      destination
      |> field_dep(field, MapSet.put(seen, {destination, field}))
      |> prefixed_reads(path)
    else
      _no_derived_destination_field -> []
    end
  end

  defp prefixed_reads(%{reads: reads}, path) do
    Enum.map(reads, fn
      {:resource, _resource} = unrelated -> unrelated
      nested when is_list(nested) -> path ++ nested
    end)
  end

  defp path_destination(resource, []), do: resource

  defp path_destination(resource, [name | rest]) do
    case Ash.Resource.Info.relationship(resource, name) do
      %{destination: destination} -> path_destination(destination, rest)
      nil -> nil
    end
  end

  # A module calculation's `load/3` IS its dependency declaration: attributes
  # it selects, relationships and calculations it loads. Unreadable loads
  # (raising implementations, non-list returns) stay conservative.
  defp module_calculation_dep(resource, module, opts, seen) do
    loads =
      try do
        if function_exported?(module, :load, 3) do
          module.load(nil, opts || [], %Ash.Resource.Calculation.Context{arguments: %{}})
        else
          []
        end
      rescue
        # broad rescue: `load/3` is arbitrary user code called for its
        # declaration only — a raising implementation must degrade to the
        # conservative dependency, never abort the dispatch.
        _undeclarable -> :error
      end

    loads_dep(resource, loads, seen)
  end

  defp loads_dep(resource, loads, seen) when is_list(loads) do
    Enum.reduce(loads, none(), fn load, acc ->
      merge_dep(acc, load_entry_dep(resource, load, seen))
    end)
  end

  defp loads_dep(_resource, _loads, _seen), do: unknown()

  defp load_entry_dep(resource, {field, nested}, seen) when is_atom(field) do
    case Ash.Resource.Info.relationship(resource, field) do
      %{destination: destination} ->
        nested_reads =
          if is_list(nested) do
            destination |> loads_dep(nested, seen) |> prefixed_reads([field])
          else
            []
          end

        %{
          none()
          | relationships: MapSet.new([field]),
            reads: MapSet.new([[field] | nested_reads])
        }

      nil ->
        load_entry_dep(resource, field, seen)
    end
  end

  defp load_entry_dep(resource, field, seen) when is_atom(field) do
    cond do
      Ash.Resource.Info.relationship(resource, field) ->
        %{none() | relationships: MapSet.new([field]), reads: MapSet.new([[field]])}

      MapSet.member?(seen, {resource, field}) ->
        none()

      true ->
        field_dep(resource, field, MapSet.put(seen, {resource, field}))
    end
  end

  defp load_entry_dep(_resource, _other, _seen), do: unknown()

  # An aggregate reads rows through its relationship path: root-attribute
  # dependence enters only through the first edge's declared query, and any
  # data change along that edge invalidates the value.
  defp aggregate_dep(resource, %{relationship_path: [head | _rest] = path} = aggregate, seen) do
    edge =
      case Ash.Resource.Info.relationship(resource, head) do
        nil ->
          none()

        %{manual: manual} when not is_nil(manual) ->
          manual_dep(manual)

        relationship ->
          declared_relationship_dep(relationship)
      end

    merge_dep(edge, %{
      none()
      | relationships: MapSet.new([head]),
        reads: MapSet.new([path | destination_reads(resource, path, aggregate.field, seen)])
    })
  end

  # An aggregate over an UNRELATED resource has no relationship edge: its
  # attribute dependence stays conservative, and it reads that resource.
  defp aggregate_dep(_resource, %{related?: false, resource: source}, _seen)
       when is_atom(source) and not is_nil(source),
       do: %{unknown() | reads: MapSet.new([{:resource, source}])}

  defp aggregate_dep(_resource, _aggregate, _seen), do: unknown()

  defp merge_dep(left, right) do
    %{
      attributes: union(left.attributes, right.attributes),
      relationships: union(left.relationships, right.relationships),
      reads: MapSet.union(left.reads, right.reads)
    }
  end

  defp union(:all, _right), do: :all
  defp union(_left, :all), do: :all
  defp union(left, right), do: MapSet.union(left, right)

  @doc false
  # Attribute names referenced through `parent(...)` in a relationship filter
  # or calculation expression — the channel through which a declared read
  # depends on the owner's non-key attributes.
  def parent_attribute_refs(nil), do: []

  def parent_attribute_refs(expression),
    do: expression |> collect_parent_refs([]) |> Enum.uniq()

  defp exists_paths(expression), do: expression |> collect_exists_paths([]) |> Enum.uniq()

  defp collect_exists_paths(%Ash.Query.Exists{path: path}, acc), do: path_from(path, acc)

  defp collect_exists_paths(%Ash.Query.Call{name: :exists, args: [path | _rest]}, acc),
    do: path_from(path, acc)

  defp collect_exists_paths(%_{} = struct, acc) do
    struct
    |> Map.from_struct()
    |> Map.values()
    |> Enum.reduce(acc, &collect_exists_paths/2)
  end

  defp collect_exists_paths(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &collect_exists_paths/2)

  defp collect_exists_paths(%{} = map, acc),
    do: map |> Map.values() |> Enum.reduce(acc, &collect_exists_paths/2)

  defp collect_exists_paths(tuple, acc) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.reduce(acc, &collect_exists_paths/2)

  defp collect_exists_paths(_other, acc), do: acc

  defp path_from([head | _rest] = path, acc) when is_atom(head) do
    if Enum.all?(path, &is_atom/1), do: [path | acc], else: [[head] | acc]
  end

  defp path_from(head, acc) when is_atom(head) and not is_nil(head), do: [[head] | acc]
  defp path_from(_other, acc), do: acc

  # `parent(:attr)` stores the bare attribute name as the Parent expr.
  defp collect_parent_refs(%Ash.Query.Parent{expr: name}, acc)
       when is_atom(name) and name not in [nil, true, false],
       do: [name | acc]

  defp collect_parent_refs(%Ash.Query.Parent{expr: expr}, acc),
    do: collect_expr_refs(expr, acc)

  defp collect_parent_refs(%Ash.Query.Call{name: :parent, args: args}, acc) do
    Enum.reduce(args, acc, fn
      name, acc when is_atom(name) and name not in [nil, true, false] -> [name | acc]
      other, acc -> collect_expr_refs(other, acc)
    end)
  end

  defp collect_parent_refs(%_{} = struct, acc) do
    struct
    |> Map.from_struct()
    |> Map.values()
    |> Enum.reduce(acc, &collect_parent_refs/2)
  end

  defp collect_parent_refs(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &collect_parent_refs/2)

  defp collect_parent_refs(%{} = map, acc),
    do: map |> Map.values() |> Enum.reduce(acc, &collect_parent_refs/2)

  defp collect_parent_refs(tuple, acc) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.reduce(acc, &collect_parent_refs/2)

  defp collect_parent_refs(_other, acc), do: acc

  defp collect_expr_refs(%Ash.Query.Ref{attribute: %{name: name}}, acc), do: [name | acc]

  defp collect_expr_refs(%Ash.Query.Ref{attribute: name}, acc) when is_atom(name),
    do: [name | acc]

  # Unhydrated authoring-surface refs (`{:_ref, path, name}`) appear in
  # relationship filters that Ash has not yet hydrated.
  defp collect_expr_refs({:_ref, _path, name}, acc) when is_atom(name), do: [name | acc]

  defp collect_expr_refs(%_{} = struct, acc) do
    struct
    |> Map.from_struct()
    |> Map.values()
    |> Enum.reduce(acc, &collect_expr_refs/2)
  end

  defp collect_expr_refs(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &collect_expr_refs/2)

  defp collect_expr_refs(%{} = map, acc),
    do: map |> Map.values() |> Enum.reduce(acc, &collect_expr_refs/2)

  defp collect_expr_refs(tuple, acc) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.reduce(acc, &collect_expr_refs/2)

  defp collect_expr_refs(_other, acc), do: acc
end
