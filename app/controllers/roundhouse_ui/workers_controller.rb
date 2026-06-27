module RoundhouseUi
  # The running Sidekiq process fleet, straight from Sidekiq::ProcessSet.
  # "Quiet" stops a process from pulling new work; "Stop" begins shutdown.
  class WorkersController < ApplicationController
    before_action :require_writable!, only: %i[quiet stop]

    def index
      @processes = Sidekiq::ProcessSet.new.to_a
      @fetch_active = RoundhouseUi::Pause.fetch_installed?
    end

    def quiet
      find_process(params[:identity])&.quiet!
      redirect_to workers_path, notice: "Sent quiet to #{params[:identity]}."
    end

    def stop
      find_process(params[:identity])&.stop!
      redirect_to workers_path, notice: "Sent stop to #{params[:identity]}."
    end

    private

    def find_process(identity)
      Sidekiq::ProcessSet.new.find { |process| process.identity == identity }
    end

    def require_writable!
      return unless RoundhouseUi.read_only
      redirect_to workers_path, alert: "Roundhouse is in read-only mode — quiet and stop are disabled."
    end
  end
end
