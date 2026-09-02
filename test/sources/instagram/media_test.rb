# frozen_string_literal: true

require_relative '../../test_helper'

module OFDL
  module Sources
    # Shapes taken from live responses; the ids and hosts are invented.
    class InstagramMediaTest < TestCase
      PHOTO = 1
      VIDEO = 2
      CAROUSEL = 8

      def candidates(*widths)
        { 'candidates' => widths.map { |w| { 'url' => "https://cdn.example.com/#{w}.jpg", 'width' => w } } }
      end

      def videos(*widths)
        widths.map { |w| { 'url' => "https://cdn.example.com/#{w}.mp4", 'width' => w, 'type' => 101 } }
      end

      def row(post_id: '111', media_type: PHOTO, product_type: 'feed', **rest)
        { 'pk' => post_id, 'taken_at' => 1_768_000_000, 'media_type' => media_type,
          'product_type' => product_type, 'image_versions2' => candidates(1080, 640) }.merge(rest)
      end

      def build(row, post_type: 'posts') = Instagram::Media.from_row(row, post_type:)

      def test_a_photo_becomes_one_item
        items = build(row)

        assert_equal(1, items.size)
        assert_equal('111_111', items.first.key)
        assert_equal('jpg', items.first.extension)
        assert_equal('instagram', items.first.source)
      end

      # The response lists candidates widest first, and the widest is the
      # original upload. The width is compared rather than the position, so the
      # order in the response does not decide it.
      def test_the_widest_candidate_is_taken_whatever_the_order
        items = build(row('image_versions2' => candidates(320, 1080, 640)))

        assert_equal('https://cdn.example.com/1080.jpg', items.first.url)
      end

      def test_the_widest_video_is_taken
        items = build(row(media_type: VIDEO, 'video_versions' => videos(480, 720, 640)))

        assert_equal('https://cdn.example.com/720.mp4', items.first.url)
      end

      def test_the_timestamp_comes_from_taken_at
        assert_equal(Time.at(1_768_000_000), build(row).first.posted_at)
      end

      # A reel is one row holding both files, and both are wanted; the
      # thumbnail takes a role so the two do not share a key. See
      # Library::MEDIA_ID.
      def test_a_reel_becomes_the_video_and_its_thumbnail
        items = build(row(media_type: VIDEO, product_type: 'clips', 'video_versions' => videos(720)),
                      post_type: 'reels')

        assert_equal(%w[111_111 111_111_thumb], items.map(&:key))
        assert_equal(%w[mp4 jpg], items.map(&:extension))
        assert_equal(%w[video photo], items.map(&:kind))
      end

      # A video posted to the grid is not a reel; only a reel is wanted in two
      # files.
      def test_a_plain_video_post_becomes_the_video_alone
        items = build(row(media_type: VIDEO, product_type: 'feed', 'video_versions' => videos(720)))

        assert_equal(%w[111_111], items.map(&:key))
      end

      def test_a_video_with_no_versions_is_dropped
        assert_empty(build(row(media_type: VIDEO, product_type: 'feed')))
      end

      # Each child carries its own pk, so a carousel needs no invented ids.
      def test_a_carousel_becomes_one_item_per_child
        items = build(row(media_type: CAROUSEL, product_type: 'carousel_container', 'carousel_media' => [
                            { 'pk' => '222', 'media_type' => PHOTO, 'image_versions2' => candidates(1080) },
                            { 'pk' => '333', 'media_type' => VIDEO, 'image_versions2' => candidates(1080),
                              'video_versions' => videos(720) }
                          ]))

        assert_equal(%w[111_222 111_333], items.map(&:key))
        assert_equal(%w[jpg mp4], items.map(&:extension))
      end

      # The children are the media; the container has no file of its own.
      def test_a_carousel_container_contributes_no_item_itself
        items = build(row(media_type: CAROUSEL, product_type: 'carousel_container', 'carousel_media' => []))

        assert_empty(items)
      end

      def test_a_row_with_no_media_is_dropped
        assert_empty(build({ 'pk' => '111', 'taken_at' => 1, 'media_type' => PHOTO }))
      end

      # Nothing on Instagram is Widevine-protected; see Downloader.
      def test_nothing_is_marked_protected
        refute_predicate(build(row).first, :protected?)
      end
    end
  end
end
