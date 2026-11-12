defmodule AshUi.Datastar.UpstreamBugs.DispatchEchoCountTest do
  @moduledoc """
  A count over a `no_attributes?` has_many, shown outside the row a dispatch is
  bound in (an inbox's unread badge in its header): a page action that marks
  a notice read writes the relationship's destination, so the dispatch echo
  reads `unread` again and the badge renders the new count, through the real
  datastar POST cycle.
  """

  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias AshUi.Datastar.{Bridge, Store}

  defmodule Notices do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(AshUi.Datastar.UpstreamBugs.DispatchEchoCountTest.Notice)
    end
  end

  defmodule Notice do
    use Ash.Resource,
      domain: AshUi.Datastar.UpstreamBugs.DispatchEchoCountTest.Notices,
      data_layer: Ash.DataLayer.Ets,
      notifiers: [AshUi.Notifier]

    ets do
      private?(false)
    end

    attributes do
      attribute(:id, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:body, :string, allow_nil?: false, public?: true)
      attribute(:state, :atom, allow_nil?: false, default: :unread, public?: true, constraints: [one_of: [:unread, :read]])
    end

    actions do
      defaults([:read])

      create :create do
        primary?(true)
        accept([:id, :body])
      end

      update :mark_read do
        change(set_attribute(:state, :read))
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
      route("/echo-count")
    end

    attributes do
      attribute(:session_id, :string, primary_key?: true, allow_nil?: false, public?: false)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    relationships do
      has_many :unread, AshUi.Datastar.UpstreamBugs.DispatchEchoCountTest.Notice do
        no_attributes?(true)
        filter(expr(state == :unread))
      end

      has_many :notices, AshUi.Datastar.UpstreamBugs.DispatchEchoCountTest.Notice do
        no_attributes?(true)
        sort(id: :asc)
      end
    end

    actions do
      defaults([:read])

      create :mount do
      end

      update :mark_notice_read do
        require_atomic?(false)
        argument(:notice_id, :string, allow_nil?: false)

        change(fn changeset, context ->
          notice_id = Ash.Changeset.get_argument(changeset, :notice_id)

          Ash.Changeset.after_action(changeset, fn _changeset, record ->
            opts = Ash.Scope.to_opts(context)

            AshUi.Datastar.UpstreamBugs.DispatchEchoCountTest.Notice
            |> Ash.get!(notice_id, opts)
            |> Ash.Changeset.for_update(:mark_read, %{}, opts)
            |> Ash.update!(opts)

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
            inline(:counted, [], [text(to_string(count(unread)))]),
            list(:rows, [], [
              each(notices, :notice, [key: notice.id], [
                item(:row, [data: %{state: notice.state}], [
                  text(notice.body),
                  button(
                    :send,
                    [type: :button, on_click: :mark_notice_read, action_input: %{notice_id: notice.id}],
                    [text("Mark as read")]
                  )
                ])
              ])
            ])
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

  defp opts, do: Bridge.init(resources: [Page])

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

  test "marking a notice read renders the count of unread notices outside its row" do
    for {id, body} <- [{"n1", "first"}, {"n2", "second"}] do
      Notice
      |> Ash.Changeset.for_create(:create, %{id: id, body: body})
      |> Ash.create!()
    end

    mount = conn(:get, "/echo-count") |> Bridge.call(opts())
    session_id = mount |> cookie() |> cookie_value()
    assert length(Store.get(session_id).record.unread) == 2
    assert mount.resp_body =~ ~r/part="counted"[^>]*>2</

    mark_key = binding_key(mount.resp_body, ~r/<button[^>]*>Mark as read<\/button>/, "click")
    clicked = dispatch!(mark_key, cookie(mount))

    # the page row the session holds: `unread` read again by the echo
    assert length(Store.get(session_id).record.unread) == 1
    # the patch: the notice row (its state) and the count outside it
    assert clicked.resp_body =~ ~s(data-state="read")
    assert clicked.resp_body =~ ~r/part="counted"[^>]*>1</, clicked.resp_body
  end
end
