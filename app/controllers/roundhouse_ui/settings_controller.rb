module RoundhouseUi
  # Per-viewer preferences. Everything here is stored in the browser and applied
  # client-side — nothing is written server-side, so one operator's choices never
  # change what anyone else sees, and there is no state to migrate or clean up.
  #
  # The server's only job is to say what is on offer: which palettes exist, and
  # what the host defaults are when a viewer has expressed no preference.
  class SettingsController < ApplicationController
    def show
      @palettes = Theme.selectable
      @host_poll = RoundhouseUi.poll_interval
      @host_theme = RoundhouseUi.theme.present?
    end
  end
end
