# frozen_string_literal: true

module OFDL
  # The apps a creator is archived from.
  #
  # A source name is the first level of the output tree, so one creator's media
  # on two apps lands in two directories and neither run's presence check
  # answers for the other.
  #
  # It is also the prefix a creator name on the command line may carry --
  # `onlyfans/alice`, `of/alice`. An app appears here once a run can fetch from
  # it, so a prefix naming one that cannot resolves to nothing rather than to a
  # source with nothing behind it.
  module Source
    ONLYFANS = 'onlyfans'

    # Full name => the short forms accepted in a command-line prefix.
    ALIASES = { ONLYFANS => %w[of] }.freeze

    ALL = ALIASES.keys.freeze

    # What an unprefixed creator name means.
    DEFAULT = ONLYFANS

    BY_NAME = ALIASES.flat_map { |name, short| [[name, name], *short.map { |s| [s, name] }] }.to_h.freeze

    # The full name, or nil when nothing here answers to it.
    def self.resolve(name) = BY_NAME[name.to_s.downcase]
  end
end
