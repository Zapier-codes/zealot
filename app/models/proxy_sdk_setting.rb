class ProxySdkSetting < ApplicationRecord
  def self.enabled?
    first&.enabled || false
  end
  def self.sdk_dex_path
    first&.sdk_dex_path
  end
  def self.api_key
    first&.api_key
  end
end
