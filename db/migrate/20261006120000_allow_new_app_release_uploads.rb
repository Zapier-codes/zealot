# frozen_string_literal: true

# Task 40r: a staged upload may now be the first upload of an app, which has no channel yet. The row keeps no
# channel until CI's stage-1 report names the package; `ReleaseUploadAppResolver` then creates the app, scheme
# and channel and sets `channel_id` before the release is built. A row without a channel is only legal when
# `form_options['new_app']` is set (a model rule, `ReleaseUpload#channel_or_new_app`).
class AllowNewAppReleaseUploads < ActiveRecord::Migration[8.1]
  def change
    change_column_null :release_uploads, :channel_id, true
  end
end
