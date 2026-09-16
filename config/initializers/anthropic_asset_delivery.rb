# frozen_string_literal: true

Rails.application.configure do
  config.x.anthropic = ActiveSupport::OrderedOptions.new
  config.x.anthropic.asset_pack_delivery_enabled = ActiveModel::Type::Boolean.new.cast(
    ENV.fetch('ENABLE_ASSET_PACK_DELIVERY', 'false')
  )
  config.x.anthropic.delta_patching_enabled = ActiveModel::Type::Boolean.new.cast(
    ENV.fetch('ENABLE_DELTA_PATCHING', 'false')
  )
end
