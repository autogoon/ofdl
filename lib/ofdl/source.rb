# frozen_string_literal: true

module OFDL
  # The apps a creator is archived from.
  #
  # A source name is the first level of the output tree, so one creator's media
  # on two apps lands in two directories and neither run's presence check
  # answers for the other.
  module Source
    ONLYFANS = 'onlyfans'

    ALL = [ONLYFANS].freeze
  end
end
