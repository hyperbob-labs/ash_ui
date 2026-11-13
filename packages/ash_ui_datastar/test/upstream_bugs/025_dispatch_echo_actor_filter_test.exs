defmodule AshUi.Datastar.UpstreamBugs.DispatchEchoActorFilterTest do
  @moduledoc """
  A count over a `no_attributes?` has_many filtered on the actor (a viewer's
  own notices: `owner == ^actor(:id)`), shown outside the button a dispatch is
  bound in. A page action that adds a notice of the actor's writes the
  relationship's destination, so the dispatch echo must read `mine` again and
  the count must render the new value, through the real datastar POST cycle.
  The echo's subscription carries the relationship's filter; with its
  `^actor(:id)` left a template, `Ash.Filter.Runtime` resolves it to
  `:unknown`, the notification never matches, and the count stays as it was.
  """

  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias AshUi.Datastar.{Bridge, Store}

  defmodule Notices do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(AshUi.Datastar.UpstreamBugs.DispatchEchoActorFilterTest.Notice)
    end
  end

  defmodule Notice do
    use Ash.Resource,
      domain: AshUi.Datastar.UpstreamBugs.DispatchEchoActorFilterTest.Notices,
      data_layer: Ash.DataLayer.Ets,
      notifiers: [AshUi.Notifier]

    ets do
      private?(false)
    end

    attributes do
      attribute(:id, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:owner, :string, allow_nil?: false, public?: true)
      attribute(:body, :string, allow_nil?: false, public?: true)
    end

    actions do
      defaults([:read])

      create :create do
        primary?(true)
        accept([:id, :owner, :body])
      end
    end
  end

  defmodule Page do
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    ets do
      private?(false)
    end

    ash_ui do
      stylesheets(["test/support/assets/datastar_test.css"])
    end

    routes do
      route("/echo-actor")
    end

    attributes do
      attribute(:session_id, :string, primary_key?: true, allow_nil?: false, public?: false)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    relationships do
      has_many :mine, AshUi.Datastar.UpstreamBugs.DispatchEchoActorFilterTest.Notice do
        no_attributes?(true)
        filter(expr(owner == ^actor(:id)))
      end
    end

    actions do
      defaults([:read])

      create :mount do
      end

      update :add_mine do
        require_atomic?(false)

        change(fn changeset, context ->
          Ash.Changeset.after_action(changeset, fn _changeset, record ->
            opts = Ash.Scope.to_opts(context)

            AshUi.Datastar.UpstreamBugs.DispatchEchoActorFilterTest.Notice
            |> Ash.Changeset.for_create(
              :create,
              %{id: "mine-2", owner: context.actor.id, body: "second"},
              opts
            )
            |> Ash.create!(opts)

            {:ok, record}
          end)
        end)
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          section(:root, [], [
            inline(:counted, [], [text(to_string(count(mine)))]),
            button(:send, [type: :button, on_click: :add_mine], [text("Add mine")])
          ])
        )
      )
    end
  end

  setup do
    Ash.DataLayer.Ets.stop(Page)
    Ash.DataLayer.Ets.stop(Notice)
    AshUi.Notification.MatchIndex.reset()
    :ok
  end

  defp opts, do: Bridge.init(resources: [Page], actor: %{id: "viewer-1"})

  defp cookie(conn),
    do: conn |> get_resp_header("set-cookie") |> List.first() |> String.split(";") |> hd()

  defp cookie_value(cookie), do: cookie |> String.split("=", parts: 2) |> List.last()

  defp binding_key(html, element_regex, event) do
    [element | _] = Regex.run(element_regex, html)

    [_, encoded_key] =
      Regex.run(
        ~r/data-on:#{Regex.escape(event)}="[^"]*?\/_ash_ui\/dispatch\/([^&'"),\s]+)/,
        element
      )

    URI.decode(encoded_key)
  end

  defp dispatch!(key, cookie) do
    conn =
      conn(
        :post,
        "/_ash_ui/dispatch/" <> URI.encode(key),
        Jason.encode!(%{"datastar" => %{}})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("cookie", cookie)
      |> Bridge.call(opts())

    assert conn.status == 200, conn.resp_body
    conn
  end

  test "a notice the actor adds renders the count of the actor's notices" do
    for {id, owner} <- [{"mine-1", "viewer-1"}, {"theirs-1", "someone-else"}] do
      Notice
      |> Ash.Changeset.for_create(:create, %{id: id, owner: owner, body: "first"})
      |> Ash.create!()
    end

    mount = conn(:get, "/echo-actor") |> Bridge.call(opts())
    session_id = mount |> cookie() |> cookie_value()
    assert length(Store.get(session_id).record.mine) == 1
    assert mount.resp_body =~ ~r/part="counted"[^>]*>1</

    add_key = binding_key(mount.resp_body, ~r/<button[^>]*>Add mine<\/button>/, "click")
    clicked = dispatch!(add_key, cookie(mount))

    # the page row the session holds: `mine` read again by the echo
    assert length(Store.get(session_id).record.mine) == 2
    # the patch: the count, which is outside the button
    assert clicked.resp_body =~ ~r/part="counted"[^>]*>2</, clicked.resp_body
  end
end
