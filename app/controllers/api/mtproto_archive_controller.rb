# frozen_string_literal: true

# Task 19f: Rails' half of moving the Telegram MTProto cold-storage archive
# (task #6) off the always-on mtproto-worker sidecar and onto a scheduled
# GitHub Actions batch. Rails no longer holds an HTTP client to a live
# worker process (that was Anthropic::MtprotoArchiveService, removed this
# slice, and AnthropicMtprotoArchiveJob's cron scan, also removed — see
# handover.md Task 19f). Instead this controller is the entire interface
# between the two: it tells the external script what to archive (with a
# signed, time-limited download URL so the script never needs Rails
# credentials to fetch the actual bytes — see ReleaseStorage#url_for) and
# records what it did once it's done. All the MTProto work itself (the
# Telegram handshake, chunked upload, retry/backoff) lives entirely in
# mtproto-worker/src/archive_batch.ts now, run by
# .github/workflows/mtproto_archive.yml — Rails never talks to Telegram.
#
# Token-authenticated (the same `?token=` param every other /api resource
# uses) and admin-only, same posture Task 17 established for
# Api::PlayCredentialsController and for the same reason: this is an /api
# controller, so nothing upstream of Pundit restricts it to admins the way
# the session-authenticated admin namespace is gated at the routing level.
# See MtprotoArchivePolicy for why an explicit policy_class: is needed here
# (this isn't backed by an ActiveRecord model the way PlayCredential is).
class Api::MtprotoArchiveController < Api::BaseController
  before_action :validate_user_token
  before_action :authorize_admin

  # Same defaults/knobs AnthropicMtprotoArchiveJob used before this slice —
  # see handover.md Task 19f. Kept identical so operators don't need to
  # re-learn or re-set these when the job disappears.
  DEFAULT_AFTER_DAYS = 90
  DEFAULT_MIN_BYTES = 50 * 1024 * 1024
  DEFAULT_BATCH_SIZE = 25

  # GET /api/mtproto_archive/candidates
  #
  # Our own release artifacts only (see handover.md's "Scope, stated
  # plainly" note on task #6): releases already compressed by the PAD
  # pipeline and stored in ReleaseStorage, old enough and big enough to be
  # worth archiving, not already archived. MTPROTO_ARCHIVE_ENABLED is the
  # Rails-side kill switch independent of whether the GitHub Actions
  # schedule itself is enabled/disabled — flipping it off here immediately
  # stops new candidates being handed out even if the workflow still runs.
  def candidates
    return render json: { candidates: [] } unless archive_enabled?

    render json: { candidates: eligible_releases.map { |release| candidate_json(release) } }
  end

  # POST /api/mtproto_archive/:id/complete
  #
  # Called once per successfully archived release by the worker script,
  # with the opaque location string MtprotoClient#archive returned
  # (encoded via encodeLocation in mtproto_client.ts — see that file).
  # Best-effort on the worker's side already (it logs and moves on to the
  # next candidate on failure, same posture the old job had); this endpoint
  # itself is a plain update, no retry logic needed here.
  def complete
    location = params[:location].to_s
    raise ActionController::ParameterMissing, :location if location.blank?

    release = Release.find(params[:id])
    release.update!(mtproto_archived_location: location, mtproto_archived_at: Time.current)
    render json: { message: 'OK' }, status: :ok
  end

  private

  def authorize_admin
    authorize :mtproto_archive, "#{action_name}?".to_sym, policy_class: MtprotoArchivePolicy
  end

  def eligible_releases
    Release
      .where(mtproto_archived_at: nil)
      .where.not(compressed_apks_storage_key: nil)
      .where('created_at < ?', after_days.days.ago)
      .where('compressed_size >= ?', min_bytes)
      .limit(batch_size)
  end

  def candidate_json(release)
    key = release.compressed_apks_storage_key
    {
      release_id: release.id,
      key: key,
      # Short-lived signed URL (ReleaseStorage#url_for, default 1h expiry) —
      # the worker script must download promptly; a run that takes longer
      # than the expiry to reach a given candidate should just let that
      # download fail and pick it up again next scheduled run rather than
      # Rails handing out a long-lived credential.
      download_url: ReleaseStorage.new(release).url_for(key),
      compressed_size: release.compressed_size,
      created_at: release.created_at
    }
  end

  def archive_enabled?
    ENV['MTPROTO_ARCHIVE_ENABLED'] == 'true'
  end

  def after_days
    (ENV['MTPROTO_ARCHIVE_AFTER_DAYS'] || DEFAULT_AFTER_DAYS).to_i
  end

  def min_bytes
    (ENV['MTPROTO_ARCHIVE_MIN_BYTES'] || DEFAULT_MIN_BYTES).to_i
  end

  def batch_size
    (ENV['MTPROTO_ARCHIVE_BATCH_SIZE'] || DEFAULT_BATCH_SIZE).to_i
  end
end
