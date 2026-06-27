require "json"
require "sidekiq/api"

module RoundhouseUi
  # Back up a queue's jobs before you purge it, and restore them later — the
  # safety net that makes clearing a stuck queue non-destructive.
  #
  # Storage is pluggable via RoundhouseUi.snapshot_store. The default RedisStore
  # keeps blobs in Redis (simple, dependency-free); for large/stuck queues you'll
  # want a file or S3 store so the backup doesn't sit in the same Redis you're
  # trying to relieve. Any object responding to write/read/delete/ids works.
  module Snapshots
    module_function

    def store
      RoundhouseUi.snapshot_store
    end

    # Copy every job currently on `queue_name` into a snapshot. Non-destructive —
    # the queue is left untouched (purge separately if you want to clear it).
    def take(queue_name)
      payloads = []
      Sidekiq::Queue.new(queue_name).each { |job| payloads << job.value }

      id = "#{queue_name}-#{Time.now.to_i}-#{rand(10_000)}"
      store.write(id, JSON.dump(
        "queue" => queue_name, "created_at" => Time.now.to_f, "count" => payloads.size, "jobs" => payloads
      ))
      metadata(id)
    end

    def all
      store.ids.filter_map { |id| metadata(id) }.sort_by { |m| -m[:created_at].to_f }
    end

    def metadata(id)
      raw = store.read(id)
      return nil unless raw

      data = JSON.parse(raw)
      { id: id, queue: data["queue"], count: data["count"] || data["jobs"].size, created_at: data["created_at"] }
    end

    # Re-enqueue a snapshot's jobs onto their original queue. Returns the count.
    def restore(id)
      raw = store.read(id)
      return 0 unless raw

      data = JSON.parse(raw)
      key = "queue:#{data["queue"]}"
      data["jobs"].each { |payload| Sidekiq.redis { |conn| conn.call("RPUSH", key, payload) } }
      data["jobs"].size
    end

    def delete(id)
      store.delete(id)
    end

    # Default store: blobs + an index set, all in Redis.
    class RedisStore
      INDEX = "roundhouse:snapshots"

      def write(id, blob)
        Sidekiq.redis do |conn|
          conn.call("SET", key(id), blob)
          conn.call("SADD", INDEX, id)
        end
      end

      def read(id)
        Sidekiq.redis { |conn| conn.call("GET", key(id)) }
      end

      def delete(id)
        Sidekiq.redis do |conn|
          conn.call("DEL", key(id))
          conn.call("SREM", INDEX, id)
        end
      end

      def ids
        Sidekiq.redis { |conn| conn.call("SMEMBERS", INDEX) }
      end

      private

      def key(id) = "roundhouse:snapshot:#{id}"
    end
  end
end
