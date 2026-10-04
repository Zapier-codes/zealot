# frozen_string_literal: true

# Production's `releases` table has no `patched_file_path` column, although db/schema.rb has it and
# `ReleaseFileMirrorJob` reads it (NoMethodError at release_file_mirror_job.rb:49 on 2026-10-04, which
# stopped the copy of an upload to storage). The column's original migration,
# 20240102000000_add_patched_file_path_to_releases.rb, carries a back-dated version, and the database
# reported "up to date" at 20261003120000 without ever having applied it.
#
# This migration has a current version, so every database that is already past the old one still runs it,
# and it adds the column only when it is missing, so a database that does have it is left alone.
class EnsurePatchedFilePathOnReleases < ActiveRecord::Migration[7.1]
  def up
    return if column_exists?(:releases, :patched_file_path)

    add_column :releases, :patched_file_path, :string
  end

  # Not reversible on purpose: the column belongs to the older migration, and dropping it here would
  # remove data on databases where that migration did run.
  def down; end
end
