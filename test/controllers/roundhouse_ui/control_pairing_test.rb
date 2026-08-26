require "test_helper"

module RoundhouseUi
  # The control scale (#65) stopped controls inventing their own pixels. It did not
  # stop a control asking for the wrong one of the two sizes the scale offers, and
  # nothing failed when the "find more like this" glass shipped at the row scale
  # into an Actions column of page-scale buttons. It just looked wrong.
  #
  # So: clickable controls that share a table cell share a size. That is the
  # property a person actually sees, and it is the one that kept being broken by
  # hand and fixed by hand.
  class ControlPairingTest < ActionDispatch::IntegrationTest
    # Controls a person can click. Display-only pills and badges are excluded:
    # a squad badge legitimately sits at the row scale beside anything.
    CLICKABLE = %w[rh-btn rh-trace-btn rh-runbook rh-iconbtn rh-kbd].freeze

    # Classes the stylesheet puts in the row-scale group without a modifier.
    # Mirrors the `.rh-btn--sm, .rh-runbook, ...` selector; control_scale_test
    # guards the CSS side of that.
    ROW_SCALE = %w[rh-runbook rh-pill rh-badge rh-ro rh-cap-pick].freeze

    class Entry
      attr_reader :klass, :jid, :item, :queue, :at
      def initialize(klass:, jid:, error: "Boom", queue: "default")
        @klass, @jid, @queue, @at = klass, jid, queue, Time.now + 300
        @item = { "class" => klass, "args" => [], "jid" => jid, "queue" => queue,
                  "retry_count" => 3, "failed_at" => (Time.now - 120).to_f,
                  "error_class" => error, "error_message" => error && "went wrong" }
      end
      def args = []
    end

    class Set
      include Enumerable
      def initialize(entries) = @entries = entries
      def each(&blk) = @entries.each(&blk)
      def size = @entries.size
    end

    def rows = Set.new([ Entry.new(klass: "Billing::SyncWorker", jid: "j1") ])

    def with_all_sets
      stub_method(Sidekiq::RetrySet, :new, rows) do
        stub_method(Sidekiq::DeadSet, :new, rows) do
          stub_method(Sidekiq::ScheduledSet, :new, rows) { yield }
        end
      end
    end

    def markup = response.body.split("</style>").last.to_s

    def size_of(classes)
      list = classes.split(/\s+/)
      return "row" if list.include?("rh-btn--sm") || (list & ROW_SCALE).any?

      "page"
    end

    # Every <td> on the page, with the clickable controls it contains.
    def cells_with_controls
      markup.scan(/<td\b[^>]*>(.*?)<\/td>/m).flatten.filter_map do |body|
        found = body.scan(/class="([^"]*)"/).flatten.select { |c| (c.split(/\s+/) & CLICKABLE).any? }
        [ body, found ] if found.size > 1
      end
    end

    def test_clickable_controls_sharing_a_cell_share_a_size
      with_all_sets do
        %w[/roundhouse/retries /roundhouse/dead /roundhouse/scheduled].each do |path|
          get path
          assert_response :success, "#{path} did not render"

          cells = cells_with_controls
          refute_empty cells, "#{path}: found no cell with two controls — the scanner is not matching"

          cells.each do |_body, classes|
            sizes = classes.map { |c| size_of(c) }.uniq
            assert_equal 1, sizes.size,
              "#{path}: one cell mixes the row and page scales — #{classes.inspect}. " \
              "Controls a person sees side by side have to be the same height; pick " \
              "the scale from what the control sits next to, not by hand."
          end
        end
      end
    end

    def test_the_actions_column_is_all_page_scale
      # Named separately because this is the specific regression: the glass shipped
      # at the row scale beside Edit, Enqueue now and Delete.
      with_all_sets do
        get "/roundhouse/scheduled"

        actions = cells_with_controls.max_by { |_b, c| c.size }
        refute_nil actions
        assert_equal [ "page" ], actions[1].map { |c| size_of(c) }.uniq,
          "the Actions column mixes scales: #{actions[1].inspect}"
        assert_operator actions[1].size, :>=, 3, "expected the Actions cell, with several controls"
      end
    end
  end
end
