require "test_helper"

module RoundhouseUi
  class DashboardControllerTest < ActionDispatch::IntegrationTest
    def fake_stats
      Struct.new(
        :processed, :failed, :enqueued, :scheduled_size,
        :retry_size, :dead_size, :workers_size
      ).new(8_420_118, 1_724, 10_641, 3_201, 218, 1_506, 47)
    end

    class FakeSet
      include Enumerable
      def initialize(items = []) = @items = items
      def each(&blk) = @items.each(&blk)
    end

    # The dashboard #show reads Stats + Queue, plus ProcessSet (utilization) and
    # the retry/dead sets (top failing classes) — stub them all so it renders
    # without a live Redis.
    def stub_dashboard(&blk)
      stub_method(Sidekiq::Stats, :new, fake_stats) do
        stub_method(Sidekiq::Queue, :all, []) do
          stub_method(Sidekiq::ProcessSet, :new, FakeSet.new) do
            stub_method(Sidekiq::RetrySet, :new, FakeSet.new) do
              stub_method(Sidekiq::DeadSet, :new, FakeSet.new, &blk)
            end
          end
        end
      end
    end


    class FakeErrorEntry
      attr_reader :klass, :jid, :queue, :at, :item
      def initialize(klass:, wrapped: nil, jid: "j1")
        @klass, @jid, @queue, @at = klass, jid, "mailers", Time.now
        @item = { "jid" => jid, "error_class" => "Net::SMTPServerBusy" }
        @item["wrapped"] = wrapped if wrapped
      end
    end

    # The dashboard's top-failing panel links to errors_path(q: g[:klass]), and
    # the Errors page greps that same value. Both ends have to move together
    # when the class is unwrapped, so this follows the link rather than trusting
    # the two halves separately. Every other dashboard test renders @top_errors
    # empty, so this href was previously exercised by nothing.
    def test_the_top_failing_link_finds_its_own_group
      wrapped = FakeErrorEntry.new(
        klass: "ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper",
        wrapped: "ActionMailer::MailDeliveryJob"
      )

      href = nil
      stub_method(Sidekiq::Stats, :new, fake_stats) do
        stub_method(Sidekiq::Queue, :all, []) do
          stub_method(Sidekiq::ProcessSet, :new, FakeSet.new) do
            stub_method(Sidekiq::RetrySet, :new, FakeSet.new) do
              stub_method(Sidekiq::DeadSet, :new, FakeSet.new([ wrapped ])) do
                get "/roundhouse"
                assert_response :success
                assert_match "ActionMailer::MailDeliveryJob", @response.body,
                  "the panel must name the real class, not the adapter wrapper"
                href = @response.body[%r{(/roundhouse/errors\?q=[^"']+)}, 1]
              end
            end
          end
        end
      end

      assert href, "dashboard did not render a top-failing link to follow"
      stub_method(Sidekiq::RetrySet, :new, FakeSet.new) do
        stub_method(Sidekiq::DeadSet, :new, FakeSet.new([ wrapped ])) do
          get CGI.unescapeHTML(href)
          assert_response :success
          assert_match "ActionMailer::MailDeliveryJob", @response.body,
            "following the dashboard link must find the group it came from"
        end
      end
    end

    # Proves the engine mounts, the controller reads Sidekiq::Stats, the view
    # renders, and the live-update hooks are present.
    def test_dashboard_renders_real_sidekiq_stats
      stub_dashboard do
        get "/roundhouse"

        assert_response :success
        assert_match "Roundhouse", @response.body
        assert_match "8,420,118", @response.body          # processed, delimited
        assert_match "No active queues", @response.body
        assert_match 'data-stat="processed"', @response.body # live-update hook
        assert_match "/roundhouse/stats", @response.body     # poll endpoint wired
        assert_match 'id="rh-tick"', @response.body           # refresh countdown present
        assert_match 'id="rh-palette"', @response.body       # ⌘K command palette present
        assert_match "/roundhouse/turbo.js", @response.body  # Turbo loaded
        assert_match "Healthy", @response.body               # composite health verdict
      end
    end

    # Proves the UI reads through RoundhouseUi.backend, not hardcoded Sidekiq —
    # a non-Sidekiq object supplies the data (the seam Solid Queue will use).
    def test_reads_through_the_configured_backend
      stats = fake_stats # capture as a local so the singleton method closes over it
      fake = Object.new
      fake.define_singleton_method(:stats) { stats }
      fake.define_singleton_method(:queues) { [] }
      # The poll reads depths through the port too, so a backend that satisfies
      # the contract needs no Redis of any kind.
      summaries = [ RoundhouseUi::QueueSummary.new(name: "mailers", size: 7, latency: 3.0) ]
      fake.define_singleton_method(:queue_summaries) { summaries }
      RoundhouseUi.backend = fake

      get "/roundhouse/stats"
      assert_response :success
      body = JSON.parse(@response.body)
      assert_equal 8_420_118, body["processed"]
      assert_equal({ "mailers" => 7 }, body["queue_depths"])
    ensure
      RoundhouseUi.backend = nil # fall back to the default Sidekiq backend
    end

    def test_response_carries_a_self_contained_nonce_csp
      stub_dashboard do
        get "/roundhouse"

        csp = @response.headers["Content-Security-Policy"]
        assert csp.present?, "engine sets its own CSP"
        assert_match "script-src", csp
        assert_match(/'nonce-/, csp, "script-src is nonce-based")
        assert_match(/<script nonce="[^"]+"/, @response.body, "inline poll script is nonce'd")
      end
    end

    def test_stats_endpoint_returns_live_counts_as_json
      stub_method(Sidekiq::Stats, :new, fake_stats) do
        stub_method(Sidekiq::Queue, :all, []) do
          get "/roundhouse/stats"

          assert_response :success
          assert_equal "application/json", @response.media_type
          body = JSON.parse(@response.body)
          assert_equal 8_420_118, body["processed"]
          assert_equal 47, body["busy"]
          assert_equal 1_506, body["dead"]
        end
      end
    end
  end
end
