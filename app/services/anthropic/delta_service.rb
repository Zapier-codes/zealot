# frozen_string_literal: true

module Anthropic
  # Computes and applies binary deltas between two APK versions using bsdiff,
  # so update clients can download a small patch instead of the full APK.
  class DeltaService
    class BsdiffNotFoundError < StandardError; end
    class PatchFailedError < StandardError; end

    DEFAULT_BSDIFF_PATH = ENV.fetch('BSDIFF_PATH', '/usr/bin/bsdiff')
    DEFAULT_BSPATCH_PATH = ENV.fetch('BSPATCH_PATH', '/usr/bin/bspatch')

    attr_reader :bsdiff_path, :bspatch_path

    def initialize(bsdiff_path: DEFAULT_BSDIFF_PATH, bspatch_path: DEFAULT_BSPATCH_PATH)
      @bsdiff_path = bsdiff_path
      @bspatch_path = bspatch_path
    end

    # @return [String] path to the generated patch file
    def diff(old_path, new_path, patch_path)
      ensure_present!(bsdiff_path, BsdiffNotFoundError, 'bsdiff')
      [old_path, new_path].each do |p|
        raise PatchFailedError, "File not found: #{p}" unless File.exist?(p)
      end

      FileUtils.mkdir_p(File.dirname(patch_path))
      run_command!([bsdiff_path, old_path, new_path, patch_path])
      patch_path
    end

    # Applies a patch to `old_path`, writing the reconstructed file to
    # `output_path`. Used both for serving updates and for verifying a
    # freshly generated patch round-trips correctly.
    def apply(old_path, patch_path, output_path)
      ensure_present!(bspatch_path, BsdiffNotFoundError, 'bspatch')
      [old_path, patch_path].each do |p|
        raise PatchFailedError, "File not found: #{p}" unless File.exist?(p)
      end

      FileUtils.mkdir_p(File.dirname(output_path))
      run_command!([bspatch_path, old_path, output_path, patch_path])
      output_path
    end

    private

    def ensure_present!(path, error_class, name)
      return if File.executable?(path) || system("command -v #{path} > /dev/null 2>&1")

      raise error_class, "#{name} not found at #{path}."
    end

    def run_command!(cmd)
      stdout, stderr, status = Open3.capture3(*cmd)
      return stdout if status.success?

      raise PatchFailedError, "#{cmd.first} failed: #{stderr.presence || stdout}"
    end
  end
end
