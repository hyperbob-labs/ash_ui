defmodule AshUi.ViewConstructor do
  @moduledoc false

  alias Ash.Query.Call
  alias AshUi.EventBinding
  alias AshUi.Expr.Compiled

  @element_tags %{
    article: :article,
    aside: :aside,
    box: :div,
    break: :br,
    button: :button,
    caption: :caption,
    cell: :td,
    checkbox: :input,
    dialog: :dialog,
    em: :em,
    fieldset: :fieldset,
    footer: :footer,
    form: :form,
    header: :header,
    header_cell: :th,
    heading: :h1,
    hidden: :input,
    image: :img,
    inline: :span,
    input: :input,
    item: :li,
    label: :label,
    legend: :legend,
    link: :a,
    list: :ul,
    main: :main,
    nav: :nav,
    option: :option,
    paragraph: :p,
    popover: :div,
    radio: :input,
    row: :tr,
    section: :section,
    select: :select,
    small: :small,
    strong: :strong,
    table: :table,
    table_body: :tbody,
    table_foot: :tfoot,
    table_head: :thead,
    textarea: :textarea
  }

  @special_names MapSet.new([
                   :attr,
                   :each,
                   :el,
                   :event,
                   :fragment,
                   :if,
                   :island,
                   :key,
                   :mark,
                   :nothing,
                   :render,
                   :text
                 ])
  @constructor_names MapSet.union(MapSet.new(Map.keys(@element_tags)), @special_names)
  @event_prefix "on_"
  @reserved_opts [
    :action_input,
    :client_driver,
    :key,
    :level,
    :ordered?,
    :part,
    :popover,
    :prevent_default,
    :reorder,
    :semantic,
    :state,
    :states,
    :stop_propagation,
    :when,
    :window
  ]

  def constructor_name?(name) when is_atom(name), do: MapSet.member?(@constructor_names, name)
  def constructor_name?(_name), do: false

  def constructor_names, do: MapSet.to_list(@constructor_names)
  def element_names, do: Map.keys(@element_tags)

  def text(content), do: lower(constructor_call(:text, [content]))
  def fragment(children), do: lower(constructor_call(:fragment, [children]))
  def nothing, do: lower(constructor_call(:nothing, []))

  def each(items, as, children) when is_atom(as), do: each(items, as, [], children)

  def each(items, as, opts, children),
    do: lower(constructor_call(:each, [items, as, opts, children]))

  def mark(name), do: lower(constructor_call(:mark, [name]))
  def mark(name, opts), do: lower(constructor_call(:mark, [name, opts]))
  def attr(name, value), do: lower(constructor_call(:attr, [name, value]))
  def island(name), do: lower(constructor_call(:island, [name, []]))
  def island(name, opts), do: lower(constructor_call(:island, [name, opts]))

  def render(resource, input), do: lower(constructor_call(:render, [resource, input]))
  def render(resource, input, opts), do: lower(constructor_call(:render, [resource, input, opts]))

  def el(tag), do: lower(constructor_call(:el, [tag]))
  def el(tag, children), do: lower(constructor_call(:el, [tag, children]))
  def el(tag, opts, children), do: lower(constructor_call(:el, [tag, opts, children]))
  def el(tag, part, opts, children), do: lower(constructor_call(:el, [tag, part, opts, children]))

  def key(name) when is_atom(name) or is_binary(name), do: key(name, [])

  def key(name, opts) when (is_atom(name) or is_binary(name)) and is_list(opts) do
    %{
      kind: :key_filter,
      key: name,
      modifiers: Keyword.get(opts, :modifiers, [])
    }
  end

  for name <- Map.keys(@element_tags) do
    def unquote(name)(), do: lower(constructor_call(unquote(name), []))
    def unquote(name)(arg1), do: lower(constructor_call(unquote(name), [arg1]))
    def unquote(name)(arg1, arg2), do: lower(constructor_call(unquote(name), [arg1, arg2]))

    def unquote(name)(arg1, arg2, arg3),
      do: lower(constructor_call(unquote(name), [arg1, arg2, arg3]))
  end

  def lower(%Compiled{} = compiled),
    do: compiled |> AshUi.ExprCompiler.compile!() |> lower_compiled()

  def lower(%Call{name: :text, args: [content]}),
    do: %{kind: :text, content: expr_or_static(content)}

  def lower(%Call{name: :fragment, args: [children]}) do
    %{kind: :fragment, children: lower_children(children)}
  end

  def lower(%Call{name: :nothing, args: []}), do: %{kind: :fragment, children: []}

  def lower(%Call{name: :if, args: [condition, branches]}) when is_list(branches) do
    %{
      kind: :if,
      condition: expr_or_static(condition),
      then: lower_child_container(Keyword.get(branches, :do, [])),
      else: lower_child_container(Keyword.get(branches, :else, []))
    }
  end

  def lower(%Call{name: :each, args: [_items, as, _opts, _body]} = call) when is_atom(as) do
    %Call{args: [items, ^as, opts, body]} =
      AshUi.ExprCompiler.normalize_each_bindings(call)

    opts = static_keyword(opts)
    index = Keyword.get(opts, :index, as)

    unless is_atom(index) do
      raise ArgumentError, "each/4 expects `index:` to be an atom, got: #{inspect(index)}"
    end

    %{
      kind: :each,
      items: expr_or_static(items),
      as: as,
      index: index,
      child: lower_child_container(body)
    }
    |> maybe_put(:key, Keyword.get(opts, :key) |> expr_or_nil())
  end

  def lower(%Call{name: :mark, args: [name]}) when is_atom(name) do
    %{kind: :part_state, name: name, when: true}
  end

  def lower(%Call{name: :mark, args: [name, opts]}) when is_atom(name) do
    opts = static_keyword(opts)
    %{kind: :part_state, name: name, when: opts |> Keyword.get(:when, true) |> expr_or_static()}
  end

  def lower(%Call{name: :attr, args: [name, value]}) when is_atom(name) or is_binary(name) do
    %{kind: :part_attr, name: name, value: expr_or_static(value)}
  end

  def lower(%Call{name: :island, args: [name]}) do
    lower(%Call{
      name: :island,
      args: [name, []],
      operator?: false,
      relationship_path: []
    })
  end

  def lower(%Call{name: :island, args: [name, opts]}) do
    name = island_name!(name)
    opts = island_opts!(opts)
    props = island_props!(Keyword.get(opts, :props, %{}))
    bindings = island_bindings!(name, Keyword.get(opts, :on, []))

    %{
      kind: :element,
      tag: :div,
      part: nil,
      attrs: %{
        "id" => "ash-ui-island-" <> EventBinding.key_component(name),
        "data-ash-ui-client-hook" => "AshUiIsland",
        "data-ash-ui-dom-update" => "ignore",
        "data-ash-ui-island" => to_string(name),
        "data-ash-ui-island-props" => expr_or_static(props)
      },
      events: bindings,
      states: [],
      children: [],
      key: name,
      meta: %{
        dom_owner: :client,
        island: %{name: to_string(name)}
      }
    }
  end

  def lower(%Call{name: :render, args: [resource, input]}) do
    lower(%Call{
      name: :render,
      args: [resource, input, []],
      operator?: false,
      relationship_path: []
    })
  end

  def lower(%Call{name: :render, args: [resource, input, opts]}) do
    opts = static_keyword(opts)

    if is_atom(resource) do
      resource_component_render(resource, input, opts)
    else
      %{
        kind: :computed,
        expr:
          compiled(%Call{
            name: :render,
            args: [resource, input, opts],
            operator?: false,
            relationship_path: []
          })
      }
    end
  end

  def lower(%Call{name: :el, args: args}) do
    {tag, part, opts, children} =
      case args do
        [tag, part, opts, children] -> {tag, part, opts, children}
        [tag, opts, children] when is_list(opts) -> {tag, nil, opts, children}
        [tag, part, children] -> {tag, part, [], children}
        [tag, children] -> {tag, nil, [], children}
        [tag] -> {tag, nil, [], []}
      end

    lower_element(static_tag(tag), part, opts, children)
  end

  def lower(%Call{name: name, args: args}) when is_map_key(@element_tags, name) do
    {part, opts, children} = node_args(name, args)
    {tag, attrs, opts} = name |> tag_attrs_opts(static_keyword(opts))

    node = lower_element(tag, Keyword.get(opts, :part, part), opts, children, attrs)

    if name == :link do
      update_in(node, [:meta], &Map.put(&1, :screen_navigation?, true))
    else
      node
    end
  end

  def lower(%{kind: :fragment, children: children} = node) do
    %{node | children: lower_children(children)}
  end

  def lower(%{kind: :element, children: children} = node) do
    %{node | children: lower_children(children)}
  end

  def lower(%{kind: :each, child: child} = node) do
    %{node | child: lower(child)}
  end

  def lower(%{kind: :when, child: child} = node) do
    %{node | child: lower(child)}
  end

  def lower(%{kind: :if, then: then_child} = node) do
    node
    |> Map.put(:then, lower(then_child))
    |> maybe_lower_child(:else)
  end

  def lower(%{kind: :empty, child: child} = node) do
    %{node | child: lower(child)}
  end

  def lower(%{kind: kind} = node)
      when kind in [
             :attached_view,
             :computed,
             :part_attr,
             :part_state,
             :resource_component,
             :text
           ],
      do: node

  def lower(%{kind: _kind} = node) do
    raise ArgumentError, "unsupported view node: #{inspect(node)}"
  end

  def lower(list) when is_list(list), do: %{kind: :fragment, children: lower_children(list)}
  def lower(other), do: %{kind: :computed, expr: expr_or_static(other)}

  defp lower_compiled(%Compiled{ir: ir}), do: lower(ir)

  defp constructor_call(name, args),
    do: %Call{name: name, args: args, operator?: false, relationship_path: []}

  defp maybe_lower_child(node, key) do
    case Map.fetch(node, key) do
      {:ok, nil} -> node
      {:ok, child} -> Map.put(node, key, lower(child))
      :error -> node
    end
  end

  def load_spec(%Compiled{} = compiled, view_exprs \\ %{}, resource \\ nil) do
    load_spec(compiled, view_exprs, resource, MapSet.new(List.wrap(resource)))
  end

  defp load_spec(%Compiled{} = compiled, view_exprs, resource, rendered_resources) do
    bindings = collect_binding_relationships(compiled.ir, %{}, resource)
    deps = transitive_deps(compiled, view_exprs)

    (deps ++
       calc_relationship_deps(deps, resource) ++
       rendered_store_relationship_deps(compiled.ir, resource, rendered_resources))
    |> deps_to_load_spec(bindings, resource)
  end

  # SYNTHESIS §2.1 — reactivity rides the same dep set as loading: a
  # view-referenced EXPRESSION calculation's relationship paths join the
  # load spec, so calc-mediated relationships materialize on the record
  # and the subscription walk (which only sees LOADED relationships)
  # registers them. Ash still expands the calc itself; this only widens
  # the load with the calc's own relationship refs (Ash.Filter.list_refs,
  # lane 3). Module-backed calcs stay opaque — their load/3 declares.
  defp calc_relationship_deps(deps, resource) when is_atom(resource) and not is_nil(resource) do
    deps
    |> Enum.flat_map(fn
      {:state, field} when is_atom(field) -> [field]
      {:state, [field]} when is_atom(field) -> [field]
      _other -> []
    end)
    |> Enum.uniq()
    |> Enum.flat_map(fn field ->
      if ash_resource_module?(resource) do
        case Ash.Resource.Info.calculation(resource, field) do
          %{calculation: {Ash.Resource.Calculation.Expression, opts}} = calculation ->
            expr_relationship_deps(Keyword.get(opts, :expr)) ++
              declared_load_relationship_deps(calculation, resource)

          %{} = calculation ->
            # Module/function-backed calcs declare their dependency set
            # statically via `load/3`'s DSL declaration — the same synthesis
            # applies: their declared relationships join the load spec so
            # they materialize on the record and the subscription walk
            # registers them (without this, a calc-mediated edge is
            # %Ash.NotLoaded{} on the rendered record and the view never
            # live-updates from that resource's writes).
            declared_load_relationship_deps(calculation, resource)

          _no_calc ->
            []
        end
      else
        []
      end
    end)
  end

  defp calc_relationship_deps(_deps, _resource), do: []

  defp expr_relationship_deps(nil), do: []

  defp expr_relationship_deps(expr) do
    expr
    |> Ash.Filter.list_refs()
    |> Enum.flat_map(fn
      %{relationship_path: [_ | _] = path, attribute: attribute} ->
        name =
          case attribute do
            %{name: name} -> name
            name when is_atom(name) -> name
          end

        [{:state, path ++ [name]}]

      _root_ref ->
        []
    end)
  end

  defp declared_load_relationship_deps(%{load: load}, resource) do
    load
    |> List.wrap()
    |> load_spec_paths()
    |> Enum.filter(fn
      [relationship | _nested] -> Ash.Resource.Info.relationship(resource, relationship)
      _other -> false
    end)
    |> Enum.map(&{:state, &1})
  end

  defp declared_load_relationship_deps(_calculation, _resource), do: []

  def binding_relationships(ir, resource \\ nil) do
    ir
    |> collect_binding_relationships(%{}, resource)
    |> Map.new(fn {as, [path | _]} -> {as, path} end)
  end

  defp lower_child_container(children) do
    children = lower_children(children)

    case children do
      [single] -> single
      many -> %{kind: :fragment, children: many}
    end
  end

  defp lower_children(children) when is_list(children) do
    children
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&lower/1)
  end

  defp lower_children(child), do: [lower(child)]

  defp node_args(name, args) do
    text_inline_args(name, args) || node_args(args)
  end

  defp text_inline_args(name, [part, content, opts, children])
       when name in [:inline, :small] and (is_atom(part) or is_binary(part)) and is_list(opts) do
    {part, opts, [text_call(content) | List.wrap(children)]}
  end

  defp text_inline_args(name, [content, opts, children])
       when name in [:inline, :small] and is_list(opts) do
    if is_atom(content) do
      nil
    else
      {nil, opts, [text_call(content) | List.wrap(children)]}
    end
  end

  defp text_inline_args(_name, _args), do: nil

  defp text_call(content),
    do: %Call{name: :text, args: [content], operator?: false, relationship_path: []}

  defp node_args([part, opts, children])
       when (is_atom(part) or is_binary(part)) and is_list(opts),
       do: {part, opts, children}

  defp node_args([part, opts]) when (is_atom(part) or is_binary(part)) and is_list(opts) do
    if Keyword.keyword?(opts), do: {part, opts, []}, else: {part, [], opts}
  end

  defp node_args([part, children]) when is_atom(part) or is_binary(part), do: {part, [], children}
  defp node_args([opts, children]) when is_list(opts), do: {nil, opts, children}

  defp node_args([opts]) when is_list(opts) do
    if Keyword.keyword?(opts), do: {nil, opts, []}, else: {nil, [], opts}
  end

  defp node_args([children]), do: {nil, [], children}
  defp node_args([]), do: {nil, [], []}

  defp lower_element(tag, part, opts, children, base_attrs \\ %{}) do
    opts = static_keyword(opts)
    lowered_children = lower_children(children)

    {inline_attrs, inline_states, lowered_children} =
      Enum.reduce(lowered_children, {%{}, [], []}, fn
        %{kind: :part_attr, name: name, value: value}, {attrs, states, nodes} ->
          {Map.put(attrs, name, value), states, nodes}

        %{kind: :part_state} = state, {attrs, states, nodes} ->
          {attrs, [state | states], nodes}

        child, {attrs, states, nodes} ->
          {attrs, states, [child | nodes]}
      end)
      |> then(fn {attrs, states, nodes} ->
        {attrs, Enum.reverse(states), Enum.reverse(nodes)}
      end)

    attrs =
      opts
      |> attrs_from_opts(base_attrs, tag, part)
      |> Map.merge(inline_attrs)

    %{
      kind: :element,
      tag: tag,
      part: part,
      attrs: attrs,
      events: events_from_opts(tag, opts, attrs),
      states: states_from_opts(opts) ++ inline_states,
      children: lowered_children,
      meta: meta_from_opts(Keyword.put(opts, :part, part))
    }
    |> maybe_put(:key, Keyword.get(opts, :key) |> expr_or_nil())
  end

  defp tag_attrs_opts(:heading, opts) do
    level = opts |> Keyword.get(:level, 1) |> normalize_heading_level()
    {String.to_atom("h#{level}"), %{}, Keyword.delete(opts, :level)}
  end

  defp tag_attrs_opts(:button, opts), do: {:button, %{}, opts}
  defp tag_attrs_opts(:checkbox, opts), do: {:input, %{"type" => "checkbox"}, opts}
  defp tag_attrs_opts(:hidden, opts), do: {:input, %{"type" => "hidden"}, opts}

  defp tag_attrs_opts(:list, opts) do
    tag = if Keyword.get(opts, :ordered?, false), do: :ol, else: :ul
    {tag, %{}, Keyword.delete(opts, :ordered?)}
  end

  defp tag_attrs_opts(:link, opts) do
    opts =
      case Keyword.fetch(opts, :to) do
        {:ok, to} -> Keyword.put_new(opts, :href, to)
        :error -> opts
      end

    {:a, %{}, Keyword.delete(opts, :to)}
  end

  defp tag_attrs_opts(:popover, opts) do
    attrs = if Keyword.get(opts, :popover, false), do: %{"popover" => true}, else: %{}
    {:div, attrs, Keyword.delete(opts, :popover)}
  end

  defp tag_attrs_opts(:radio, opts), do: {:input, %{"type" => "radio"}, opts}
  defp tag_attrs_opts(name, opts), do: {Map.fetch!(@element_tags, name), %{}, opts}

  defp normalize_heading_level(level) when level in 1..6, do: level
  defp normalize_heading_level(_level), do: 1

  defp attrs_from_opts(opts, base, tag, part) do
    reject_legacy_attrs!(opts, tag)

    part = part || Keyword.get(opts, :part)

    opts
    |> Keyword.drop(@reserved_opts ++ event_option_keys(opts))
    |> Enum.flat_map(&attr_entry/1)
    |> Map.new()
    |> Map.merge(base, fn _key, value, _base -> value end)
    |> merge_client_driver_attrs(part, Keyword.get(opts, :client_driver))
  end

  defp reject_legacy_attrs!(opts, tag) do
    if Keyword.has_key?(opts, :attrs) do
      raise ArgumentError,
            "`attrs:` on #{tag || "node"} is not supported; pass explicit attributes or use `data:`/`aria:`"
    end
  end

  defp attr_entry({:data, values}) when is_list(values) or is_map(values) do
    Enum.map(values, fn {key, value} -> {data_attr_name(key), expr_or_static(value)} end)
  end

  defp attr_entry({:aria, values}) when is_list(values) or is_map(values) do
    Enum.map(values, fn {key, value} -> {aria_attr_name(key), expr_or_static(value)} end)
  end

  defp attr_entry({:emit_attrs, values}) when is_list(values) or is_map(values) do
    Enum.map(values, fn {key, value} -> {to_string(key), expr_or_static(value)} end)
  end

  defp attr_entry({key, value}) when is_atom(key), do: [{attr_name(key), expr_or_static(value)}]
  defp attr_entry({key, value}), do: [{to_string(key), expr_or_static(value)}]

  defp data_attr_name(key), do: "data-" <> dasherize(key)
  defp aria_attr_name(key), do: "aria-" <> dasherize(key)
  defp attr_name(:dom_id), do: "id"
  defp attr_name(:aria_label), do: "aria-label"
  defp attr_name(:debounce), do: "data-ash-ui-debounce"
  defp attr_name(:throttle), do: "data-ash-ui-throttle"
  defp attr_name(key), do: key |> Atom.to_string() |> String.replace("_", "-")
  defp dasherize(key), do: key |> to_string() |> String.replace("_", "-")

  defp compile_map_values(values) when is_map(values) do
    Map.new(values, fn {key, value} ->
      {key, if(fragment_input?(value), do: lower(value), else: expr_or_static(value))}
    end)
  end

  defp compile_map_values(values) when is_list(values),
    do: values |> Map.new() |> compile_map_values()

  defp compile_map_values(_values), do: %{}

  defp resource_component_render(resource, assigns, _opts) do
    node = %{
      kind: :resource_component,
      resource: resource,
      assigns: if(is_map(assigns), do: compile_map_values(assigns), else: %{}),
      client: [],
      runtimes: []
    }

    if is_map(assigns), do: node, else: Map.put(node, :record, expr_or_static(assigns))
  end

  defp fragment_input?(%Call{name: name}), do: constructor_name?(name)

  defp fragment_input?(values) when is_list(values) and values != [] do
    Enum.all?(values, &(is_nil(&1) or fragment_input?(&1)))
  end

  defp fragment_input?(_value), do: false

  defp static_tag(%Compiled{ir: tag}), do: static_tag(tag)
  defp static_tag(tag) when is_atom(tag) or is_binary(tag), do: tag
  defp static_tag(tag), do: tag

  defp island_name!(%Compiled{ir: name}), do: island_name!(name)

  defp island_name!(name) when (is_atom(name) or is_binary(name)) and name not in [nil, ""] do
    name
  end

  defp island_name!(name) do
    raise ArgumentError,
          "island/2 expects a non-empty static atom or string name, got: #{inspect(name)}"
  end

  defp island_opts!(opts) when is_map(opts), do: opts |> Map.to_list() |> island_opts!()

  defp island_opts!(opts) when is_list(opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError,
            "island/2 expects a keyword list of options, got: #{inspect(opts)}"
    end

    unknown = opts |> Keyword.keys() |> Enum.uniq() |> Kernel.--([:props, :on])

    if unknown != [] do
      raise ArgumentError,
            "island/2 received unknown options #{inspect(unknown)}; expected only :props and :on"
    end

    opts
  end

  defp island_opts!(opts) do
    raise ArgumentError,
          "island/2 expects a keyword list of options, got: #{inspect(opts)}"
  end

  defp island_props!(props) when is_map(props), do: props

  defp island_props!(props) do
    raise ArgumentError, "island/2 expects props: to be an expression map, got: #{inspect(props)}"
  end

  defp island_bindings!(name, bindings) when is_map(bindings),
    do: island_bindings!(name, Map.to_list(bindings))

  defp island_bindings!(name, bindings) when is_list(bindings) do
    unless Keyword.keyword?(bindings) do
      raise ArgumentError,
            "island/2 expects on: to be a keyword list of island event names to action atoms, got: #{inspect(bindings)}"
    end

    duplicates =
      bindings
      |> Keyword.keys()
      |> Enum.frequencies()
      |> Enum.filter(fn {_event, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))

    if duplicates != [] do
      raise ArgumentError,
            "island/2 received duplicate on: event names #{inspect(duplicates)}"
    end

    Enum.map(bindings, fn
      {event, action} when is_atom(event) and is_atom(action) ->
        EventBinding.new("island-" <> Atom.to_string(event), action,
          meta: %{
            island_event: Atom.to_string(event),
            island_name: to_string(name),
            provides_action_payload?: true
          }
        )

      {event, action} ->
        raise ArgumentError,
              "island/2 on: entries must map atom event names to action atoms, got: #{inspect({event, action})}"
    end)
  end

  defp island_bindings!(_name, bindings) do
    raise ArgumentError,
          "island/2 expects on: to be a keyword list of island event names to action atoms, got: #{inspect(bindings)}"
  end

  defp events_from_opts(tag, opts, attrs) do
    opts
    |> Enum.flat_map(fn
      {key, action} when is_atom(key) and is_atom(action) ->
        if event_option_key?(key), do: [event_binding(tag, key, action, opts, attrs)], else: []

      {key, {_item, _action} = targeted} when is_atom(key) ->
        if event_option_key?(key) do
          raise ArgumentError,
                "#{key}: item-tuple event bindings are not supported; use a bare action atom with typed action_input targeting a page action, got: #{inspect(targeted)}"
        else
          []
        end

      {key, action} when is_atom(key) ->
        if event_option_key?(key) do
          raise ArgumentError,
                "#{key}: expects a bare Ash action atom, got: #{inspect(action)}"
        else
          []
        end

      _other ->
        []
    end)
  end

  defp event_binding(tag, key, action, opts, attrs) do
    dom_event =
      key |> Atom.to_string() |> String.replace_prefix(@event_prefix, "") |> String.to_atom()

    action_input = opts |> Keyword.get(:action_input, %{}) |> Map.new()

    meta =
      %{}
      |> maybe_put(:auto_bind, tag in [:form, "form"] and action_input in [%{}, []])
      |> maybe_put(:key_filter, event_key_filter(dom_event, Keyword.get(opts, :when)))
      |> maybe_put(:provides_form?, tag in [:form, "form"] and dom_event in [:change, :submit])
      |> maybe_put_value_source(tag, attrs, dom_event)
      |> Map.merge(binding_option_meta(opts))

    EventBinding.new(dom_event, action,
      args_exprs: action_input |> Map.new() |> compile_action_input(),
      meta: meta
    )
  end

  defp maybe_put_value_source(meta, tag, attrs, dom_event) do
    case EventBinding.value_source_for(tag, attrs, dom_event) do
      nil ->
        meta

      source ->
        meta
        |> Map.put(:provides_value?, true)
        |> Map.put(:value_source, source)
        |> maybe_put_bound_field(attrs)
    end
  end

  defp maybe_put_bound_field(meta, attrs) do
    case Map.get(attrs, "name") || Map.get(attrs, :name) do
      field when is_atom(field) ->
        Map.put(meta, :bound_field, field)

      field when is_binary(field) ->
        try do
          Map.put(meta, :bound_field, String.to_existing_atom(field))
        rescue
          ArgumentError -> meta
        end

      _dynamic_or_missing ->
        meta
    end
  end

  defp binding_option_meta(opts) do
    %{}
    |> maybe_put_binding_bool(opts, :prevent_default)
    |> maybe_put_binding_bool(opts, :stop_propagation)
  end

  defp maybe_put_binding_bool(meta, opts, key) do
    if Keyword.has_key?(opts, key) do
      case Keyword.fetch!(opts, key) do
        value when is_boolean(value) -> Map.put(meta, key, value)
        other -> raise ArgumentError, "#{key}: expects a boolean, got: #{inspect(other)}"
      end
    else
      meta
    end
  end

  defp event_option_keys(opts) do
    opts |> Keyword.keys() |> Enum.filter(&event_option_key?/1)
  end

  defp event_option_key?(key) when is_atom(key),
    do: key |> Atom.to_string() |> String.starts_with?(@event_prefix)

  defp event_option_key?(_key), do: false

  defp states_from_opts(opts) do
    opts
    |> Keyword.get(:state, Keyword.get(opts, :states, []))
    |> List.wrap()
    |> Enum.flat_map(fn
      {name, condition} when is_atom(name) ->
        [%{kind: :part_state, name: name, when: expr_or_static(condition)}]

      name when is_atom(name) ->
        [%{kind: :part_state, name: name, when: true}]

      _other ->
        []
    end)
  end

  defp meta_from_opts(opts) do
    part = Keyword.get(opts, :part)

    %{}
    |> maybe_put(:component_part, part)
    |> maybe_put(:part, part)
    |> maybe_put(:reorder, reorder_with_target(Keyword.get(opts, :reorder), part))
    |> merge_client_driver_meta(part, Keyword.get(opts, :client_driver))
  end

  defp reorder_with_target(nil, _part), do: nil
  defp reorder_with_target(false, _part), do: nil

  defp reorder_with_target(reorder, part) when is_map(reorder) do
    if is_nil(part) or Map.has_key?(reorder, :target),
      do: reorder,
      else: Map.put(reorder, :target, part)
  end

  defp reorder_with_target(reorder, part) when is_list(reorder) do
    if is_nil(part) or Keyword.has_key?(reorder, :target),
      do: reorder,
      else: Keyword.put(reorder, :target, part)
  end

  defp reorder_with_target(reorder, _part), do: reorder

  defp merge_client_driver_attrs(attrs, _part, nil), do: attrs
  defp merge_client_driver_attrs(attrs, _part, false), do: attrs

  defp merge_client_driver_attrs(attrs, part, drivers) do
    normalized = normalize_client_drivers!(drivers)
    validate_client_driver_attrs!(attrs, normalized)
    driver_names = Enum.map(normalized, &driver_name/1)
    client_actions = client_driver_client_actions(normalized, part)

    attrs =
      case driver_names do
        [] ->
          attrs

        names ->
          attrs
          |> Map.put(
            "data-ash-ui-client-driver",
            Enum.join(Enum.map(names, &to_string/1), " ")
          )
          |> Map.put_new("data-ash-ui-client-hook", "AshUiClient")
      end

    attrs =
      case client_actions do
        [] ->
          attrs

        actions ->
          attrs
          |> Map.put(
            "data-ash-ui-client-actions",
            Jason.encode!(Enum.map(actions, &EventBinding.serialize_client_action/1))
          )
          |> Map.put_new("data-ash-ui-client-hook", "AshUiClient")
      end

    Enum.reduce(normalized, attrs, fn driver, acc ->
      namespace = driver_namespace(driver)

      driver
      |> Keyword.get(:data, [])
      |> Map.new()
      |> Enum.reduce(acc, fn {key, value}, next ->
        maybe_put(next, "data-#{attr_suffix(namespace)}-#{attr_suffix(key)}", value)
      end)
    end)
  end

  defp merge_client_driver_meta(meta, _part, nil), do: meta
  defp merge_client_driver_meta(meta, _part, false), do: meta

  defp merge_client_driver_meta(meta, part, drivers) do
    normalized = normalize_client_drivers!(drivers)
    client_actions = client_driver_client_actions(normalized, part)

    meta
    |> Map.update(:client_drivers, Enum.map(normalized, &driver_name/1), fn existing ->
      Enum.uniq(List.wrap(existing) ++ Enum.map(normalized, &driver_name/1))
    end)
    |> Map.update(:client_driver_contracts, normalized, &(List.wrap(&1) ++ normalized))
    |> Map.update(:client_actions, client_actions, &(List.wrap(&1) ++ client_actions))
  end

  defp normalize_client_drivers!(driver) when is_atom(driver) or is_binary(driver),
    do: [[name: driver]]

  defp normalize_client_drivers!(drivers) when is_list(drivers) do
    cond do
      Keyword.keyword?(drivers) and Keyword.has_key?(drivers, :name) ->
        [drivers]

      true ->
        Enum.map(drivers, fn
          driver when is_atom(driver) or is_binary(driver) ->
            [name: driver]

          driver when is_list(driver) ->
            driver

          %{} = driver ->
            Map.to_list(driver)

          other ->
            raise ArgumentError,
                  "client_driver expects an atom, keyword list, map, or list of those, got: #{inspect(other)}"
        end)
    end
  end

  defp normalize_client_drivers!(%{} = driver), do: [Map.to_list(driver)]

  defp normalize_client_drivers!(other) do
    raise ArgumentError,
          "client_driver expects an atom, keyword list, map, or list of those, got: #{inspect(other)}"
  end

  defp driver_name(driver) do
    Keyword.fetch!(driver, :name)
  rescue
    KeyError -> raise ArgumentError, "client_driver requires `name:`"
  end

  defp driver_namespace(driver), do: Keyword.get(driver, :namespace, driver_name(driver))

  defp validate_client_driver_attrs!(attrs, drivers) do
    Enum.each(drivers, fn driver ->
      if island_owned_fields(driver) != [] and not stable_dom_id?(attrs) do
        raise ArgumentError,
              "client_driver #{inspect(driver_name(driver))} owns fields and requires a stable `dom_id:` on the constructor"
      end
    end)
  end

  defp island_owned_fields(driver) do
    owns = Keyword.get(driver, :owns, Keyword.get(driver, :owned_fields, []))

    cond do
      is_list(owns) -> owns
      is_map(owns) -> Map.get(owns, :fields, Map.get(owns, "fields", []))
      true -> []
    end
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
  end

  defp stable_dom_id?(attrs) when is_map(attrs) do
    case Map.get(attrs, "id", Map.get(attrs, :id)) do
      value when value in [nil, ""] -> false
      _value -> true
    end
  end

  defp client_driver_client_actions(normalized, part) do
    Enum.flat_map(normalized, fn driver ->
      target = Keyword.get(driver, :target, part)

      driver
      |> Keyword.get(:emits, Keyword.get(driver, :actions, []))
      |> List.wrap()
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn action ->
        if is_nil(target) do
          raise ArgumentError,
                "client_driver #{inspect(driver_name(driver))} emits #{inspect(action)} but the node has no part; pass `target:` or name the node"
        end

        EventBinding.client_action(action,
          target: target,
          using: driver_name(driver),
          dom_event: Keyword.get(driver, :dom_event)
        )
      end)
    end)
  end

  defp attr_suffix(value), do: value |> to_string() |> String.replace("_", "-")

  defp key_filter(%Call{name: :key, args: [key]}), do: %{key: static_value(key), modifiers: []}

  defp key_filter(%Call{name: :key, args: [key, opts]}),
    do: %{key: static_value(key), modifiers: Keyword.get(static_keyword(opts), :modifiers, [])}

  defp key_filter(%{kind: :key_filter, key: key, modifiers: modifiers}),
    do: %{key: key, modifiers: modifiers}

  defp key_filter(_other), do: nil

  defp event_key_filter(dom_event, condition) when dom_event in [:keydown, :keyup],
    do: key_filter(condition)

  defp event_key_filter(_dom_event, _condition), do: nil

  defp expr_or_nil(nil), do: nil
  defp expr_or_nil(value), do: expr_or_static(value)

  defp expr_or_static(value) do
    if static_literal?(value), do: value, else: compiled(value)
  end

  defp compiled(%Compiled{} = compiled), do: compiled
  defp compiled(value), do: AshUi.ExprCompiler.compile!(value)

  defp static_literal?(value)
       when is_atom(value) or is_binary(value) or is_number(value) or is_boolean(value) or
              is_nil(value),
       do: true

  defp static_literal?(value) when is_list(value),
    do: Keyword.keyword?(value) == false and Enum.all?(value, &static_literal?/1)

  defp static_literal?(value) when is_map(value) and not is_struct(value) do
    Enum.all?(value, fn {key, item} -> static_literal?(key) and static_literal?(item) end)
  end

  defp static_literal?(_value), do: false

  defp static_keyword(value) when is_list(value), do: value
  defp static_keyword(value) when is_map(value), do: Map.to_list(value)
  defp static_keyword(_value), do: []

  defp static_value(%Call{name: :event, args: [field]}), do: {:event, static_value(field)}
  defp static_value(%Call{name: :key, args: [key]}), do: static_value(key)
  defp static_value(value), do: value

  defp compile_action_input(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, item} -> {key, compile_action_input(item)} end)
  end

  defp compile_action_input(%Compiled{ir: %Call{name: :event, args: [field]}}),
    do: {:event, static_value(field)}

  defp compile_action_input(%Call{name: :event, args: [field]}), do: {:event, static_value(field)}
  defp compile_action_input(value), do: expr_or_static(value)

  defp collect_binding_relationships(
         %Call{name: :each, args: [items, as, _opts, body]},
         acc,
         resource
       )
       when is_atom(as) do
    acc = put_each_binding(acc, as, items, resource)

    collect_binding_relationships(body, acc, resource)
  end

  defp collect_binding_relationships(
         %{kind: :each, items: items, as: as} = each,
         acc,
         resource
       )
       when is_atom(as) do
    acc = put_each_binding(acc, as, items, resource)

    each
    |> Map.delete(:items)
    |> collect_binding_relationships(acc, resource)
  end

  defp collect_binding_relationships(%Call{args: args}, acc, resource),
    do: Enum.reduce(args, acc, &collect_binding_relationships(&1, &2, resource))

  defp collect_binding_relationships(%Compiled{ir: ir}, acc, resource),
    do: collect_binding_relationships(ir, acc, resource)

  defp collect_binding_relationships(list, acc, resource) when is_list(list),
    do: Enum.reduce(list, acc, &collect_binding_relationships(&1, &2, resource))

  defp collect_binding_relationships(map, acc, resource)
       when is_map(map) and not is_struct(map) do
    Enum.reduce(map, acc, fn {key, value}, next ->
      value
      |> collect_binding_relationships(
        collect_binding_relationships(key, next, resource),
        resource
      )
    end)
  end

  defp collect_binding_relationships(%_{} = struct, acc, resource) do
    struct |> Map.from_struct() |> collect_binding_relationships(acc, resource)
  end

  defp collect_binding_relationships(tuple, acc, resource) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> collect_binding_relationships(acc, resource)
  end

  defp collect_binding_relationships(_other, acc, _resource), do: acc

  defp put_each_binding(acc, as, items, resource) do
    case items do
      {:_ref, path, field} when is_list(path) and is_atom(field) ->
        maybe_put_binding_relationship(acc, as, resource, path ++ [field])

      %Compiled{ir: {:_ref, path, field}} when is_list(path) and is_atom(field) ->
        maybe_put_binding_relationship(acc, as, resource, path ++ [field])

      {:_item, parent_binding, path} when is_atom(parent_binding) ->
        maybe_put_nested_binding_relationship(acc, as, parent_binding, path)

      %Compiled{ir: {:_item, parent_binding, path}} when is_atom(parent_binding) ->
        maybe_put_nested_binding_relationship(acc, as, parent_binding, path)

      _other ->
        acc
    end
  end

  defp maybe_put_binding_relationship(acc, as, resource, [relationship | _rest] = path) do
    if relationship_field?(resource, relationship) do
      # one binder name may stand for the items of several lists of a view (`each :open_jobs, :job`,
      # `each :booked_jobs, :job`): every path is kept, not only the first
      Map.update(acc, as, [path], fn paths -> if path in paths, do: paths, else: paths ++ [path] end)
    else
      acc
    end
  end

  defp maybe_put_nested_binding_relationship(acc, as, parent_binding, path) do
    # the parent binder may stand for several lists: the nested list is nested under each of them
    acc
    |> Map.get(parent_binding, [])
    |> Enum.reduce(acc, fn
      [_relationship | _rest] = parent_path, acc ->
        nested = parent_path ++ List.wrap(path)
        Map.update(acc, as, [nested], fn paths -> if nested in paths, do: paths, else: paths ++ [nested] end)

      _other, acc ->
        acc
    end)
  end

  defp transitive_deps(%Compiled{} = compiled, view_exprs) do
    compiled.deps ++
      Enum.flat_map(compiled.deps, fn
        {:state, [[], name]} when is_map_key(view_exprs, name) ->
          transitive_deps(Map.fetch!(view_exprs, name), view_exprs)

        {:state, name} when is_map_key(view_exprs, name) ->
          transitive_deps(Map.fetch!(view_exprs, name), view_exprs)

        _other ->
          []
      end)
  end

  @doc false
  def rendered_store_relationship_deps(_ir, nil), do: []

  def rendered_store_relationship_deps(ir, resource) when is_atom(resource) do
    rendered_store_relationship_deps(ir, resource, MapSet.new([resource]))
  end

  defp rendered_store_relationship_deps(_ir, nil, _seen), do: []

  defp rendered_store_relationship_deps(ir, resource, seen) when is_atom(resource) do
    rendered_resources = collect_store_render_resources(ir, MapSet.new(), MapSet.new())

    resource
    |> Ash.Resource.Info.relationships()
    |> Enum.filter(&MapSet.member?(rendered_resources, &1.destination))
    |> Enum.flat_map(fn relationship ->
      nested_loads =
        if MapSet.member?(seen, relationship.destination) do
          []
        else
          case AshUi.Compiled.view_exprs(relationship.destination) do
            %{view: %Compiled{} = view} = view_exprs ->
              load_spec(
                view,
                view_exprs,
                relationship.destination,
                MapSet.put(seen, relationship.destination)
              )

            _no_view ->
              []
          end
        end

      [{:state, [[], relationship.name]}] ++
        Enum.map(load_spec_paths(nested_loads), fn path ->
          {:state, [[], relationship.name | path]}
        end)
    end)
  end

  defp load_spec_paths(loads) when is_list(loads),
    do: Enum.flat_map(loads, &load_spec_paths/1)

  defp load_spec_paths(field) when is_atom(field), do: [[field]]

  defp load_spec_paths({field, nested}) when is_atom(field) do
    [[field] | Enum.map(load_spec_paths(nested), &[field | &1])]
  end

  defp load_spec_paths(_other), do: []

  defp collect_store_render_resources(
         %Call{name: :render, args: [child | args]},
         resources,
         seen
       )
       when is_atom(child) do
    resources = collect_store_render_resources(args, resources, seen)

    collect_store_render_resource(child, resources, seen)
  end

  defp collect_store_render_resources(
         %{kind: :resource_component, resource: child} = node,
         resources,
         seen
       )
       when is_atom(child) do
    resources =
      node
      |> Map.delete(:resource)
      |> collect_store_render_resources(resources, seen)

    collect_store_render_resource(child, resources, seen)
  end

  defp collect_store_render_resources(%Call{args: args}, resources, seen),
    do: collect_store_render_resources(args, resources, seen)

  defp collect_store_render_resources(%Compiled{ir: ir}, resources, seen),
    do: collect_store_render_resources(ir, resources, seen)

  defp collect_store_render_resources(list, resources, seen) when is_list(list),
    do: Enum.reduce(list, resources, &collect_store_render_resources(&1, &2, seen))

  defp collect_store_render_resources(map, resources, seen)
       when is_map(map) and not is_struct(map) do
    Enum.reduce(map, resources, fn {key, value}, resources ->
      resources = collect_store_render_resources(key, resources, seen)
      collect_store_render_resources(value, resources, seen)
    end)
  end

  defp collect_store_render_resources(%_{} = struct, resources, seen) do
    struct
    |> Map.from_struct()
    |> collect_store_render_resources(resources, seen)
  end

  defp collect_store_render_resources(tuple, resources, seen) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> collect_store_render_resources(resources, seen)
  end

  defp collect_store_render_resources(_other, resources, _seen), do: resources

  defp collect_store_render_resource(child, resources, seen) do
    cond do
      not ash_resource_module?(child) ->
        resources

      Ash.Resource.Info.embedded?(child) and not MapSet.member?(seen, child) ->
        case AshUi.Compiled.view_exprs(child) do
          %{view: %Compiled{ir: child_ir}} ->
            collect_store_render_resources(child_ir, resources, MapSet.put(seen, child))

          _other ->
            resources
        end

      Ash.Resource.Info.embedded?(child) ->
        resources

      true ->
        MapSet.put(resources, child)
    end
  end

  defp deps_to_load_spec(deps, bindings, resource) do
    deps
    |> Enum.reduce(%{fields: MapSet.new(), relationships: %{}}, fn
      {:state, [[], field | path]}, acc when is_atom(field) ->
        cond do
          relationship_field?(resource, field) -> put_relationship_path(acc, field, path)
          path == [] -> put_field_load(acc, resource, field)
          true -> acc
        end

      {:state, field}, acc when is_atom(field) ->
        put_field_load(acc, resource, field)

      # path-faithful refs arrive as single-element lists: a bare calc or
      # aggregate ref is a FIELD load, not a discarded relationship miss
      {:state, [field]}, acc when is_atom(field) ->
        if relationship_field?(resource, field) do
          put_relationship_path(acc, field, [])
        else
          put_field_load(acc, resource, field)
        end

      {:state, [relationship | path]}, acc when is_atom(relationship) ->
        if relationship_field?(resource, relationship) do
          put_relationship_path(acc, relationship, path)
        else
          acc
        end

      {:item, [binding, field]}, acc ->
        put_binding_paths_field_load(acc, Map.get(bindings, binding), field)

      {:item, binding, field}, acc ->
        put_binding_paths_field_load(acc, Map.get(bindings, binding), field)

      _other, acc ->
        acc
    end)
    |> load_acc_to_spec(resource)
  end

  defp put_binding_paths_field_load(acc, paths, field) when is_list(paths) do
    Enum.reduce(paths, acc, &put_binding_field_load(&2, &1, field))
  end

  defp put_binding_paths_field_load(acc, _paths, _field), do: acc

  defp put_binding_field_load(acc, [relationship | path], field) do
    put_relationship_path(acc, relationship, path ++ List.wrap(field))
  end

  defp put_binding_field_load(acc, _binding_path, _field), do: acc

  defp put_field_load(acc, resource, field) do
    if loadable_field?(resource, field) do
      update_in(acc.fields, &MapSet.put(&1, field))
    else
      acc
    end
  end

  defp put_relationship_path(acc, relationship, path) do
    update_in(acc.relationships, fn relationships ->
      Map.update(
        relationships,
        relationship,
        nested_load(path),
        &merge_nested_load(&1, nested_load(path))
      )
    end)
  end

  defp relationship_field?(nil, _field), do: true

  defp relationship_field?(resource, field) when is_atom(resource) and is_atom(field) do
    ash_resource_module?(resource) and not is_nil(Ash.Resource.Info.relationship(resource, field))
  end

  defp relationship_field?(_resource, _field), do: false

  defp loadable_field?(nil, _field), do: true

  defp loadable_field?(resource, field) when is_atom(resource) and is_atom(field) do
    ash_resource_module?(resource) and
      (not is_nil(Ash.Resource.Info.relationship(resource, field)) or
         not is_nil(Ash.Resource.Info.calculation(resource, field)) or
         not is_nil(Ash.Resource.Info.aggregate(resource, field)))
  end

  defp loadable_field?(_resource, _field), do: false

  defp ash_resource_module?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and Ash.Resource.Info.resource?(module)
  end

  defp nested_load([]), do: %{}
  defp nested_load([field]), do: %{field => %{}}
  defp nested_load([field | rest]), do: %{field => nested_load(rest)}

  defp merge_nested_load(left, right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      merge_nested_load(left_value, right_value)
    end)
  end

  defp load_acc_to_spec(%{fields: fields, relationships: relationships}, resource) do
    field_spec = fields |> MapSet.to_list() |> Enum.sort()

    relationship_spec =
      relationships
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {relationship, nested} ->
        nested = manual_relationship_nested_load(resource, relationship, nested)

        if nested == %{} do
          relationship
        else
          {relationship, nested_load_to_spec(nested, load_destination(resource, relationship))}
        end
      end)

    field_spec ++ relationship_spec
  end

  # A manual relationship owns the records it returns, including projected
  # attribute values. Loading those attributes again by identity replaces the
  # projection with storage-backed defaults. Nested derived fields still load.
  defp manual_relationship_nested_load(resource, relationship, nested)
       when is_atom(resource) and is_atom(relationship) and is_map(nested) do
    with true <- ash_resource_module?(resource),
         %{manual: manual, destination: destination} when not is_nil(manual) <-
           Ash.Resource.Info.relationship(resource, relationship),
         true <- ash_resource_module?(destination) do
      Map.reject(nested, fn {field, _nested} ->
        not is_nil(Ash.Resource.Info.attribute(destination, field))
      end)
    else
      _not_manual_relationship -> nested
    end
  end

  defp manual_relationship_nested_load(_resource, _relationship, nested), do: nested

  defp nested_load_to_spec(map, _resource) when map == %{}, do: []

  # Nesting is valid ONLY under relationships. A path segment that lands on
  # a calculation, aggregate, or (embedded) attribute loads BARE — its
  # value carries the subfields; `Ash.load` rejects nesting under them.
  defp nested_load_to_spec(map, resource) do
    map
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn
      {field, nested} when nested == %{} ->
        field

      {field, nested} ->
        case load_destination(resource, field) do
          nil -> field
          destination -> {field, nested_load_to_spec(nested, destination)}
        end
    end)
  end

  # The relationship's destination resource, or nil when the field is not a
  # relationship (or the resource is unknown — in which case nesting is
  # preserved for backwards-safe behavior via :unknown).
  defp load_destination(nil, _field), do: :unknown_resource

  defp load_destination(:unknown_resource, _field), do: :unknown_resource

  defp load_destination(resource, field) when is_atom(resource) do
    if ash_resource_module?(resource) do
      case Ash.Resource.Info.relationship(resource, field) do
        %{destination: destination} -> destination
        nil -> nil
      end
    else
      :unknown_resource
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, false), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
