defmodule AshUi.Datastar.UpstreamBugs.DispatchEchoNestedAggregateTest do
  @moduledoc """
  A count over a has_many of a record the page loads through a to-one
  relationship (the page's portfolio and its `risk_count`), shown outside the
  button a dispatch is bound in. A page action that adds a risk to the
  portfolio writes a row the count derives from, so the dispatch echo must
  read the count again and the patch must carry the new value, through the
  real datastar POST cycle.

  The walk subscribes to the rows a loaded calculation or aggregate derives
  from ("whatever a page reads, it subscribes to",
  `AshUi.Notification.DerivedReads`) once per record it walks. It went under
  a loaded relationship only when that relationship's load loads a
  relationship (`recurse_notification_relationships?/2`), so a record loaded
  with derived fields alone was never walked: no subscription on the risks,
  the notification of the new risk reached nothing, and the count stayed as
  it was.
  """

  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias AshUi.Datastar.{Bridge, Store}

  defmodule Book do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(AshUi.Datastar.UpstreamBugs.DispatchEchoNestedAggregateTest.Portfolio)
      resource(AshUi.Datastar.UpstreamBugs.DispatchEchoNestedAggregateTest.Risk)
    end
  end

  defmodule Portfolio do
    use Ash.Resource,
      domain: AshUi.Datastar.UpstreamBugs.DispatchEchoNestedAggregateTest.Book,
      data_layer: Ash.DataLayer.Ets,
      notifiers: [AshUi.Notifier]

    ets do
      private?(false)
    end

    attributes do
      attribute(:id, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:name, :string, allow_nil?: false, public?: true)
    end

    relationships do
      has_many :risks, AshUi.Datastar.UpstreamBugs.DispatchEchoNestedAggregateTest.Risk do
        destination_attribute(:portfolio_id)
        public?(true)
      end
    end

    aggregates do
      count(:risk_count, :risks, public?: true)
    end

    actions do
      defaults([:read])

      create :create do
        primary?(true)
        accept([:id, :name])
      end
    end
  end

  defmodule Risk do
    use Ash.Resource,
      domain: AshUi.Datastar.UpstreamBugs.DispatchEchoNestedAggregateTest.Book,
      data_layer: Ash.DataLayer.Ets,
      notifiers: [AshUi.Notifier]

    ets do
      private?(false)
    end

    attributes do
      attribute(:id, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:portfolio_id, :string, allow_nil?: false, public?: true)
    end

    actions do
      defaults([:read])

      create :create do
        primary?(true)
        accept([:id, :portfolio_id])
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
      route("/echo-nested")
    end

    attributes do
      attribute(:session_id, :string, primary_key?: true, allow_nil?: false, public?: false)
      attribute(:portfolio_id, :string, default: "book-1", allow_nil?: false, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    relationships do
      has_one :portfolio, AshUi.Datastar.UpstreamBugs.DispatchEchoNestedAggregateTest.Portfolio do
        source_attribute(:portfolio_id)
        destination_attribute(:id)
        public?(true)
      end
    end

    actions do
      defaults([:read])

      create :mount do
      end

      update :add_risk do
        require_atomic?(false)

        change(fn changeset, _context ->
          Ash.Changeset.after_action(changeset, fn _changeset, record ->
            AshUi.Datastar.UpstreamBugs.DispatchEchoNestedAggregateTest.Risk
            |> Ash.Changeset.for_create(:create, %{id: "risk-2", portfolio_id: record.portfolio_id})
            |> Ash.create!()

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
            inline(:counted, [], [text(to_string(portfolio.risk_count))]),
            button(:send, [type: :button, on_click: :add_risk], [text("Add risk")])
          ])
        )
      )
    end
  end

  setup do
    Ash.DataLayer.Ets.stop(Page)
    Ash.DataLayer.Ets.stop(Portfolio)
    Ash.DataLayer.Ets.stop(Risk)
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

  test "a risk added to the page's portfolio renders the portfolio's risk count" do
    Portfolio
    |> Ash.Changeset.for_create(:create, %{id: "book-1", name: "Book"})
    |> Ash.create!()

    Risk
    |> Ash.Changeset.for_create(:create, %{id: "risk-1", portfolio_id: "book-1"})
    |> Ash.create!()

    mount = conn(:get, "/echo-nested") |> Bridge.call(opts())
    session_id = mount |> cookie() |> cookie_value()
    assert Store.get(session_id).record.portfolio.risk_count == 1
    assert mount.resp_body =~ ~r/part="counted"[^>]*>1</

    add_key = binding_key(mount.resp_body, ~r/<button[^>]*>Add risk<\/button>/, "click")
    clicked = dispatch!(add_key, cookie(mount))

    # the page row the session holds: the portfolio's count read again by the echo
    assert Store.get(session_id).record.portfolio.risk_count == 2
    # the patch: the count, which is outside the button
    assert clicked.resp_body =~ ~r/part="counted"[^>]*>2</, clicked.resp_body
  end
end
