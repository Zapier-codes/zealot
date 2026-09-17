# frozen_string_literal: true

class AddMtprotoArchiveFieldsToReleases < ActiveRecord::Migration[7.1]
  def change
    add_column :releases, :mtproto_archived_location, :string
    add_column :releases, :mtproto_archived_at, :datetime
    add_index :releases, :mtproto_archived_at
  end
end
