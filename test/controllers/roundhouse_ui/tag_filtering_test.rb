require "test_helper"

module RoundhouseUi
  # Steps 3 and 4 of ADR 0002: tags annotate error groups, and ?tag=key:value
  # filters the job sets — applied identically in browse and bulk_apply so the
  # rows an operator sees are the rows a bulk action touches.
  class TagFilteringTest < ActionDispatch::IntegrationTest
    class FakeEntry
      attr_reader :klass, :jid, :args, :item, :at, :queue, :actions
      def initialize(klass:, jid:, queue: "default", wrapped: nil)
        @klass, @jid, @queue, @args, @at = klass, jid, queue, [], Time.now + 60
        @item = { "jid" => jid, "error_class" => "Boom", "error_message" => "boom", "retry_count" => 1, "args" => [] }
        @item["wrapped"] = wrapped if wrapped
        @actions = []
      end
      define_method(:retry) { @actions << :retry }
      def delete = @actions << :delete
    end

    class FakeSet
      def initialize(entries) = @entries = entries
      def size = @entries.size
      def each(&blk) = @entries.each(&blk)
      def find_job(jid) = @entries.find { |e| e.jid == jid }
    end

    # Class names deliberately share no substring with their squad, so a search
    # for "growth" can only match through the tag — otherwise these tests would
    # pass on the class-name match and prove nothing.
    OWNERS = { "AlphaJob" => :growth, "BetaJob" => :core }.freeze

    def setup
      RoundhouseUi.read_only = false
      RoundhouseUi.job_tags = ->(klass:, item:) { { squad: OWNERS[klass] } if OWNERS.key?(klass) }
      @entries = [
        FakeEntry.new(klass: "AlphaJob", jid: "g1"),
        FakeEntry.new(klass: "AlphaJob", jid: "g2"),
        FakeEntry.new(klass: "BetaJob",   jid: "c1"),
        FakeEntry.new(klass: "UntaggedJob", jid: "u1")
      ]
      @set = FakeSet.new(@entries)
    end

    def teardown
      RoundhouseUi.job_tags = nil
      RoundhouseUi.job_tags_per_job = false
      RoundhouseUi.tag_filters = nil
      RoundhouseUi.read_only = false
    end

    # --- step 4: filtering ---------------------------------------------------

    def test_tag_filter_narrows_the_listing
      stub_method(Sidekiq::RetrySet, :new, @set) do
        get "/roundhouse/retries?tag=squad:growth"
        assert_response :success
        assert_match "g1", @response.body
        assert_match "g2", @response.body
        assert_no_match(/\bc1\b/, @response.body)
        assert_no_match(/\bu1\b/, @response.body)
      end
    end

    def test_no_tag_filter_lists_everything
      stub_method(Sidekiq::RetrySet, :new, @set) do
        get "/roundhouse/retries"
        assert_response :success
        %w[g1 g2 c1 u1].each { |jid| assert_match jid, @response.body }
      end
    end

    # A known key with an unusable value is DROPPED, not refused — a typo should not
    # stop you browsing. What it must not do is quietly widen a destroy: the facet is
    # gone for browse and bulk alike (one filter, no divergence), and bulk declines
    # to act at all, because what survived selects a superset of what was typed.
    def test_a_malformed_tag_is_ignored_for_browsing
      stub_method(Sidekiq::RetrySet, :new, @set) do
        get "/roundhouse/retries?tag=garbage"
        assert_response :success
        body = @response.body.split("</style>").last.to_s

        assert_match(/\bu1\b/, body, "an unusable tag must be dropped, not select nothing")
        assert_match "Ignored", body, "a dropped filter must say it was dropped"
        assert_match "tag= takes key:value", body
      end
    end

    # The heading must describe the filter that SURVIVED, not the bulk gate. This is
    # the second time display was routed through any_filter? and lied: `tag=garbage
    # queue=mailers` applies the queue and narrows the table, but any_filter? answers
    # "may this authorise a bulk action" — no, because it degraded — so the heading
    # reported the whole set over a narrowed table.
    def test_a_degraded_filter_still_reports_what_it_narrowed_to
      mixed = FakeSet.new([
        FakeEntry.new(klass: "AlphaJob", jid: "m1", queue: "mailers"),
        FakeEntry.new(klass: "AlphaJob", jid: "d1", queue: "default")
      ])
      stub_method(Sidekiq::DeadSet, :new, mixed) do
        get "/roundhouse/dead?q=tag%3Dgarbage+queue%3Dmailers"
        body = @response.body.split("</style>").last.to_s

        assert_match "1 of 2 jobs", body,
          "the heading reported the whole set over a table narrowed by the surviving filter"
        # The pill names it now, in the words you would type to reproduce it — the
        # heading's prose restatement was one of the four renderings this replaced.
        assert_match %r{<span class="k">queue</span>\s*<span class="v"[^>]*>mailers</span>}, body,
          "and must name the filter it did apply"
      end
    end

    # A dropped facet that leaves nothing behind is NOT a filter, and must not be
    # described as one — the table shows every row, so "0 of N" would be wrong too.
    def test_a_fully_dropped_filter_reports_the_whole_set
      stub_method(Sidekiq::RetrySet, :new, @set) do
        get "/roundhouse/retries?q=tag%3Dgarbage"
        body = @response.body.split("</style>").last.to_s

        # The exact heading, not a substring of it: "#{@set.size} jobs" also matches
        # "4 of 4 jobs", so asserting the substring passed whether or not the fully
        # dropped filter was reported as a filter. Vacuous, and it was mine.
        heading = body[/<h2 class="rh-h2">(.*?)<\/h2>/m, 1].to_s.gsub(/<[^>]+>/, " ").squeeze(" ").strip
        assert_equal "Retries · #{@set.size} jobs", heading,
          "nothing survived the drop, so nothing is 'of' the set"
        assert_match "Ignored", body, "the drop must still be reported"
      end
    end

    # `tag=squad:` has a colon, so a colon-only check let it through: pill rendered,
    # tag_pair nil, entry_selected? selected everything — and any_facets? was true, so
    # the bulk controls stayed live over the whole set.
    def test_a_half_empty_tag_selects_nothing_and_authorises_no_bulk
      mixed = FakeSet.new([
        FakeEntry.new(klass: "AlphaJob", jid: "m1", queue: "mailers"),
        FakeEntry.new(klass: "AlphaJob", jid: "d1", queue: "default")
      ])
      stub_method(Sidekiq::DeadSet, :new, mixed) do
        %w[squad: :core :].each do |bad|
          get "/roundhouse/dead", params: { q: "tag=#{bad}" }
          assert_response :success
          body = @response.body.split("</style>").last.to_s
          assert_match "Ignored", body, "tag=#{bad} was accepted as a filter"
          refute_match "preview", body, "tag=#{bad} left the bulk controls live"
        end

        post "/roundhouse/dead/bulk_all", params: { op: "delete", q: "tag=squad: queue=mailers" }
        assert_equal 2, Sidekiq::DeadSet.new.size,
          "a half-empty tag scoped a destroy to the surviving queue filter"
      end
    end

    # THE reason this is a drop and not a silent ignore. `tag=garbage queue=mailers`
    # degrades to `queue=mailers`, which selects the whole queue — so a Delete offered
    # here would destroy every dead job in it while the operator believed the tag
    # narrowed it too. That is the confirm-2-destroy-5 shape reached by a typo.
    def test_a_dropped_facet_authorises_no_bulk_action
      mixed = FakeSet.new([
        FakeEntry.new(klass: "AlphaJob", jid: "m1", queue: "mailers"),
        FakeEntry.new(klass: "AlphaJob", jid: "d1", queue: "default")
      ])
      stub_method(Sidekiq::DeadSet, :new, mixed) do
        get "/roundhouse/dead?q=tag%3Dgarbage+queue%3Dmailers"
        assert_response :success
        body = @response.body.split("</style>").last.to_s

        assert_match(/\bm1\b/, body, "the surviving queue filter must still browse")
        refute_match(/\bd1\b/, body)
        refute_match "preview", body,
          "a degraded filter must offer no bulk control — it selects wider than it says"

        post "/roundhouse/dead/bulk_all", params: { op: "delete", q: "tag=garbage queue=mailers" }
        assert_equal 2, Sidekiq::DeadSet.new.size,
          "a degraded filter scoped a destroy to more than was typed"
        assert_match(/Ignored/, flash[:alert].to_s,
          "the refusal must name what was dropped, not claim there was no filter")
      end
    end

    def test_tag_and_text_query_combine
      stub_method(Sidekiq::RetrySet, :new, @set) do
        get "/roundhouse/retries?tag=squad:growth&q=g2"
        assert_response :success
        assert_match "g2", @response.body
        assert_no_match(/\bg1\b/, @response.body)
      end
    end

    # The safety property: bulk acts on exactly the filtered set, never wider.
    def test_bulk_all_respects_the_tag_filter
      stub_method(Sidekiq::RetrySet, :new, @set) do
        post "/roundhouse/retries/bulk_all", params: { op: "delete", tag: "squad:growth" }
      end
      deleted = @entries.select { |e| e.actions.include?(:delete) }.map(&:jid)
      assert_equal %w[g1 g2], deleted.sort
    end

    def test_bulk_all_with_tag_and_query_intersects
      stub_method(Sidekiq::RetrySet, :new, @set) do
        post "/roundhouse/retries/bulk_all", params: { op: "delete", tag: "squad:growth", q: "g1" }
      end
      deleted = @entries.select { |e| e.actions.include?(:delete) }.map(&:jid)
      assert_equal %w[g1], deleted
    end

    # --- squad names are searchable ------------------------------------------

    def test_the_search_box_finds_jobs_by_tag_value
      stub_method(Sidekiq::RetrySet, :new, @set) do
        get "/roundhouse/retries?q=growth"
        assert_response :success
        assert_match "g1", @response.body
        assert_match "g2", @response.body
        assert_no_match(/\bc1\b/, @response.body, "a core job must not match a growth search")
      end
    end

    # The reason tag values are allowed into the free-text haystack at all:
    # browse and bulk_apply share one predicate, so a text search that matches
    # by tag selects exactly the rows it displays. If these ever diverge, an
    # operator sees one set and "delete all matching" destroys another.
    def test_bulk_all_matches_by_tag_value_exactly_as_the_listing_does
      stub_method(Sidekiq::RetrySet, :new, @set) do
        post "/roundhouse/retries/bulk_all", params: { op: "delete", q: "growth" }
      end
      deleted = @entries.select { |e| e.actions.include?(:delete) }.map(&:jid)
      assert_equal %w[g1 g2], deleted.sort
    end

    def test_searching_by_tag_finds_nothing_when_no_resolver_is_configured
      RoundhouseUi.job_tags = nil
      stub_method(Sidekiq::RetrySet, :new, @set) do
        get "/roundhouse/retries?q=growth"
        assert_response :success
        assert_no_match(/\bg1\b/, @response.body)
      end
    end

    def test_an_undeclared_key_matches_nothing_when_a_vocabulary_is_declared
      RoundhouseUi.tag_filters = { squad: %w[growth core] }
      stub_method(Sidekiq::RetrySet, :new, @set) do
        get "/roundhouse/retries?tag=team:growth"
        assert_response :success
        assert_no_match(/\bg1\b/, @response.body, "fail closed on an undeclared key")
      end
    end

    def test_an_undeclared_key_matches_nothing_for_bulk_too
      RoundhouseUi.tag_filters = { squad: %w[growth core] }
      stub_method(Sidekiq::RetrySet, :new, @set) do
        post "/roundhouse/retries/bulk_all", params: { op: "delete", tag: "team:growth" }
      end
      assert_empty @entries.select { |e| e.actions.any? }, "fail-closed must apply to destructive paths"
    end

    def test_the_filter_control_renders_declared_vocabulary
      RoundhouseUi.tag_filters = { squad: %w[growth core] }
      stub_method(Sidekiq::RetrySet, :new, @set) do
        get "/roundhouse/retries"
        assert_response :success
        assert_match "squad: growth", @response.body
        assert_match "squad: core", @response.body
      end
    end

    def test_the_bulk_bar_appears_for_a_tag_only_filter
      stub_method(Sidekiq::RetrySet, :new, @set) do
        get "/roundhouse/retries?tag=squad:growth"
        assert_response :success
        assert_match "tagged squad: growth", @response.body,
          "the confirm/description must name the tag, not just a text query"
      end
    end

    def test_the_dead_set_filters_too
      stub_method(Sidekiq::DeadSet, :new, @set) do
        get "/roundhouse/dead?tag=squad:core"
        assert_response :success
        assert_match "c1", @response.body
        assert_no_match(/\bg1\b/, @response.body)
      end
    end

    def test_the_scheduled_set_filters_too
      stub_method(Sidekiq::ScheduledSet, :new, @set) do
        get "/roundhouse/scheduled?tag=squad:core"
        assert_response :success
        assert_match "c1", @response.body
        assert_no_match(/\bg1\b/, @response.body)
      end
    end

    # --- ?queue= filtering ---------------------------------------------------

    def test_queue_filter_narrows_the_listing
      mixed = FakeSet.new([
        FakeEntry.new(klass: "AlphaJob", jid: "m1", queue: "mailers"),
        FakeEntry.new(klass: "BetaJob",  jid: "d1", queue: "default")
      ])
      stub_method(Sidekiq::RetrySet, :new, mixed) do
        get "/roundhouse/retries?queue=mailers"
        assert_response :success
        assert_match "m1", @response.body
        assert_no_match(/\bd1\b/, @response.body)
      end
    end

    # Exact, not substring: this predicate also drives bulk_apply, so "default"
    # selecting "default_low" would quietly widen a destructive action.
    def test_queue_filter_is_an_exact_match
      mixed = FakeSet.new([
        FakeEntry.new(klass: "AlphaJob", jid: "d1", queue: "default"),
        FakeEntry.new(klass: "AlphaJob", jid: "d2", queue: "default_low")
      ])
      stub_method(Sidekiq::RetrySet, :new, mixed) do
        get "/roundhouse/retries?queue=default"
        assert_response :success
        assert_match "d1", @response.body
        assert_no_match(/\bd2\b/, @response.body)
      end
    end

    def test_bulk_all_respects_the_queue_filter
      mixed = [
        FakeEntry.new(klass: "AlphaJob", jid: "m1", queue: "mailers"),
        FakeEntry.new(klass: "AlphaJob", jid: "d1", queue: "default")
      ]
      stub_method(Sidekiq::RetrySet, :new, FakeSet.new(mixed)) do
        post "/roundhouse/retries/bulk_all", params: { op: "delete", queue: "mailers" }
      end
      assert_equal [ "m1" ], mixed.select { |e| e.actions.any? }.map(&:jid)
    end

    def test_queue_and_tag_filters_intersect
      mixed = FakeSet.new([
        FakeEntry.new(klass: "AlphaJob", jid: "m1", queue: "mailers"),
        FakeEntry.new(klass: "BetaJob",  jid: "m2", queue: "mailers")
      ])
      stub_method(Sidekiq::RetrySet, :new, mixed) do
        get "/roundhouse/retries?queue=mailers&tag=squad:growth"
        assert_response :success
        assert_match "m1", @response.body
        assert_no_match(/\bm2\b/, @response.body)
      end
    end

    # Seeds Redis rather than stubbing Sidekiq::Queue — the page reads every
    # queue's depth and latency in one pipelined batch, which a stub would skip.
    def test_queues_index_can_be_filtered_by_name
      with_fake_redis do |fake|
        %w[mailers critical].each { |n| fake.call("SADD", "queues", n) }
        get "/roundhouse/queues?q=mail"
        assert_response :success
        assert_match "mailers", @response.body
        assert_no_match "critical", @response.body
      end
    end


    # The destructive-scope invariant, asserted end to end: what the page shows
    # under a queue filter is exactly what "delete all matching" destroys. The
    # bulk forms previously omitted queue, so the page showed a narrow set and
    # the POST acted on a wider one.
    def test_the_bulk_all_form_carries_every_active_filter
      mixed = FakeSet.new([
        FakeEntry.new(klass: "AlphaJob", jid: "m1", queue: "mailers"),
        FakeEntry.new(klass: "AlphaJob", jid: "d1", queue: "default")
      ])
      stub_method(Sidekiq::DeadSet, :new, mixed) do
        get "/roundhouse/dead?queue=mailers"
        assert_response :success

        # The destructive control itself, not the search box: whatever this link
        # carries is the scope the confirm page will offer to delete.
        href = css_select("a.rh-btn-danger[href*='preview']").first&.[]("href")
        refute_nil href, "no bulk delete control under an active queue filter"
        assert_equal "queue=mailers",
          FilterQuery.parse(Rack::Utils.parse_nested_query(URI(href).query)["q"]).to_s,
          "the bulk control must carry the queue filter, or it acts wider than the page shows"
      end
    end

    def test_the_heading_reports_the_filtered_count_not_the_whole_set
      stub_method(Sidekiq::RetrySet, :new, @set) do
        get "/roundhouse/retries?tag=squad:growth"
        assert_response :success
        assert_match "2 of 4 jobs", @response.body
      end
    end

    def test_an_empty_result_under_a_tag_filter_does_not_claim_the_set_is_empty
      stub_method(Sidekiq::DeadSet, :new, @set) do
        get "/roundhouse/dead?tag=squad:nobody"
        assert_response :success
        assert_no_match "Dead set is empty", @response.body
        assert_match "No dead jobs", @response.body
      end
    end

    # --- the squad column and quick filters ----------------------------------

    def test_the_tag_column_appears_only_when_tags_are_configured
      RoundhouseUi.tag_filters = { squad: %w[growth core] }
      stub_method(Sidekiq::RetrySet, :new, @set) do
        get "/roundhouse/retries"
        assert_response :success
        assert_match "<th>Squad</th>", @response.body
      end

      RoundhouseUi.job_tags = nil
      stub_method(Sidekiq::RetrySet, :new, @set) do
        get "/roundhouse/retries"
        assert_response :success
        assert_no_match "<th>Squad</th>", @response.body, "no dead column for hosts without tags"
      end
    end

    # A conditional column has to be conditional in the header, the body and the
    # empty-state colspan, or the table silently misaligns.
    def test_the_empty_state_spans_the_right_number_of_columns
      # Retries: Job, Squad, Queue, Last error, Attempt, Next try, Actions
      stub_method(Sidekiq::RetrySet, :new, FakeSet.new([])) do
        get "/roundhouse/retries"
        assert_response :success
        assert_match 'colspan="7"', @response.body
      end

      RoundhouseUi.job_tags = nil
      stub_method(Sidekiq::RetrySet, :new, FakeSet.new([])) do
        get "/roundhouse/retries"
        assert_response :success
        assert_match 'colspan="6"', @response.body
      end
    end

    # A conditional column has to be conditional in three places at once; count
    # the rendered cells against the rendered headers rather than trusting that.
    def test_every_job_set_row_has_as_many_cells_as_its_header
      { "/roundhouse/retries" => Sidekiq::RetrySet,
        "/roundhouse/dead" => Sidekiq::DeadSet,
        "/roundhouse/scheduled" => Sidekiq::ScheduledSet }.each do |path, klass|
        stub_method(klass, :new, @set) do
          get path
          assert_response :success
          # <th[ >] rather than "<th", which would also count the <thead> tag.
          headers = @response.body[%r{<thead>.*?</thead>}m].scan(/<th[\s>]/).size
          first_row = @response.body[%r{<tbody>.*?<tr>(.*?)</tr>}m, 1]
          assert_equal headers, first_row.scan(/<td[\s>]/).size, "#{path} row/header cell mismatch"
        end
      end
    end

    # The dead set had per-job retry/delete routes and controller actions but no
    # Actions column, so the only way to act on one job was to tick a checkbox —
    # unlike every other set. These assert the column is now reachable.
    def test_dead_rows_expose_per_job_actions
      stub_method(Sidekiq::DeadSet, :new, @set) do
        get "/roundhouse/dead"
        assert_response :success
        assert_match "<th class=\"r\">Actions</th>", @response.body
        assert_match "/roundhouse/dead/g1/retry", @response.body
        assert_match "/roundhouse/dead/g1/delete", @response.body
      end
    end

    def test_a_single_dead_job_can_be_deleted_from_its_row
      stub_method(Sidekiq::DeadSet, :new, @set) do
        post "/roundhouse/dead/c1/delete"
      end
      acted = @entries.select { |e| e.actions.any? }
      assert_equal [ "c1" ], acted.map(&:jid)
      assert_equal [ :delete ], acted.first.actions
    end


    # Both bugs found by the search audit: a zero-match search on Errors used to
    # 500 (empty-but-truthy counts hash took the counted branch while the
    # vocabulary fell back to the uncounted shape), and Errors search ignored
    # tags even though its placeholder advertised them.
    def test_a_zero_match_search_on_errors_renders_rather_than_500s
      RoundhouseUi.tag_filters = { squad: %w[growth core] }
      stub_method(Sidekiq::RetrySet, :new, @set) do
        stub_method(Sidekiq::DeadSet, :new, FakeSet.new([])) do
          get "/roundhouse/errors?q=zzz-no-such-thing"
          assert_response :success
          assert_match "No issues match", @response.body
        end
      end
    end

    def test_errors_search_matches_a_squad_name
      stub_method(Sidekiq::RetrySet, :new, @set) do
        stub_method(Sidekiq::DeadSet, :new, FakeSet.new([])) do
          get "/roundhouse/errors?q=growth"
          assert_response :success
          assert_match "AlphaJob", @response.body
          assert_no_match "BetaJob", @response.body
        end
      end
    end


    # --- ActiveJob unwrap in search (#30) ------------------------------------

    WRAPPER = "ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper".freeze

    # args stays empty on purpose. A real ActiveJob payload carries
    # [{"job_class" => "RealJob"}], and entry.args.to_s is already in the
    # haystack — so a realistic fixture would pass this test before the fix.
    def wrapped_set
      FakeSet.new([ FakeEntry.new(klass: WRAPPER, jid: "w1", wrapped: "ReportJob") ])
    end

    def test_search_finds_a_wrapped_job_by_its_real_class
      stub_method(Sidekiq::RetrySet, :new, wrapped_set) do
        get "/roundhouse/retries?q=ReportJob"
        assert_response :success
        assert_match "w1", @response.body
      end
    end

    # Appending rather than replacing: a saved or habitual wrapper query must
    # keep selecting what it always did, because this predicate also decides
    # what a bulk action destroys.
    def test_search_still_finds_a_wrapped_job_by_the_wrapper_name
      stub_method(Sidekiq::RetrySet, :new, wrapped_set) do
        get "/roundhouse/retries?q=JobWrapper"
        assert_response :success
        assert_match "w1", @response.body
      end
    end

    def test_bulk_selects_exactly_what_a_real_class_search_showed
      entries = [
        FakeEntry.new(klass: WRAPPER, jid: "w1", wrapped: "ReportJob"),
        FakeEntry.new(klass: WRAPPER, jid: "w2", wrapped: "OtherJob")
      ]
      stub_method(Sidekiq::RetrySet, :new, FakeSet.new(entries)) do
        post "/roundhouse/retries/bulk_all", params: { op: "delete", q: "ReportJob" }
      end
      assert_equal [ "w1" ], entries.select { |e| e.actions.any? }.map(&:jid)
    end


    def test_rows_show_the_real_class_not_the_wrapper
      { "/roundhouse/retries" => Sidekiq::RetrySet,
        "/roundhouse/dead" => Sidekiq::DeadSet,
        "/roundhouse/scheduled" => Sidekiq::ScheduledSet }.each do |path, klass|
        stub_method(klass, :new, wrapped_set) do
          get path
          assert_response :success
          assert_match "ReportJob", @response.body, "#{path} should name the real class"
          assert_no_match "JobWrapper", @response.body, "#{path} should not leak the adapter wrapper"
        end
      end
    end

    def test_the_job_page_shows_the_real_class
      stub_method(Sidekiq::RetrySet, :new, wrapped_set) do
        get "/roundhouse/jobs/retry/w1"
        assert_response :success
        assert_match "ReportJob", @response.body
      end
    end

    # --- step 3: error groups ------------------------------------------------

    def test_error_groups_are_annotated_with_the_class_tag
      stub_method(Sidekiq::RetrySet, :new, @set) do
        stub_method(Sidekiq::DeadSet, :new, FakeSet.new([])) do
          get "/roundhouse/errors"
          assert_response :success
          assert_match "growth", @response.body
          assert_match "core", @response.body
        end
      end
    end

    # Errors failed OPEN on an undeclared key: tag_filter returned nil, so no filter
    # applied and every issue listed while the bar showed a tag pill. The job sets
    # fail closed, and the README promises they both do.
    def test_errors_fails_closed_on_a_tag_key_nobody_declared
      RoundhouseUi.tag_filters = { squad: %w[growth core] }
      stub_method(Sidekiq::RetrySet, :new, @set) do
        stub_method(Sidekiq::DeadSet, :new, FakeSet.new([])) do
          get "/roundhouse/errors", params: { tag: "nosuchkey:whatever" }
          assert_response :success
          body = @response.body.split("</style>").last.to_s

          refute_match "AlphaJob", body, "an undeclared tag key listed every issue"
          refute_match "BetaJob", body
        end
      end
    end

    def test_errors_still_filters_on_a_declared_key
      RoundhouseUi.tag_filters = { squad: %w[growth core] }
      stub_method(Sidekiq::RetrySet, :new, @set) do
        stub_method(Sidekiq::DeadSet, :new, FakeSet.new([])) do
          get "/roundhouse/errors", params: { tag: "squad:growth" }
          assert_response :success
          body = @response.body.split("</style>").last.to_s
          assert_match "AlphaJob", body, "the declared key must still select"
        end
      end
    end

    def test_errors_quick_filters_count_occurrences_per_squad
      stub_method(Sidekiq::RetrySet, :new, @set) do
        stub_method(Sidekiq::DeadSet, :new, FakeSet.new([])) do
          get "/roundhouse/errors"
          assert_response :success
          assert_match "rh-quickfilters", @response.body
          # AlphaJob failed twice under one error class, BetaJob once.
          assert_match "tag=squad%3Agrowth", @response.body
          assert_match "tag=squad%3Acore", @response.body
        end
      end
    end

    def test_errors_can_be_filtered_to_one_squad
      stub_method(Sidekiq::RetrySet, :new, @set) do
        stub_method(Sidekiq::DeadSet, :new, FakeSet.new([])) do
          get "/roundhouse/errors?tag=squad:growth"
          assert_response :success
          assert_match "AlphaJob", @response.body
          assert_no_match "BetaJob", @response.body
        end
      end
    end

    # The counts describe the whole scan, so selecting one squad must not make
    # the other squads' counts vanish from the strip.
    def test_quick_filter_counts_survive_an_active_filter
      stub_method(Sidekiq::RetrySet, :new, @set) do
        stub_method(Sidekiq::DeadSet, :new, FakeSet.new([])) do
          get "/roundhouse/errors?tag=squad:growth"
          assert_response :success
          assert_match "tag=squad%3Acore", @response.body,
            "core must still be offered while growth is selected"
        end
      end
    end
  end
end
