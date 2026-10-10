# frozen_string_literal: true

# Z-P12 (Play Console parity): the one door through which the pre-launch CI workflow reports back. The workflow
# runs the build on redroid (`docs/ci/pre-launch-runner.py`), then POSTs the JSON payload here for one release.
#
# Authentication is a shared secret only (`PRE_LAUNCH_CALLBACK_TOKEN`, sent as `Authorization: Bearer <token>`),
# the same door Task 40a uses for the compile workflow: the caller is a workflow, not a person. If the variable
# is unset, every call is refused (never open by default).
#
# The body is the runner's payload (see PreLaunchReport.from_payload). It is NOT trusted to be well-formed: the
# pure half tolerates a missing section, and the whole thing is recorded as the verdict. An idempotent repeat
# for a release already `done` answers 200 and writes nothing. A callback in a state that cannot accept one is
# refused with 409.
class Api::PreLaunchReportsController < Api::BaseController
  OPEN_STATES = %w[not_run running failed].freeze
  # The runner's payload, permitted as a whole: arrays of hashes for the observations and one hash for startup.
  PERMITTED = [
    :events,
    devices: %i[name api_level abi],
    startup: %i[ok message],
    crashes: %i[device message reason type],
    anrs: %i[device message reason type],
    exceptions: %i[device message reason type]
  ].freeze

  before_action :authenticate_callback!

  # POST /api/pre_launch_reports/:id
  #
  #   { "devices": [{"name": "localhost:9100"}], "events": 2000,
  #     "crashes": [{"device": "...", "message": "FATAL EXCEPTION ..."}],
  #     "anrs": [...], "exceptions": [...], "startup": {"ok": true, "message": ""} }
  def create
    release = Release.find_by(id: params[:id])
    return render json: { error: 'Unknown release' }, status: :not_found if release.nil?
    return refuse_state(release) unless OPEN_STATES.include?(release.pre_launch_status)

    payload = payload_hash
    ReleaseChecks::PreLaunchRecorder.record!(release, status: 'done', payload: payload)
    render json: { message: 'OK' }, status: :ok
  end

  private

  def payload_hash
    permitted = params.permit(*PERMITTED).to_h
    # `permit` returns ActionController::Parameters nested; unwrap to plain hashes the pure half can read.
    JSON.parse(permitted.to_json)
  end

  def refuse_state(release)
    render json: { error: "A pre-launch report for a release that is '#{release.pre_launch_status}' is refused" },
           status: :conflict
  end

  def authenticate_callback!
    expected = ENV['PRE_LAUNCH_CALLBACK_TOKEN'].to_s
    supplied = request.authorization.to_s.sub(/\ABearer\s+/i, '')
    return if expected.present? && supplied.present? && same_secret?(expected, supplied)

    render json: { error: 'Unauthorized' }, status: :unauthorized
  end

  # Compares digests, so the comparison is constant-time whatever the lengths are.
  def same_secret?(left, right)
    ActiveSupport::SecurityUtils.secure_compare(
      ::Digest::SHA256.hexdigest(left), ::Digest::SHA256.hexdigest(right)
    )
  end
end
