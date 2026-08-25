# frozen_string_literal: true

module OFDL
  # A post advertising another creator: its text names an @handle, or links to
  # another onlyfans.com page. Both forms survive whichever text field is read
  # -- OnlyFans returns `text` with the link wrapped in an anchor and `rawText`
  # without it, and the handle and the URL are in the string either way.
  module Advert
    # The @ must not follow a word character, or every email address in a post
    # is a handle. The final character class keeps trailing punctuation out of
    # the name, and holds the shortest match to three characters.
    HANDLE = /(?<![\w@.])@([a-z0-9_.]{2,29}[a-z0-9_])/i

    # The lookbehind rejects a hostname that merely ends in onlyfans.com. Only
    # the first path segment is a creator; the rest is captured so the debug
    # line names the page rather than its prefix.
    LINK = %r{(?<![\w.])(?:www\.)?onlyfans\.com/([a-z0-9_.]+)(?:/[^\s"'<>]*)?}i

    TEXT_FIELDS = %w[text rawText].freeze

    class << self
      # The handle or URL that matched, for the log line, or nil when the post
      # advertises nobody. `creator` is the account whose wall is being read:
      # their own name is not an advertisement for anyone else. It is absent
      # when a stream is drained without a username, and then every name counts.
      def reason(row, creator: nil)
        return nil unless row.is_a?(Hash)

        text = TEXT_FIELDS.filter_map { row[it] }.join(' ')
        return nil if text.empty?

        self_name = creator.to_s.downcase.delete_prefix('@')
        [LINK, HANDLE].each do |pattern|
          matched = first_other_name(text, pattern, self_name)
          return matched if matched
        end
        nil
      end

      private

      # A page path that is not a username -- onlyfans.com/action/trial/... --
      # cannot be the creator's own, and nothing but an advert carries one.
      def first_other_name(text, pattern, self_name)
        text.scan(pattern) do |(name)|
          return Regexp.last_match(0) unless name.downcase == self_name
        end
        nil
      end
    end
  end
end
