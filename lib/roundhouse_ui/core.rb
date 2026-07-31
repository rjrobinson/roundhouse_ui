require "roundhouse_ui/version"
require "rails"
require "roundhouse_ui/engine"
require "roundhouse_ui/observability"
require "roundhouse_ui/redaction"
require "roundhouse_ui/health"

module RoundhouseUi
  class << self
    attr_accessor :read_only, :actor_resolver, :allow_job_editing, :redact_args,
      :show_sidekiq_failures, :collect_durations, :poll_interval, :pause_enabled
    attr_writer :backend, :observability

    def configure
      yield self
    end

    def backend
      @backend ||= Backends::Sidekiq.new
    end

    def observability
      @observability ||= Observability::NullAdapter.new
    end
  end

  self.read_only = false
  self.allow_job_editing = false
  self.redact_args = []
  self.show_sidekiq_failures = false
  self.pause_enabled = true
  self.poll_interval = 5
  self.collect_durations = false
end
