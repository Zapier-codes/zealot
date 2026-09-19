# frozen_string_literal: true

module HomeHelper
  # [threshold, suffix] pairs, largest first. Mirrors COMPACT_UNITS in
  # app/frontend/javascript/controllers/counter_controller.js — keep the
  # two in sync so the server-rendered value (no-JS / crawlers) matches
  # what the animated counter settles on.
  COMPACT_UNITS = [[1_000_000_000, 'B'], [1_000_000, 'M']].freeze

  # Shorthand for the landing page's big stat counters:
  #
  #   10_000_037 => "10M+"      5_250_000 => "5.2M+"      750_000 => "750,000+"
  #
  # Truncates to one decimal place rather than rounding, so a "+" never
  # overstates the real figure (5,299,999 is "5.2M+", not "5.3M+"). Always
  # ends in "+" because these totals are a baseline plus a live count.
  def compact_count(value)
    threshold, symbol = COMPACT_UNITS.find { |min, _| value >= min }
    return "#{number_with_delimiter(value)}+" unless threshold

    whole, tenth = (value / (threshold / 10)).divmod(10)
    "#{tenth.zero? ? whole : "#{whole}.#{tenth}"}#{symbol}+"
  end
end
