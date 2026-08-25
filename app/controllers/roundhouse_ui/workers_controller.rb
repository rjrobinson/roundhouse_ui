module RoundhouseUi
  # The running Sidekiq process fleet, straight from Sidekiq::ProcessSet.
  # "Quiet" stops a process from pulling new work; "Stop" begins shutdown.
  class WorkersController < ApplicationController
    def index
      @processes = backend.process_set.to_a
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

    def read_only_redirect_path = workers_path

    def find_process(identity)
      backend.process_set.find { |process| process.identity == identity }
    end
  end
end
