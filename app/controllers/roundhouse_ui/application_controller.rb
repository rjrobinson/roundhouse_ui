require "securerandom"

module RoundhouseUi
  class ApplicationController < ActionController::Base
    # Isolated engines don't auto-include the host's helpers; include ours.
    helper ObservabilityHelper
    helper NavHelper
    helper TagsHelper
    helper_method :content_nonce

    # Forgery protection, shipped rather than inherited. ActionController::Base
    # only carries this because the host's `config.load_defaults` (5.2+) put it
    # there, so an app on older defaults mounts a console where every
    # destructive POST is forgeable — while our own README promises the
    # opposite. Same argument as the CSP below: the engine states its security
    # posture instead of hoping the host set one. AssetsController opts out,
    # deliberately and in writing.
    protect_from_forgery with: :exception

    # Self-contained CSP, set per-request on our own responses so Roundhouse is
    # safe to mount even when the host sets no policy — and never weakens one it
    # does (this header only applies to engine responses). Strict default; we
    # enumerate exactly what our pages use (same-origin only, nonce'd inline JS).
    after_action :set_content_security_policy

    # Read-only enforcement, fail closed. Every POST is treated as a write unless
    # its controller says otherwise, so a destructive action added tomorrow is
    # guarded the moment it exists rather than the moment someone remembers a
    # before_action. This used to be seven near-identical `require_writable!`
    # methods, each wired to a hand-maintained `only:` list — all seven correct,
    # and all seven one omission away from silently not being.
    #
    # `guard_in_read_only` covers the dry-run GETs: a preview shows what a bulk
    # action would do, and is gated with the action it previews.
    class_attribute :read_only_exempt_actions, default: [].freeze, instance_writer: false
    class_attribute :read_only_extra_actions,  default: [].freeze, instance_writer: false

    def self.allow_in_read_only(*actions)
      self.read_only_exempt_actions = actions.map(&:to_s).freeze
    end

    def self.guard_in_read_only(*actions)
      self.read_only_extra_actions = actions.map(&:to_s).freeze
    end

    before_action :require_writable!, if: :read_only_guarded_action?

    # Record every state-changing (POST) action. Actions halted by a
    # before_action (e.g. read-only mode) never reach here, so we only log what
    # actually ran.
    AUDIT_VERBS = {
      "purge" => "purged queue", "pause" => "paused queue", "resume" => "resumed queue",
      "snapshot" => "snapshotted queue", "requeue" => "retried", "destroy" => "deleted",
      "bulk" => "bulk action", "enqueue" => "enqueued now", "restore" => "restored snapshot",
      "quiet" => "quieted process", "stop" => "stopped process",
      "create" => "enqueued job", "update" => "edited & re-enqueued",
      "cancel" => "requested cancel"
    }.freeze

    after_action :record_audit_event, if: -> { request.post? }

    # Use 303 See Other after POSTs so Turbo treats form submissions as redirects
    # (and visits the target in place) instead of re-issuing the POST.
    def redirect_to(options = {}, response_options = {})
      response_options[:status] ||= :see_other if request.post?
      super
    end

    private

    # The queue backend (Sidekiq by default). Controllers read through this
    # rather than naming Sidekiq directly. See ADR 0001.
    def backend
      RoundhouseUi.backend
    end

    def read_only_guarded_action?
      return false if self.class.read_only_exempt_actions.include?(action_name)

      request.post? || self.class.read_only_extra_actions.include?(action_name)
    end

    def require_writable!
      return unless RoundhouseUi.read_only

      redirect_to read_only_redirect_path,
                  alert: "Roundhouse is in read-only mode — this action is disabled."
    end

    # Where someone lands when a write is refused. The buttons still render in
    # read-only mode, so this fires on an ordinary click and the destination is
    # worth getting right; sections override it to send you back where you were.
    def read_only_redirect_path
      root_path
    end

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
