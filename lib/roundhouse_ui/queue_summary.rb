module RoundhouseUi
  # One row of the Queues page: name, depth, and how long the oldest waiting job
  # has been waiting. A plain value object rather than a backend's own Queue,
  # because the backends compute these in one batch — Sidekiq in a single
  # pipeline, Solid Queue in a single grouped query — and handing back live
  # objects invites the caller to re-read per row and undo that.
  #
  # `latency` is seconds. Actions (pause, purge, snapshot) still go through
  # backend.queue(name); this carries no behaviour.
  QueueSummary = Struct.new(:name, :size, :latency, keyword_init: true)
end
