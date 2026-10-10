# frozen_string_literal: true

# Z-P11 (Play Console parity, docs/PARITY-KANBAN.md): trained-upgrade mapping / native symbol upload.
#
# Play Console wants the R8/ProGuard `mapping.txt` (and, for apps with native code, the native debug
# symbols) uploaded beside a release so it can de-obfuscate the crashes a later vitals feed reports. This
# is that store. One row per (release, kind); replacing a mapping replaces the row rather than appending,
# because a release has exactly one mapping per kind in Play too.
#
# The file keeps the release's own deobfuscation material and nothing else: the checksum is stored so a
# re-upload of the same bytes is a no-op and a reader can prove the file it fetched is the file uploaded.
class DebugSymbol < ApplicationRecord
  KINDS = %w[mapping native_symbols].freeze

  # A cap so a mistaken multi-gigabyte upload is refused at the model, not after the disk is full.
  MAX_FILE_SIZE = 300.megabytes

  mount_uploader :file, DebugSymbolUploader

  belongs_to :app
  belongs_to :release

  validates :kind, inclusion: { in: KINDS }
  validates :release_id, uniqueness: { scope: :kind }
  validates :file, presence: true
  validate :file_size_within_cap

  before_validation :generate_checksum

  scope :for_tenant, ->(tenant) { joins(:app).where(apps: { tenant_id: tenant&.id }) }

  # The mapping file Play Console's "deobfuscation file" field expects, newest first (there is one).
  def self.mapping_for(release)
    where(release: release, kind: 'mapping').order(id: :desc).first
  end

  def native?
    kind == 'native_symbols'
  end

  def download_filename
    base = File.basename(file.file.filename.to_s)
    "#{app.name}-#{release.release_version}-#{release.build_version}-#{kind}-#{base}"
  end

  private

  def file_size_within_cap
    size = file&.size
    return if size.blank? || size <= MAX_FILE_SIZE

    errors.add(:file, I18n.t('activerecord.errors.models.debug_symbol.attributes.file.too_large'))
  end

  def generate_checksum
    self.checksum = file.checksum if file.present?
  end
end
