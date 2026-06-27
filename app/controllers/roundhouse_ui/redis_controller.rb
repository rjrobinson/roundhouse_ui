module RoundhouseUi
  # Redis health from INFO — the "is Redis about to silently drop my jobs?" view
  # that Sidekiq Web doesn't have. The headline signal: an eviction policy other
  # than noeviction (with a memory cap) means Sidekiq data can be evicted.
  class RedisController < ApplicationController
    def show
      @info = parse_info(Sidekiq.redis { |conn| conn.call("INFO") })
    end

    private

    def parse_info(raw)
      raw.to_s.each_line.each_with_object({}) do |line, info|
        line = line.strip
        next if line.empty? || line.start_with?("#")
        key, value = line.split(":", 2)
        info[key] = value if key && value
      end
    end
  end
end
