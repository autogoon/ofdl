# frozen_string_literal: true

module OFDL
  # The bar and the percentage beside it; Dashboard#slot lays out the rest of
  # the row.
  #
  #   [=======           ]
  #
  # `bar` returns `width` cells, MIN_WIDTH at the least, and returns them all
  # empty when the total is unknown, so the dashboard's columns hold whether or
  # not a size has arrived.
  #
  # ASCII, not block-drawing characters: those render at inconsistent widths
  # across terminals and fonts, so a bar built from them would not be a
  # predictable number of cells.
  class ProgressBar
    MIN_WIDTH = 4

    def initialize(total:, width: 20)
      @total = total.to_i
      @width = [width, MIN_WIDTH].max
    end

    def known? = @total.positive?

    def fraction(current)
      return 0.0 unless known?

      (current.to_f / @total).clamp(0.0, 1.0)
    end

    def bar(current)
      inner = @width - 2
      filled = (fraction(current) * inner).round
      "[#{'=' * filled}#{' ' * (inner - filled)}]"
    end

    # "69%", or "--" while the size is unknown. Dashboard#lead right-justifies
    # either to PERCENT_COLUMN.
    def percent(current)
      known? ? "#{(fraction(current) * 100).round}%" : '--'
    end
  end
end
