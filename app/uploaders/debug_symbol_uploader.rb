# frozen_string_literal: true

# Z-P11: where a release's mapping / native symbol file lives. `after :remove` in the base uploader
# removes the empty per-release directory when the row is replaced or deleted.
class DebugSymbolUploader < ApplicationUploader
  def store_dir
    "#{base_store_dir}/apps/a#{model.app_id}/r#{model.release_id}/symbols/#{model.kind}"
  end

  # Play accepts a zip of the mapping or the bare mapping.txt; native symbols are a zip. Keep it to
  # those two so a release's own source cannot be dropped here by mistake.
  def extension_allowlist
    %w[txt zip]
  end
end
