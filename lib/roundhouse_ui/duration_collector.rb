module RoundhouseUi
  # Opt-in server middleware that records per-class execution time, so the UI can
  # answer "which job classes are slow?" — something Sidekiq doesn't track. Two
  # cheap Redis writes per job (a counter + a summed-ms float). Off by default;
  # enable in your Sidekiq server config:
  #
  #   Sidekiq.configure_server do |config|
  #     config.server_middleware { |chain| chain.add RoundhouseUi::DurationCollector }
  #   end
  class DurationCollector
    KEY = "roundhouse:durations".freeze

    def call(_worker, job, _queue)
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
    ensure
      record(job["class"], (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000.0)
    end

    private

    def record(klass, elapsed_ms)
      return unless klass

      Sidekiq.redis do |conn|
        conn.call("HINCRBY", KEY, "#{klass}\x00count", 1)
        conn.call("HINCRBYFLOAT", KEY, "#{klass}\x00ms", elapsed_ms)
      end
    rescue => e
      # Metrics collection must never break a job.
      Sidekiq.logger&.warn("[roundhouse] duration collect failed: #{e.message}")
    end

    # [{ klass:, count:, total_ms:, avg_ms: }], slowest (by total time) first.
    def self.summary(limit: 20)
      raw = Sidekiq.redis { |conn| conn.call("HGETALL", KEY) }
      pairs = raw.is_a?(Hash) ? raw : raw.each_slice(2).to_a # redis-client: flat array; redis-rb: hash

      by_class = Hash.new { |h, k| h[k] = { klass: k, count: 0, total_ms: 0.0 } }
      pairs.each do |field, value|
        klass, kind = field.split("\x00", 2)
        next unless kind

        kind == "count" ? by_class[klass][:count] = value.to_i : by_class[klass][:total_ms] = value.to_f
      end

      by_class.values
              .map { |r| r.merge(avg_ms: r[:count].positive? ? r[:total_ms] / r[:count] : 0.0) }
              .sort_by { |r| -r[:total_ms] }
              .first(limit)
    end
  end
end
