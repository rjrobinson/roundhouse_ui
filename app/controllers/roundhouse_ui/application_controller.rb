require "securerandom"

module RoundhouseUi
  class ApplicationController < ActionController::Base
    # Isolated engines don't auto-include the host's helpers; include ours.
    helper ObservabilityHelper
    helper NavHelper
    helper_method :content_nonce

    # Self-contained CSP, set per-request on our own responses so Roundhouse is
    # safe to mount even when the host sets no policy — and never weakens one it
    # does (this header only applies to engine responses). Strict default; we
    # enumerate exactly what our pages use (same-origin only, nonce'd inline JS).
    after_action :set_content_security_policy

    # Record every state-changing (POST) action. Actions halted by a
    # before_action (e.g. read-only mode) never reach here, so we only log what
    # actually ran.
    AUDIT_VERBS = {
      "purge" => "purged queue", "pause" => "paused queue", "resume" => "resumed queue",
      "snapshot" => "snapshotted queue", "requeue" => "retried", "destroy" => "deleted",
      "bulk" => "bulk action", "enqueue" => "enqueued now", "restore" => "restored snapshot",
      "quiet" => "quieted process", "stop" => "stopped process",
      "create" => "enqueued job", "update" => "edited & re-enqueued"
    }.freeze

    after_action :record_audit_event, if: -> { request.post? }

    # Use 303 See Other after POSTs so Turbo treats form submissions as redirects
    # (and visits the target in place) instead of re-issuing the POST.
    def redirect_to(options = {}, response_options = {})
      response_options[:status] ||= :see_other if request.post?
      super
    end

    private

    def record_audit_event
      target = params[:name] || params[:jid] || params[:id] || params[:job_class] ||
               (params[:jids].presence && "#{Array(params[:jids]).size} jobs") || params[:op]
      RoundhouseUi::Audit.record(
        actor:  current_actor,
        action: AUDIT_VERBS[action_name] || "#{controller_name}##{action_name}",
        target: target
      )
    rescue => e
      Rails.logger.warn("[roundhouse] audit failed: #{e.message}")
    end

    def current_actor
      resolver = RoundhouseUi.actor_resolver
      (resolver && resolver.call(self)) || "anonymous"
    rescue
      "anonymous"
    end

    # Memoized so the value rendered into the <script> tag matches the header.
    def content_nonce
      @content_nonce ||= SecureRandom.base64(16)
    end

    def set_content_security_policy
      response.headers["Content-Security-Policy"] = [
        "default-src 'none'",
        "script-src 'self' 'nonce-#{content_nonce}'",
        "style-src 'self' 'unsafe-inline'",
        "connect-src 'self'",
        "img-src 'self' data:",
        "form-action 'self'",
        "base-uri 'self'"
      ].join("; ")
    end
  end
end
