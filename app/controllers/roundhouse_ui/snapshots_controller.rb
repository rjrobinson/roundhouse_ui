module RoundhouseUi
  class SnapshotsController < ApplicationController
    # Snapshots read Sidekiq's queues through Redis. On a backend without either they
    # captured zero jobs and said "Snapshot saved" — beside a Purge telling you to
    # snapshot first.
    requires_capability :snapshots, only: %i[index show restore destroy create]
    def index
      @snapshots = RoundhouseUi::Snapshots.all
    end

    def restore
      count = RoundhouseUi::Snapshots.restore(params[:id])
      redirect_to snapshots_path, notice: "Restored #{count} job(s) to their queue."
    end

    def destroy
      RoundhouseUi::Snapshots.delete(params[:id])
      redirect_to snapshots_path, notice: "Snapshot deleted."
    end

    private

    def read_only_redirect_path = snapshots_path
  end
end
