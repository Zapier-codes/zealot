# frozen_string_literal: true

# Stores release-pipeline artifacts on local disk, under the same root
# CarrierWave uploads to. This is the default adapter, so existing/dev
# environments need no configuration to keep working.
class ReleaseStorage::LocalAdapter
  def initialize(root: default_root)
    @root = root
  end

  def put(key, local_path, content_encoding: nil, content_type: nil)
    destination = path_for(key)
    FileUtils.mkdir_p(File.dirname(destination))
    FileUtils.cp(local_path, destination)
    key
  end

  def get(key, to)
    source = path_for(key)
    return nil unless File.exist?(source)

    FileUtils.mkdir_p(File.dirname(to))
    FileUtils.cp(source, to)
    to
  end

  # Local files aren't served via a separate URL scheme in this adapter;
  # callers should fall back to `get` + `send_file`.
  def url_for(_key, expires_in: nil)
    nil
  end

  def delete(key)
    FileUtils.rm_f(path_for(key))
    true
  end

  def exist?(key)
    File.exist?(path_for(key))
  end

  private

  def default_root
    Rails.root.join('public')
  end

  def path_for(key)
    File.join(@root, key)
  end
end
