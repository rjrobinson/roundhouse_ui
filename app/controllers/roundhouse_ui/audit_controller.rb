module RoundhouseUi
  class AuditController < ApplicationController
    def index
      @entries = RoundhouseUi::Audit.recent
    end
  end
end
