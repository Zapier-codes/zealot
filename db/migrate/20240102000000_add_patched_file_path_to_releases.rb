class AddPatchedFilePathToReleases < ActiveRecord::Migration[7.1]
  def change
    add_column :releases, :patched_file_path, :string
  end
end
