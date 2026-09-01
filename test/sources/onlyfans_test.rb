# frozen_string_literal: true

require_relative '../test_helper'

module OFDL
  module Sources
    class OnlyFansTest < TestCase
      # Stands in for Api: records which feed was asked for and returns canned
      # rows, so nothing here reaches the network.
      class FakeApi
        attr_reader :asked

        def initialize(rows = {})
          @rows = rows
          @asked = []
        end

        def posts(id, archived: false, since: nil)
          @asked << [archived ? 'archived' : 'posts', id, since]
          @rows.fetch(archived ? 'archived' : 'posts', [])
        end

        def messages(id, since: nil) = record('messages', id, since)
        def paid(id, since: nil) = record('paid', id, since)
        def stories(id) = record('stories', id, nil)
        def highlights(id) = record('highlights', id, nil)

        def subscriptions = @rows.fetch('subscriptions', [])

        private

        def record(name, id, since)
          @asked << [name, id, since]
          @rows.fetch(name, [])
        end
      end

      def setup
        @dir = Pathname(Dir.mktmpdir('ofdl-onlyfans'))
        @config = Config.new(@dir.join('config.json'))
      end

      def teardown = FileUtils.remove_entry(@dir)

      def source(rows = {})
        subject = OnlyFans.new(config: @config, log: silent_log, stats: Stats.new, transport: nil)
        subject.instance_variable_set(:@api, FakeApi.new(rows))
        subject
      end

      def row(post_id, media_id)
        {
          'id' => post_id, 'postedAt' => '2026-01-14T00:00:00Z',
          'media' => [{ 'id' => media_id, 'type' => 'photo',
                        'files' => { 'full' => { 'url' => "https://cdn.example.com/#{media_id}.jpg" } } }]
        }
      end

      def test_it_answers_to_the_onlyfans_key
        assert_equal('onlyfans', source.key)
      end

      def test_it_names_the_feeds_it_has
        assert_equal(%w[posts messages stories highlights paid archived], source.post_types)
      end

      # The post type decides which Api call is made; see Api for the cursor
      # each feed carries.
      def test_each_post_type_reaches_its_own_endpoint
        subject = source
        %w[posts archived messages paid stories highlights].each { subject.each_row(it, 7) { nil } }

        assert_equal(%w[posts archived messages paid stories highlights], subject.api.asked.map(&:first))
      end

      # Only the feeds ordered newest-first can stop early on it; see
      # Api#exhausted?.
      def test_since_reaches_the_feeds_that_can_stop_on_it
        subject = source
        since = Time.utc(2026, 1, 1)
        %w[posts messages paid stories highlights].each { subject.each_row(it, 7, since:) { nil } }

        carried = subject.api.asked.to_h { [it.first, it.last] }

        assert_equal(since, carried['posts'])
        assert_equal(since, carried['messages'])
        assert_equal(since, carried['paid'])
        assert_nil(carried['stories'])
        assert_nil(carried['highlights'])
      end

      def test_an_unknown_post_type_is_an_error
        assert_raises(ConfigError) { source.each_row('nonsense', 7) { nil } }
      end

      # A feed that fails does not end the run: the others still have media in
      # them.
      def test_a_failing_feed_is_logged_and_skipped
        subject = source
        subject.api.define_singleton_method(:posts) { |*, **| raise ApiError, 'HTTP 500' }

        seen = []
        subject.each_row('posts', 7) { seen << it }

        assert_empty(seen)
      end

      def test_items_carry_the_onlyfans_source
        items = source.items_from(row(1, 10), post_type: 'posts')

        assert_equal(['onlyfans'], items.map(&:source))
        assert_equal(['posts'], items.map(&:post_type))
      end

      def test_creators_are_the_active_subscriptions
        subject = source('subscriptions' => [{ 'id' => 1, 'username' => 'alice' }])

        assert_equal([{ source: 'onlyfans', id: 1, username: 'alice' }], subject.creators)
      end

      # The same creator can appear on more than one page of the subscription
      # list; archiving one twice would list every feed twice.
      def test_creators_are_deduplicated
        rows = [{ 'id' => 1, 'username' => 'alice' }, { 'id' => 1, 'username' => 'alice' }]

        assert_equal(1, source('subscriptions' => rows).creators.size)
      end

      def test_a_post_advertising_another_creator_is_reported
        advert = row(1, 10).merge('text' => 'go and see @someoneelse')

        assert_equal('@someoneelse', source.advert_reason(advert, creator: 'alice'))
      end

      def test_a_post_naming_the_creator_being_scanned_is_not_an_advert
        own = row(1, 10).merge('text' => 'follow me at @alice')

        assert_nil(source.advert_reason(own, creator: 'alice'))
      end
    end
  end
end
