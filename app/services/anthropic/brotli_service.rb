# frozen_string_literal: true

module Anthropic
  # Compresses/decompresses files with Brotli for smaller wire transfer.
  #
  # NOTE: Android's PackageManager does NOT auto-decompress Brotli for
  # sideloaded APKs. Any client consuming files produced by this service
  # must explicitly decompress before installing. This service only
  # produces the compressed artifact and reports size metrics; it does not
  # attempt to make Brotli-compressed APKs directly installable.
  class BrotliService
    class BrotliNotFoundError < StandardError; end
    class CompressionFailedError < StandardError; end

    DEFAULT_BROTLI_PATH = ENV.fetch('BROTLI_PATH', '/usr/bin/brotli')
    DEFAULT_QUALITY = ENV.fetch('BROTLI_QUALITY', '11').to_i

    attr_reader :brotli_path, :quality

    def initialize(brotli_path: DEFAULT_BROTLI_PATH, quality: DEFAULT_QUALITY)
      @brotli_path = brotli_path
      @quality = quality
    end

    # @param input_path [String] file to compress
    # @param output_path [String, nil] defaults to "#{input_path}.br"
    # @return [Hash] { path:, original_size:, compressed_size: }
    def compress(input_path, output_path: nil)
      raise CompressionFailedError, "Input not found: #{input_path}" unless File.exist?(input_path)

      output_path ||= "#{input_path}.br"
      FileUtils.rm_f(output_path)

      original_size = File.size(input_path)

      if binary_available?
        run_command!([brotli_path, "-q#{quality}", '-o', output_path, input_path])
      elsif ruby_gem_available?
        compress_with_gem(input_path, output_path)
      else
        raise BrotliNotFoundError, "Neither brotli CLI (#{brotli_path}) nor the `brotli` gem is available."
      end

      {
        path: output_path,
        original_size: original_size,
        compressed_size: File.size(output_path)
      }
    end

    # Decompresses a .br file, primarily used to verify round-trip integrity.
    def decompress(input_path, output_path:)
      raise CompressionFailedError, "Input not found: #{input_path}" unless File.exist?(input_path)

      if binary_available?
        run_command!([brotli_path, '-d', '-o', output_path, input_path])
      elsif ruby_gem_available?
        File.binwrite(output_path, ::Brotli.inflate(File.binread(input_path)))
      else
        raise BrotliNotFoundError, "Neither brotli CLI nor the `brotli` gem is available."
      end

      output_path
    end

    private

    def binary_available?
      File.executable?(brotli_path) || system("command -v #{brotli_path} > /dev/null 2>&1")
    end

    def ruby_gem_available?
      require 'brotli'
      true
    rescue LoadError
      false
    end

    def compress_with_gem(input_path, output_path)
      File.binwrite(output_path, ::Brotli.deflate(File.binread(input_path), quality: quality))
    end

    def run_command!(cmd)
      stdout, stderr, status = Open3.capture3(*cmd)
      return stdout if status.success?

      raise CompressionFailedError, "brotli command failed: #{stderr.presence || stdout}"
    end
  end
end
