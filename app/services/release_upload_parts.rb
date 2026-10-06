# frozen_string_literal: true

# Task 40s: the plan for a multipart direct upload. Pure arithmetic and env reading, no Rails, no network, no
# database: it decides WHETHER a file is sent in parts, HOW BIG the parts are and whether the parts R2 holds
# are the parts the plan asked for. Rails never handles a byte of the file (nothing runs on Render's disk or
# memory): the browser or the developer's CI PUTs every part straight to R2 and Zealot only signs, lists,
# completes and aborts.
#
# Settings (environment, editable at any time; a change only affects uploads opened AFTER it, because the part
# size of an open upload is stored on its row):
#
#   RELEASE_UPLOAD_MULTIPART_ENABLED        "true" switches multipart on. Off (the default): every file is sent
#                                           as one presigned PUT, exactly as before Task 40s.
#   RELEASE_UPLOAD_MULTIPART_THRESHOLD_MIB  files of at least this many MiB go in parts. Default 100. A value
#                                           that is not a positive whole number falls back to the default; one
#                                           below the part size is raised to the part size.
#   RELEASE_UPLOAD_PART_SIZE_MIB            size of every part but the last, in MiB. Default 16. Not a positive
#                                           whole number, or below 5, falls back to the default.
#
# What R2 enforces (checked by the operator against the zealot-staging bucket, 2026-10-06; see the Task 40s
# session entry in handover.md): every part but the last must have the same length ("InvalidPart: All
# non-trailing parts must have the same length"), the last may be smaller, and a non-last part of 1 MiB is
# refused ("EntityTooSmall"). Parts of 6 MiB were accepted; 5 MiB is S3's minimum and is used as the floor.
#
#   plan = ReleaseUploadParts::Plan.new(size: 40_000_000, part_size: 16 * 1024 * 1024)
#   plan.count               # => 3
#   plan.size_of(3)          # => 6_445_952 (the last part is what is left)
#   plan.problem_with(parts) # => nil, or a sentence saying which parts are missing or the wrong size
#
# Not verified: no Rails and no R2 here; the arithmetic was exercised with a plain Ruby script only.
module ReleaseUploadParts
  MIB = 1024 * 1024
  DEFAULT_THRESHOLD_MIB = 100
  DEFAULT_PART_MIB = 16
  MIN_PART_MIB = 5
  # R2 and S3 allow at most 10,000 parts. At the smallest part size and the 2 GiB cap there are about 410.
  MAX_PARTS = 10_000

  # What a client may ask to be signed in one request.
  MAX_BATCH = 10

  # The window a multipart row stays open for (a large file on a slow link needs longer than a single PUT's
  # two hours). It must stay under the bucket's one-day rule that aborts half-sent multipart uploads.
  WINDOW = 6 * 60 * 60

  # One part as R2 reports it: its number and its size in bytes.
  Held = Struct.new(:part_number, :size, keyword_init: true)

  module_function

  def enabled?(env = ENV)
    env['RELEASE_UPLOAD_MULTIPART_ENABLED'] == 'true'
  end

  def part_size_bytes(env = ENV)
    mib = whole_mib(env['RELEASE_UPLOAD_PART_SIZE_MIB'])
    mib = DEFAULT_PART_MIB if mib.nil? || mib < MIN_PART_MIB
    mib * MIB
  end

  def threshold_bytes(env = ENV)
    mib = whole_mib(env['RELEASE_UPLOAD_MULTIPART_THRESHOLD_MIB']) || DEFAULT_THRESHOLD_MIB
    [mib * MIB, part_size_bytes(env)].max
  end

  # True when a file of `size` bytes is sent in parts under the current settings.
  def use_multipart?(size, env = ENV)
    return false unless enabled?(env)
    return false unless size.is_a?(Integer) && size.positive?

    size >= threshold_bytes(env)
  end

  # nil for anything that is not a plain positive whole number ("16", " 16 "); "1.5", "abc", "0", "-3" are nil.
  def whole_mib(value)
    text = value.to_s.strip
    return nil unless text.match?(/\A\d+\z/)

    number = text.to_i
    number.positive? ? number : nil
  end

  # The split of one file into parts.
  class Plan
    attr_reader :size, :part_size

    def initialize(size:, part_size:)
      @size = Integer(size)
      @part_size = Integer(part_size)
      raise ArgumentError, 'size must be positive' unless @size.positive?
      raise ArgumentError, 'part_size must be positive' unless @part_size.positive?
    end

    def count
      (size + part_size - 1) / part_size
    end

    # @return [Integer] the number of bytes part `number` must have; 0 for a number outside the plan
    def size_of(number)
      return 0 unless number.is_a?(Integer) && number.between?(1, count)

      number < count ? part_size : size - ((count - 1) * part_size)
    end

    def number_ok?(number)
      number.is_a?(Integer) && number.between?(1, count)
    end

    # @param held [Array<Held>] what R2 lists for the upload
    # @return [nil, String] nil when the listed parts are exactly the planned ones; otherwise a sentence
    def problem_with(held)
      by_number = held.to_h { |part| [part.part_number, part.size] }
      stray = by_number.keys.reject { |number| number_ok?(number) }
      return "R2 holds parts that are not part of this upload (#{stray.sort.first(5).join(', ')})." if stray.any?

      wrong = (1..count).reject { |number| by_number[number] == size_of(number) }
      return nil if wrong.empty?

      "Parts #{summarize(wrong)} of #{count} are missing or have the wrong size. Send them again, then finalize."
    end

    # The part numbers still to send, given what R2 holds (a part with the wrong size counts as not sent).
    def missing(held)
      by_number = held.to_h { |part| [part.part_number, part.size] }
      (1..count).reject { |number| by_number[number] == size_of(number) }
    end

    private

    # "3, 5, 6" or "3, 5 and 40 more": keeps the message short for a file with many missing parts.
    def summarize(numbers)
      shown = numbers.first(8).join(', ')
      numbers.size > 8 ? "#{shown} and #{numbers.size - 8} more" : shown
    end
  end
end
