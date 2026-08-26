require "test_helper"

module RoundhouseUi
  # Six sites hand-enumerated the filters into URLs and forms. Adding `class=` and
  # `error=` updated three of them, and the confirm form was one of the misses — so
  # a dry run listing two jobs POSTed a request that deleted five, and reported
  # "Deleted 5 matching job(s)" as though that had been approved.
  #
  # `active_filters` / `filter_params` / `filter_url` start from ALL of them and
  # name only the delta, so dropping one is not expressible. This test is what
  # stops anyone going back to a list — including me, since I fixed six sites and
  # wrote a behavioural test for exactly one of them.
  class FilterTransportTest < ActiveSupport::TestCase
    ROOT = RoundhouseUi::Engine.root

    # Spellings that mean "I am building a filtered URL or form by hand".
    HAND_ROLLED = [
      /\bq:\s*@query/, /\bq:\s*params\[:q\]/,
      /\btag:\s*params\[:tag\]/, /\bqueue:\s*params\[:queue\]/,
      /name="tag"/, /name="queue"/, /name="class"/, /name="error"/
    ].freeze

    # Each exemption is a decision, with the reason, not a way to quiet the test.
    ALLOWED = {
      # Filters on queue NAME plus a paused/active state. Different filter set,
      # different concern — it does not include JobSetBrowsing.
      "app/views/roundhouse_ui/queues/index.html.erb" =>
        "queue-name + state filter, not the job-set filters",
      # ErrorsController does not include JobSetBrowsing either: it has q and tag
      # and no class/error/queue, because a row already IS a class+error group.
      "app/views/roundhouse_ui/errors/index.html.erb" =>
        "grouped errors carry only q and tag; active_filters is not available here",
      # `name="queue"` here is a job ATTRIBUTE being edited, not a filter.
      "app/views/roundhouse_ui/jobs/_form.html.erb" =>
        "the queue field of a job being edited, not a filter"
    }.freeze

    def files
      Dir[ROOT.join("app/views/**/*.erb"), ROOT.join("app/helpers/**/*.rb")].sort
    end

    def test_nothing_enumerates_filter_params_by_hand
      offenders = files.flat_map do |path|
        rel = path.sub(ROOT.to_s + "/", "")
        next [] if ALLOWED.key?(rel)

        File.readlines(path).each_with_index.filter_map do |line, i|
          next if line.lstrip.start_with?("#", "<%#")

          hits = HAND_ROLLED.count { |re| line.match?(re) }
          "#{rel}:#{i + 1} — #{line.strip[0, 90]}" if hits.positive?
        end
      end

      assert_empty offenders, <<~WHY
        These build a filtered URL or form by naming filters one at a time:

          #{offenders.join("\n          ")}

        Use filter_url / filter_params / active_filters. They start from every
        active filter, so the next one added cannot be silently dropped — which is
        how the confirm form came to destroy more jobs than its dry run displayed.
      WHY
    end

    def test_the_filter_key_list_covers_every_filter_the_scan_reads
      # If a filter is honoured by entry_selected? but missing from FILTER_KEYS, it
      # never reaches a URL — the browse would apply it and the bulk would not.
      predicate = File.read(ROOT.join("app/controllers/concerns/roundhouse_ui/job_set_browsing.rb"))
      body = predicate[/def entry_selected\?.*?\n    end/m]
      assert body, "could not find entry_selected?"

      read = body.scan(/@(\w+)_filter\b/).flatten.uniq.map(&:to_sym)
      read << :tag if body.include?("entry_tagged?")
      read << :q   if body.include?("entry_matches?")

      missing = read - JobSetBrowsing::FILTER_KEYS
      assert_empty missing,
        "entry_selected? honours #{missing.join(', ')} but FILTER_KEYS omits them, " \
        "so no URL or form carries them and the dry run and the action will diverge."
    end

    def test_active_filters_serializes_every_key
      keys = JobSetBrowsing::FILTER_KEYS
      source = File.read(ROOT.join("app/controllers/concerns/roundhouse_ui/job_set_browsing.rb"))
      body = source[/def active_filters.*?\n    end/m]
      assert body, "could not find active_filters"

      missing = keys.reject { |k| body.match?(/(^|\s)#{k}:/) }
      assert_empty missing, "active_filters omits #{missing.join(', ')}"
    end
  end
end
