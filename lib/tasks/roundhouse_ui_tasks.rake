# frozen_string_literal: true

namespace :roundhouse_ui do
  namespace :demo do
    desc "Enqueue demo jobs for N minutes (default 10, hard cap 20): rake roundhouse_ui:demo:load[10]"
    task :load, [ :minutes ] => :environment do |_task, args|
      require "roundhouse_ui/demo"

      abort "refusing to run in #{Rails.env}" unless Rails.env.development?

      # Ask the connection where it actually is. Reading configuration cannot
      # answer that, and Sidekiq falls back to database 0 when nothing set it.
      db = Sidekiq.redis { |c| c.call("CLIENT", "INFO") }.to_s[/\bdb=(\d+)/, 1]
      abort "refusing to enqueue against Redis database 0" if db.nil? || db == "0"

      # Capped, and capped in one place. A load generator you have to remember to
      # stop is a load generator that runs all night.
      minutes = [ (args[:minutes] || 10).to_f, 20.0 ].min
      minutes = 1.0 if minutes <= 0

      mono = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      started = mono.call
      deadline = started + (minutes * 60)
      enqueued = Hash.new(0)
      tick = 0

      puts "Enqueueing to Redis db=#{db} for #{minutes.round(1)} min " \
           "(#{RoundhouseUi::Demo::ALL.size} worker classes). Ctrl-C to stop early."

      begin
        while mono.call < deadline
          tick += 1
          # A rate that moves, so the dashboard's throughput line and the drain
          # forecast have something to say. Peaks roughly every two minutes.
          phase = Math.sin(tick / 12.0)
          batch = (6 + (phase.abs * 18)).round

          batch.times do
            worker = RoundhouseUi::Demo::ALL.sample
            worker.set(queue: worker::QUEUE).perform_async(
              "account_id" => 40_000 + rand(600),
              "user_id" => 900_000 + rand(9_000),
              # Deliberately named to be masked by redact_args in the UI.
              "api_token" => "sk_live_#{SecureRandom.hex(8)}"
            )
            enqueued[worker.name.split("::").last] += 1
          end

          if (tick % 10).zero?
            left = ((deadline - mono.call) / 60).round(1)
            puts "  +#{enqueued.values.sum} enqueued, #{left} min left"
          end
          sleep 1.5
        end
      rescue Interrupt
        puts "\n  stopped early"
      end

      puts "\nDone after #{((mono.call - started) / 60).round(1)} min:"
      enqueued.sort_by { |_k, v| -v }.each { |k, v| puts format("  %-22s %5d", k, v) }
      puts format("  %-22s %5d", "TOTAL", enqueued.values.sum)
    end

    desc "Remove everything the demo seeded or enqueued"
    task clean: :environment do
      require "roundhouse_ui/demo"
      abort "refusing to run in #{Rails.env}" unless Rails.env.development?
      removed = 0
      %w[retry dead schedule].each do |set|
        Sidekiq.redis do |conn|
          conn.call("ZRANGE", set, "0", "-1").each do |raw|
            job = JSON.parse(raw) rescue next
            next unless job["rh_demo"] || job["class"].to_s.start_with?("RoundhouseUi::Demo::")

            conn.call("ZREM", set, raw)
            removed += 1
          end
        end
      end
      RoundhouseUi::Demo::ALL.each { |w| Sidekiq::Queue.new(w::QUEUE).clear }
      puts "removed #{removed} demo entries from the retry/dead/scheduled sets"
    end
  end
end
