module RoundhouseUi
  # Serves the vendored Turbo build same-origin so it passes the engine's CSP
  # (script-src 'self') without a build step or asset pipeline.
  class AssetsController < ApplicationController
    # It's a public static asset — Rails' cross-origin-JS forgery guard would
    # otherwise 422 the <script src> request.
    skip_forgery_protection

    TURBO_PATH = RoundhouseUi::Engine.root.join("app/assets/javascripts/roundhouse_ui/turbo.min.js").freeze

    def turbo
      response.headers["Cache-Control"] = "public, max-age=31536000, immutable"
      send_file TURBO_PATH, type: "text/javascript", disposition: "inline"
    end
  end
end
