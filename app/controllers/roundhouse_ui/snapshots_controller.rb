module RoundhouseUi
  class SnapshotsController < ApplicationController
    before_action :require_writable!, only: %i[restore destroy]

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

    def require_writable!
      return unless RoundhouseUi.read_only
      redirect_to snapshots_path, alert: "Roundhouse is in read-only mode — restore and delete are disabled."
    end
  end
end
