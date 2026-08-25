module RoundhouseUi
  # Periodic work, whichever scheduler defines it. Read-only: the schedule
  # belongs in the code that declares it, and a UI that silently changes a
  # production schedule is a different risk conversation. See #62.
  class RecurringController < ApplicationController
    def index
      @tasks = Recurring.tasks
      @sources = @tasks.map(&:source).uniq
      @overdue = @tasks.count { |t| t.status == :overdue }
    end
  end
end
