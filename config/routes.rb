RoundhouseUi::Engine.routes.draw do
  root to: "dashboard#show"
  get "stats" => "dashboard#stats", as: :dashboard_stats # JSON, polled for live updates
  get "turbo.js" => "assets#turbo", as: :turbo_js        # vendored Turbo, served same-origin
  get "metrics" => "metrics#show", as: :metrics          # derived metrics (separate from the live dashboard)

  get  "busy" => "busy#index", as: :busy
  post "busy/:jid/cancel" => "busy#cancel", as: :cancel_job, constraints: { jid: /[^\/]+/ }
  get  "workers" => "workers#index", as: :workers
  post "workers/quiet" => "workers#quiet", as: :quiet_worker
  post "workers/stop"  => "workers#stop",  as: :stop_worker

  get "queues" => "queues#index", as: :queues
  # Queue names can contain dots/colons, so allow anything but a slash.
  scope constraints: { name: /[^\/]+/ } do
    post "queues/:name/purge"    => "queues#purge",    as: :purge_queue
    post "queues/:name/pause"    => "queues#pause",    as: :pause_queue
    post "queues/:name/resume"   => "queues#resume",   as: :resume_queue
    post "queues/:name/snapshot" => "queues#snapshot", as: :snapshot_queue
  end

  get "snapshots" => "snapshots#index", as: :snapshots
  scope constraints: { id: /[^\/]+/ } do
    post "snapshots/:id/restore" => "snapshots#restore", as: :restore_snapshot
    post "snapshots/:id/delete"  => "snapshots#destroy", as: :delete_snapshot
  end

  get  "scheduled" => "scheduled#index", as: :scheduled
  post "scheduled/:jid/enqueue" => "scheduled#enqueue", as: :enqueue_scheduled
  post "scheduled/:jid/delete"  => "scheduled#destroy", as: :delete_scheduled

  get  "retries" => "retries#index", as: :retries
  post "retries/bulk_all"    => "retries#bulk_all", as: :bulk_all_retries
  post "retries/:jid/run"    => "retries#requeue", as: :run_retry
  post "retries/:jid/delete" => "retries#destroy", as: :delete_retry

  get  "dead" => "dead#index", as: :dead_set
  post "dead/bulk"        => "dead#bulk",      as: :bulk_dead
  post "dead/bulk_all"    => "dead#bulk_all",  as: :bulk_all_dead
  post "dead/:jid/retry"  => "dead#requeue",   as: :retry_dead_job
  post "dead/:jid/delete" => "dead#destroy",   as: :delete_dead_job

  get "errors" => "errors#index", as: :errors
  get "capsules" => "capsules#index", as: :capsules
  get "redis"  => "redis#show", as: :redis_info
  get "audit"  => "audit#index", as: :audit_log

  # Job editing / enqueue (opt-in via RoundhouseUi.allow_job_editing)
  get  "jobs/new" => "jobs#new",    as: :new_job
  post "jobs"     => "jobs#create", as: :jobs
  scope constraints: { set: /dead|retry|scheduled/, jid: /[^\/]+/ } do
    get  "jobs/:set/:jid/edit" => "jobs#edit", as: :edit_job
    get  "jobs/:set/:jid"      => "jobs#show"           # read-only inspect (job_path)
    post "jobs/:set/:jid"      => "jobs#update", as: :job
  end
end
