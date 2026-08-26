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
    # Five controls in one right-aligned cell wrapped: Delete dropped to a second
    # line as soon as the glass and Edit both appeared. text-align:right does not
    # stop a cell breaking between inline-blocks, so the cell has to say so.
    def test_the_actions_cell_is_marked_and_told_not_to_wrap
      with_all_sets do
        %w[/roundhouse/retries /roundhouse/dead /roundhouse/scheduled].each do |path|
          get path
          busiest = cells_with_controls.max_by { |_body, controls| controls.size }
          refute_nil busiest, "#{path}: no cell with controls"
          assert_operator busiest[1].size, :>=, 3, "#{path}: expected the Actions cell"

          cell_tag = markup[/<td\b[^>]*>#{Regexp.escape(busiest[0][0, 60])}/m]
          assert_match(/rh-cell-actions/, cell_tag.to_s,
            "#{path}: the Actions cell is not marked rh-cell-actions, so nothing " \
            "stops it wrapping between controls")
        end
      end
    end

    def test_the_actions_class_actually_prevents_wrapping
      css = File.read(RoundhouseUi::Engine.root.join("app/views/layouts/roundhouse_ui/application.html.erb"))
      rule = css[/\.rh-table td\.rh-cell-actions \{([^}]*)\}/, 1]
      assert rule, "rh-cell-actions has no rule; marking the cell achieves nothing"
      assert_match(/white-space:\s*nowrap/, rule)
    end

    # The dashboard drew a full vendor lockup on every row — five stacked
    # wordmarks. One legend, and a compact icon per row, as on the Errors page.
    def test_the_dashboard_panel_carries_one_legend_not_a_lockup_per_row
      RoundhouseUi.observability = Observability::DatadogAdapter.new(site: "datadoghq.com", service: "sidekiq")
      with_all_sets do
        get "/roundhouse"

        rows = markup.scan(/<div class="rh-insight-row">(.*?)<\/div>\s*<\/div>/m).flatten
        refute_empty rows, "no insight rows rendered, so this asserts nothing"

        # The mark class, counted inside the rows only. Precise beats fuzzy: an
        # earlier version of this counted <svg xmlns> across a regex-guessed slice
        # of the panel and passed against the very regression it names.
        marked = rows.count { |row| row.include?("rh-mark-dd") }
        assert_equal 0, marked,
          "#{marked} of #{rows.size} rows draw a vendor lockup. One legend above the " \
          "list, a compact icon in the row — five stacked wordmarks read as five logos."

        legend = markup[/rh-trace-legend.*?<\/div>/m].to_s
        assert_includes legend, "rh-mark-dd", "the legend that replaces them is missing"
      end
    ensure
      RoundhouseUi.observability = nil
    end
  end
end
