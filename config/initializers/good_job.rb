# frozen_string_literal: true

CRON_JOBS_SETUP = lambda do
  cron_jobs = {
    sync_apple_devices: {
      cron: '0 0 * * *',
      class: 'SyncAppleDevicesJob',

      description: 'Syncing devices for all Apple Developers on each 0AM',
    },
    clean_old_releases: {
      cron: '0 6 * * *',
      class: 'CleanOldReleasesJob',
      description: 'Clean old versions on each 6AM',
    },
    reset_for_demo_mode: {
      cron: '0 0 * * *',
      class: 'ResetForDemoModeJob',
      description: 'Reset demo data everyday'
    },
    anthropic_play_approval_expiry: {
      cron: '*/15 * * * *',
      class: 'AnthropicPlayApprovalExpiryJob',
      description: 'Auto-expire Play Store publish-approval requests older than 48h'
    },
    anthropic_play_setup_recheck: {
      cron: '*/10 * * * *',
      class: 'AnthropicPlaySetupRecheckJob',
      description: 'Re-check Play Console setup for apps with releases waiting on it and resume their publish'
    }
  }

  cron_jobs.delete(:clean_old_releases) if Setting.keep_uploads
  cron_jobs.delete(:reset_for_demo_mode) unless Setting.demo_mode

  begin
    Backup.enabled_jobs.each do |backup|
      cron_jobs[backup.schedule_key] = backup.schedule_job
    end
  rescue ActiveRecord::ConnectionNotEstablished
    # ignore, maybe executing `rails assets:precompile`
  end

  cron_jobs
end

Rails.application.reloader.to_prepare do
  Rails.application.configure do
    # Both the web (Puma) process and the dedicated job-worker process
    # (`bin/good_job`, see docker/rootfs/etc/services.d/job/run) load this
    # same initializer. Previously `execution_mode` and `enable_cron` were
    # unconditional, so BOTH processes independently ran a GoodJob
    # scheduler (up to max_threads each) and BOTH registered the same cron
    # jobs — visible in production logs as repeated "Failed enqueuing ...
    # a before_enqueue callback halted the enqueuing execution" (GoodJob's
    # own advisory-lock safety valve catching the two processes racing to
    # enqueue the same cron job). On a memory-constrained instance (Render
    # free tier, 512Mi) this duplicate scheduler + duplicate cron polling
    # was a real contributor to repeated OOM kills. Only the worker process
    # sets ZEALOT_JOB_WORKER=true, so only it now runs the scheduler/cron;
    # the web process still enqueues jobs normally, it just doesn't also
    # execute/poll for them itself.
    is_job_worker = ActiveModel::Type::Boolean.new.cast(ENV['ZEALOT_JOB_WORKER'])

    config.good_job.dashboard_default_locale = I18n.default_locale
    config.good_job.preserve_job_records = true
    config.good_job.retry_on_unhandled_error = false
    config.good_job.on_thread_error = -> (exception) { Rails.error.report(exception) }
    config.good_job.execution_mode = is_job_worker ? :async : :external
    config.good_job.queues = '*'
    config.good_job.max_threads = (ENV['ZEALOT_WORKER_CONCURRENCY'] || '5').to_i
    config.good_job.poll_interval = (ENV['ZEALOT_WORKER_POLL_INTERVAL'] || '30').to_i
    config.good_job.shutdown_timeout = (ENV['ZEALOT_WORKER_SHUTDOWN_TIMEOUT'] || '30').to_i

    begin
      config.good_job.enable_cron = is_job_worker
      config.good_job.cron = CRON_JOBS_SETUP.call if is_job_worker
    rescue ActiveRecord::StatementInvalid
      # initialize zealot, ignore
    end
  end
end

ActiveSupport.on_load(:good_job_application_controller) do
  content_security_policy do |policy|
    policy.frame_ancestors(:self)
  end
end
