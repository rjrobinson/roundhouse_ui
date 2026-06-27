module RoundhouseUi
  # Sidekiq 7+ capsules — isolated concurrency pools, each with its own queues.
  # Aggregated across the running processes so you can see which capsule serves
  # which queues (and answer "why isn't this queue draining?").
  class CapsulesController < ApplicationController
    def index
      @capsules = aggregate
    end

    private

    def aggregate
      capsules = Hash.new { |h, k| h[k] = { name: k, concurrency: 0, processes: 0, queues: {} } }

      Sidekiq::ProcessSet.new.each do |process|
        (process.capsules || {}).each do |name, data|
          cap = capsules[name]
          cap[:concurrency] += data["concurrency"].to_i
          cap[:processes]   += 1
          (data["weights"] || {}).each { |queue, weight| cap[:queues][queue] = weight }
        end
      end

      capsules.values.sort_by { |c| c[:name] }
    end
  end
end
