defmodule AshUi.UpstreamBugs.ViewLoadBinderReuseTest do
  @moduledoc """
  One binder name reused by several lists of a view (`each :open_jobs, :job`, `each :booked_jobs, :job`;
  bobstack's views do this) must load the nested fields of every list. `binding_relationships/2` used
  `Map.put_new/3`, so only the FIRST list kept its binder: the items of every later list rendered
  without their nested calculations and aggregates.
  """
  use ExUnit.Case, async: true

  import AshUi.ViewConstructor

  alias AshUi.ExprCompiler
  alias AshUi.ViewConstructor

  test "a binder reused by two lists loads the nested fields under both" do
    compiled =
      ExprCompiler.compile!(
        [
          each({:_ref, [:board], :open_jobs}, :job, [], [text({:_item, :job, [:title]})]),
          each({:_ref, [:board], :booked_jobs}, :job, [], [text({:_item, :job, [:technician_name]})])
        ]
      )

    wrapped = %{compiled | ir: [do: compiled.ir]}

    assert ViewConstructor.load_spec(wrapped) == [
             board: [
               booked_jobs: [:technician_name, :title],
               open_jobs: [:technician_name, :title]
             ]
           ]
  end

  test "the public binder map still names the first list of a binder" do
    compiled =
      ExprCompiler.compile!(
        [
          each({:_ref, [:board], :open_jobs}, :job, [], [text({:_item, :job, [:title]})]),
          each({:_ref, [:board], :booked_jobs}, :job, [], [text({:_item, :job, [:title]})])
        ]
      )

    assert ViewConstructor.binding_relationships(compiled.ir) == %{job: [:board, :open_jobs]}
  end
end
