require "roundhouse_ui/core"
require "sidekiq/api"
require "roundhouse_ui/pause"
require "roundhouse_ui/fetch"
require "roundhouse_ui/snapshots"
require "roundhouse_ui/audit"
require "roundhouse_ui/cancellation"
require "roundhouse_ui/cancel_middleware"
require "roundhouse_ui/metrics"
require "roundhouse_ui/error_groups"
require "roundhouse_ui/duration_collector"
require "roundhouse_ui/backends/sidekiq"
require "roundhouse_ui/backends/solid_queue"

module RoundhouseUi
  class << self
    attr_writer :snapshot_store

    def snapshot_store
      @snapshot_store ||= Snapshots::RedisStore.new
    end

    def cancelled?(jid)
      Cancellation.cancelled?(jid)
    end
  end

  self.backend = Backends::Sidekiq.new
end
