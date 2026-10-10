# frozen_string_literal: true

module ArchivePatcher
  # The base of every error this namespace raises, so a caller can rescue one class (a malformed archive, a
  # malformed patch, an unsupported compression method, a delta that does not reproduce) without knowing
  # which layer noticed.
  class Error < StandardError; end
end
