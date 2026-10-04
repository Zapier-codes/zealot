# frozen_string_literal: true

# Task 40h-a: the staging record of an upload that has been asked for but is not a `Release` yet (decided Task
# 40 flow). The authenticated owner asks for an upload (40h-b), the bytes go straight to the R2 staging bucket
# through a presigned URL (`ReleaseUploadStaging`), CI reads the file, and only then does the callback create
# the real `Release` (40i-b). Until then nothing about the file is trusted, and the release list, the catalog
# index and the download routes never see this row.
#
# This slice is the record and its rules only: it creates the row, picks the staging key and the window the
# client has to upload in. The state transitions are written by the slices that perform them (finalize in 40h-b,
# the CI callbacks in 40i), each as a conditional update, so none of them is invented here.
#
#   awaiting_bytes  asked for; the client has not finished (or not started) sending the file
#   uploaded        finalize saw the object in staging with the declared size and dispatched CI
#   processing      CI called back with the parsed metadata and the release exists, held
#   done            CI finished; the release is available (unless the uploader asked to hold it)
#   failed          a check refused it, CI failed, or the sweeper gave up; the reason is in `error`
#   expired         never got its bytes inside the window
#
# Not verified: no Ruby run beyond `ruby -c` in the sandbox this was written in; nothing was executed.
class ReleaseUpload < ApplicationRecord
  STATES = %w[awaiting_bytes uploaded processing failed expired done].freeze

  # GitHub release assets must be under 2 GiB and the staged file ends up in one, so larger declarations are
  # refused up front (the decided flow's cap). R2's own single-PUT limit (5 GiB) is not the binding one.
  MAX_BYTES = (2 * 1024**3) - 1

  # How long the client has to send the bytes. The presigned URL's life is the same (see
  # `ReleaseUploadStaging::DEFAULT_EXPIRES_IN`); an `awaiting_bytes` row past this is the sweeper's to expire.
  UPLOAD_WINDOW = 2.hours

  MAX_FILENAME_BASE = 120
  MAX_FILENAME_EXT = 16

  belongs_to :channel
  belongs_to :user, optional: true
  belongs_to :release, optional: true

  enum :state, STATES.index_with(&:itself), prefix: true

  before_validation :sanitize_filename
  before_validation :set_expiry, on: :create
  after_create :assign_staging_key

  validates :filename, presence: true
  validates :declared_size, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: MAX_BYTES }
  validates :content_type, length: { maximum: 255 }, allow_blank: true
  validate :form_options_is_a_hash

  # Rows still waiting for bytes after their window closed: what the sweeper (gap H) expires.
  scope :stale_awaiting, ->(now = Time.current) { state_awaiting_bytes.where(expires_at: ...now) }

  def app
    channel.scheme.app
  end

  # True while the client may still send the bytes.
  def window_open?(now = Time.current)
    state_awaiting_bytes? && expires_at.present? && expires_at > now
  end

  private

  # The client's file name is only a label for the staging key and the download name later, never a path:
  # directories and anything outside letters, digits, dot, dash and underscore are dropped or replaced.
  def sanitize_filename
    return if filename.blank?

    base = File.basename(filename.to_s.tr('\\', '/'))
    ext = File.extname(base)
    stem = File.basename(base, ext).gsub(/[^A-Za-z0-9._-]/, '_').sub(/\A\.+/, '')[0, MAX_FILENAME_BASE]
    self.filename = "#{stem}#{ext.gsub(/[^A-Za-z0-9.]/, '_')[0, MAX_FILENAME_EXT]}"
    self.filename = nil if stem.blank?
  end

  def set_expiry
    self.expires_at ||= Time.current + UPLOAD_WINDOW
  end

  # Needs the row's id, so it is written right after the insert. A random segment keeps the key unguessable
  # even for someone who knows the app and upload ids. The unique index on `staging_key` is the backstop.
  def assign_staging_key
    update_columns(staging_key: "staging/a#{app.id}/u#{id}/#{SecureRandom.hex(16)}/#{filename}")
  end

  def form_options_is_a_hash
    errors.add(:form_options, :invalid) unless form_options.is_a?(Hash)
  end
end
