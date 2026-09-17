class CreateProxySdkSettings < ActiveRecord::Migration[6.1]
  def change
    create_table :proxy_sdk_settings do |t|
      t.boolean :enabled, default: false
      t.string :api_key
      t.string :sdk_dex_path
      t.timestamps
    end
  end
end
