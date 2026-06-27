require "json"
require "sidekiq"

module RoundhouseUi
  # An append-only audit trail of state-changing actions, kept in a capped Redis
  # list. Answers "who purged that queue?" — the accountability Sidekiq Web lacks.
  module Audit
    KEY = "roundhouse:audit"
    MAX = 1_000

    module_function

    def record(actor:, action:, target:)
      entry = JSON.dump("actor" => actor.to_s, "action" => action.to_s, "target" => target.to_s, "at" => Time.now.to_f)
      Sidekiq.redis do |conn|
        conn.call("LPUSH", KEY, entry)
        conn.call("LTRIM", KEY, 0, MAX - 1)
      end
    end

    def recent(limit = 200)
      Sidekiq.redis { |conn| conn.call("LRANGE", KEY, 0, limit - 1) }.map { |raw| JSON.parse(raw) }
    end
  end
end
