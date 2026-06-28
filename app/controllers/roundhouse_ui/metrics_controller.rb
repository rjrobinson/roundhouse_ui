module RoundhouseUi
  # Derived metrics, kept off the dashboard so the at-a-glance view stays lean.
  class MetricsController < ApplicationController
    def show
      @metrics = Metrics.new
    end
  end
end
