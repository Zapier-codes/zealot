# frozen_string_literal: true

# Task 40r: the channel a staged upload belongs to, when the owner opened it as the FIRST upload of an app (no
# `channel_key`). The multipart door creates the app, scheme and channel from the file it parses; a staged
# upload cannot, because Zealot never reads the file (CI does). So this runs from `ReleaseUploadReleaseBuilder`
# after stage 1 has reported the package, inside the builder's transaction on the locked `release_uploads` row,
# and it makes exactly what the multipart door makes:
#
#   app      named by the owner (`form_options['name']`), else the file's label, else its package name. An app
#            of that name that already exists is reused only if the uploader may change it (`AppPolicy#update?`,
#            the rule Task 23 put on the multipart door); a new one gets the uploader as its owner and needs
#            `AppPolicy#create?`. An archived app is refused.
#   scheme   the default "Adhoc" scheme
#   channel  the app's Android channel, created from the owner's optional `slug`, `git_url` and
#            `download_filename_type`
#
#   result = ReleaseUploadAppResolver.new(row).call
#   result.channel   # the channel, already saved on the row (`channel_id`), for a created or an existing one
#   result.reason    # the refusal text; nothing is left half-made (the caller's transaction rolls back on a raise,
#                    # and this service only returns a reason after rolling its own savepoint back)
#
# Nothing here trusts the report beyond what stage 1's intake already validated (package name, label length),
# and a refusal marks nothing itself: the builder turns `reason` into a `failed` upload like any other refusal.
# The same checks run again at session time (`Api::Apps::UploadSessionsController`) so a caller who may not
# create an app finds out before sending bytes; this is the check that counts, because the user can lose the
# right (or be locked) between the session and the callback.
#
# Only the default host opens a channel-less session, so `Current.tenant` is nil here and the policies answer
# for the default catalog exactly as on the multipart door. A tenant host's first upload is not available
# through a session.
#
# Not verified: no Ruby beyond `ruby -c` in the sandbox this was written in; nothing was executed.
class ReleaseUploadAppResolver
  Result = Struct.new(:channel, :reason, keyword_init: true)

  CHANNEL_OPTION_KEYS = %w[slug git_url download_filename_type].freeze

  def initialize(upload)
    @upload = upload
  end

  # @return [Result]
  def call
    return Result.new(channel: upload.channel) if upload.channel

    reason = precondition_problem
    return Result.new(reason: reason) if reason

    resolve
  rescue ActiveRecord::RecordInvalid, ArgumentError => e
    # ArgumentError: an enum value Channel does not know (`download_filename_type`).
    Result.new(reason: "The app could not be created: #{e.message}".truncate(500))
  end

  private

  attr_reader :upload

  def user
    upload.user
  end

  def precondition_problem
    return 'This upload does not create an app (it has no channel).' unless upload.new_app?
    return 'The uploader no longer exists, so the app was not created.' if user.nil?
    return 'The uploader\'s account is locked, so the app was not created.' if user.access_locked?

    nil
  end

  # Savepoint so a refusal after the app row was written (a scheme or channel that does not validate) leaves no
  # orphan app behind; the builder's own transaction is what makes the rest of the callback atomic.
  def resolve
    result = nil
    ActiveRecord::Base.transaction(requires_new: true) do
      app, problem = find_or_create_app
      result = problem ? Result.new(reason: problem) : Result.new(channel: build_channel(app))
      raise ActiveRecord::Rollback if result.reason
    end
    attach(result.channel) if result.channel
    result
  end

  def find_or_create_app
    name = app_name
    existing = App.find_by(name: name)
    return use_existing(existing) if existing
    return [nil, "You may not create an app named #{name}."] unless AppPolicy.new(user, App.new(name: name)).create?

    app = App.create!(name: name)
    app.create_owner(user)
    [app, nil]
  end

  def use_existing(app)
    return [nil, "The app #{app.name} is archived, so it takes no uploads."] if app.archived
    return [app, nil] if AppPolicy.new(user, app).update?

    [nil, "An app named #{app.name} already exists and you may not upload to it."]
  end

  def app_name
    meta = upload.metadata
    upload.form_options['name'].presence || meta['app_label'].presence || meta['package_name'].to_s
  end

  def build_channel(app)
    scheme = app.schemes.find_or_create_by!(name: scheme_name)
    scheme.channels.find_by(device_type: :android) || scheme.channels.create!(channel_attributes)
  end

  def channel_attributes
    { name: 'android', device_type: :android }.merge(upload.form_options.slice(*CHANNEL_OPTION_KEYS).symbolize_keys)
  end

  def scheme_name
    I18n.t('api.apps.upload.create.adhoc', default: 'Adhoc')
  end

  def attach(channel)
    ReleaseUpload.where(id: upload.id, channel_id: nil).update_all(channel_id: channel.id, updated_at: Time.current)
    upload.channel = channel
  end
end
