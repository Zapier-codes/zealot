# frozen_string_literal: true

# Task 40s-a: the part size of a multipart direct upload, stored on the row when the session opens. The part
# size comes from an environment variable that may be edited at any time (`RELEASE_UPLOAD_PART_SIZE_MIB`), so
# an upload that is already open must keep the size it was opened with: R2 requires every part but the last to
# have the same length, and the plan (`ReleaseUploadParts::Plan`) is rebuilt from `declared_size` and this
# column at every parts request and at finalize. NULL means a single presigned PUT (every row before this
# migration, and every row opened while multipart is off). Additive; nothing reads the column yet.
class AddPartSizeToReleaseUploads < ActiveRecord::Migration[8.1]
  def change
    add_column :release_uploads, :part_size, :bigint
    add_check_constraint :release_uploads, 'part_size IS NULL OR part_size > 0',
                         name: 'release_uploads_part_size_positive'
  end
end
