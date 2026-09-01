# frozen_string_literal: true

require_relative 'test_helper'

module OFDL
  class MediaTest < TestCase
    def row(media)
      { 'id' => 111, 'postedAt' => '2026-01-14T10:00:00+00:00', 'media' => media.is_a?(Array) ? media : [media] }
    end

    def test_maps_a_plain_photo
      item = Media.from_row(row({
                                  'id' => 222, 'type' => 'photo',
                                  'files' => { 'full' => { 'url' => 'https://cdn.example.com/a/b.jpg?Policy=x' } }
                                }), post_type: 'posts').first

      assert_equal(222, item.media_id)
      assert_equal(111, item.post_id)
      assert_equal('jpg', item.extension)
      refute_predicate(item, :protected?)
      assert_equal('2026-01-14_111_222.jpg', item.filename)
    end

    def test_flags_drm_from_the_response_alone
      item = Media.from_row(row({
                                  'id' => 333, 'type' => 'video',
                                  'files' => {
                                    'full' => { 'url' => nil },
                                    'drm' => { 'manifest' => { 'dash' => 'https://cdn.example.com/v.mpd' } }
                                  }
                                }), post_type: 'posts').first

      assert_predicate(item, :protected?)
      assert_equal('mpd', item.extension)
      assert_equal('2026-01-14_111_333.mpd.drm', item.marker_filename)
    end

    def test_drops_media_the_account_cannot_view
      items = Media.from_row(row({ 'id' => 444, 'type' => 'video', 'canView' => false }), post_type: 'posts')

      assert_empty(items)
    end

    def test_drops_locked_rows
      locked = row({ 'id' => 555, 'type' => 'photo',
                     'files' => { 'full' => { 'url' => 'https://cdn.example.com/a.jpg' } } })
      locked['canViewMedia'] = false

      assert_empty(Media.from_row(locked, post_type: 'posts'))
    end

    def test_falls_back_to_kind_when_the_url_has_no_extension
      item = Media.from_row(row({
                                  'id' => 666, 'type' => 'audio',
                                  'files' => { 'full' => { 'url' => 'https://cdn.example.com/stream?id=9' } }
                                }), post_type: 'messages').first

      assert_equal('mp3', item.extension)
    end

    # A row does not say which feed it came from, so Media takes the post type
    # from its caller and stamps it on the Item.
    def test_carries_the_post_type_it_was_read_under
      item = Media.from_row(row({
                                  'id' => 777, 'type' => 'photo',
                                  'files' => { 'full' => { 'url' => 'https://cdn.example.com/a.jpg' } }
                                }), post_type: 'messages').first

      assert_equal('messages', item.post_type)
    end
  end
end
