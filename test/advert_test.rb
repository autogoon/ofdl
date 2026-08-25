# frozen_string_literal: true

require_relative 'test_helper'

module OFDL
  class AdvertTest < TestCase
    def row(text, field: 'text') = { 'id' => 1, field => text }

    def test_an_at_handle_is_an_advert
      assert_equal('@bob', Advert.reason(row('go see @bob 😘'), creator: 'alice'))
    end

    def test_a_bare_link_is_an_advert
      assert_equal('onlyfans.com/bob',
                   Advert.reason(row('https://onlyfans.com/bob'), creator: 'alice'))
    end

    def test_an_anchor_is_an_advert
      text = %(my friend <a href="https://onlyfans.com/bob">bob</a>)

      assert_equal('onlyfans.com/bob', Advert.reason(row(text), creator: 'alice'))
    end

    def test_a_www_link_is_an_advert
      assert_equal('www.onlyfans.com/bob', Advert.reason(row('www.onlyfans.com/bob'), creator: 'alice'))
    end

    # The path holds no username, so the exclusion for the creator's own page
    # cannot apply. Nothing but an advert carries such a link.
    def test_a_trial_link_is_an_advert
      assert_equal('onlyfans.com/action/trial/abc123',
                   Advert.reason(row('free! https://onlyfans.com/action/trial/abc123'), creator: 'alice'))
    end

    def test_the_creators_own_handle_is_not_an_advert
      assert_nil(Advert.reason(row('@alice is back tomorrow'), creator: 'alice'))
    end

    def test_the_creators_own_page_is_not_an_advert
      assert_nil(Advert.reason(row('pinned: onlyfans.com/alice/photo/9'), creator: 'alice'))
    end

    def test_the_creators_own_name_matches_without_regard_to_case_or_a_leading_at
      assert_nil(Advert.reason(row('@Alice_X here'), creator: '@alice_x'))
    end

    # The first is the creator's own page; the second is not.
    def test_a_second_name_still_advertises
      text = 'onlyfans.com/alice and also @bob'

      assert_equal('@bob', Advert.reason(row(text), creator: 'alice'))
    end

    def test_an_email_address_is_not_a_handle
      assert_nil(Advert.reason(row('business: alice@example.com'), creator: 'alice'))
    end

    def test_a_plain_post_is_not_an_advert
      assert_nil(Advert.reason(row('new set up now, 20 photos'), creator: 'alice'))
    end

    def test_a_row_with_no_text_is_not_an_advert
      assert_nil(Advert.reason({ 'id' => 1 }, creator: 'alice'))
      assert_nil(Advert.reason(nil, creator: 'alice'))
    end

    def test_reads_the_unmarked_up_text_as_well
      assert_equal('@bob', Advert.reason(row('go see @bob', field: 'rawText'), creator: 'alice'))
    end

    def test_trailing_punctuation_is_not_part_of_the_handle
      assert_equal('@bob', Advert.reason(row('subscribe to @bob.'), creator: 'alice'))
    end

    def test_a_single_letter_is_not_a_handle
      assert_nil(Advert.reason(row('rated 10/10 @ 9pm'), creator: 'alice'))
    end

    # `creator` is absent when the stream is drained without a username.
    def test_without_a_creator_every_name_advertises
      assert_equal('@alice', Advert.reason(row('@alice')))
    end
  end
end
