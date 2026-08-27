module RoundhouseUi
  class AuditController < ApplicationController
    requires_capability :redis, only: %i[index]
    def index
      @entries = RoundhouseUi::Audit.recent
    end
  end
end
