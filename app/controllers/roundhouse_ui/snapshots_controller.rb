module RoundhouseUi
  class SnapshotsController < ApplicationController
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
