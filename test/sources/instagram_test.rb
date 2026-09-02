# frozen_string_literal: true

require_relative '../test_helper'

module OFDL
  module Sources
    class InstagramTest < TestCase
      # Records which reels the listing offered and which ones a full row was
      # then requested for, so a test can show the second is a subset.
      class FakeApi
        attr_reader :fetched

        def initialize(reels: [], timeline: [], stories: [], missing: [])
          @reels = reels
          @timeline = timeline
          @stories = stories
          @missing = missing
          @fetched = []
        end

        attr_accessor :follows, :friendship_rows

        def reels(_user_id) = @reels.map { { 'pk' => it } }

        def following(_user_id) = Array(@follows)

        def user(username) = { 'pk' => "id-#{username}", 'username' => username }

        def friendship(user_id) = (@friendship_rows || {}).fetch(user_id, { 'following' => true })

        def timeline(_user_id, since: nil) = @timeline

        def stories(_user_id) = @stories

        def media(media_id)
          @fetched << media_id
          return nil if @missing.include?(media_id)

          { 'pk' => media_id, 'taken_at' => 1_768_000_000, 'media_type' => 2, 'product_type' => 'clips',
            'video_versions' => [{ 'url' => "https://cdn.example.com/#{media_id}.mp4", 'width' => 720 }],
            'image_versions2' => { 'candidates' => [{ 'url' => "https://cdn.example.com/#{media_id}.jpg",
                                                      'width' => 1080 }] } }
        end
      end

      def setup
        @dir = Pathname(Dir.mktmpdir('ofdl-ig'))
        @config = Config.new(@dir.join('config.json'))
      end

      def teardown = FileUtils.remove_entry(@dir)

      def source(api)
        subject = Instagram.new(config: @config, log: silent_log, stats: Stats.new, transport: nil)
        subject.instance_variable_set(:@api, api)
        subject
      end

      def rows(subject, post_types, present: nil)
        seen = []
        subject.each_row(post_types, 7, present:) { |post_type, row| seen << [post_type, row['pk']] }
        seen
      end

      def test_it_answers_to_the_instagram_key
        assert_equal('instagram', source(FakeApi.new).key)
      end

      def test_it_names_the_post_types_it_has
        assert_equal(%w[posts reels stories highlights avatar], source(FakeApi.new).post_types)
      end

      # An account's reels need not appear in its grid, so the reels tab is its
      # own listing rather than a filter over the timeline.
      def test_reels_come_from_the_reels_tab_not_the_timeline
        api = FakeApi.new(reels: %w[10 20], timeline: [{ 'pk' => '30' }])

        assert_equal([%w[reels 10], %w[reels 20]], rows(source(api), %w[reels]))
      end

      def test_posts_come_from_the_timeline
        api = FakeApi.new(reels: %w[10], timeline: [{ 'pk' => '30' }])

        assert_equal([%w[posts 30]], rows(source(api), %w[posts]))
      end

      # The listing gives no video URL, so a reel costs a second request -- and
      # that request is what asking the library first avoids.
      def test_a_reel_already_on_disk_costs_no_request
        api = FakeApi.new(reels: %w[10 20])
        on_disk = ->(_post_type, key) { key.start_with?('10_') }

        seen = rows(source(api), %w[reels], present: on_disk)

        assert_equal([%w[reels 20]], seen)
        assert_equal(%w[20], api.fetched)
      end

      # Both files have to be present to skip it: a run interrupted between the
      # video and its thumbnail must still fetch the thumbnail.
      def test_a_reel_missing_one_of_its_two_files_is_still_fetched
        api = FakeApi.new(reels: %w[10])
        video_only = ->(_post_type, key) { key == '10_10' }

        assert_equal([%w[reels 10]], rows(source(api), %w[reels], present: video_only))
        assert_equal(%w[10], api.fetched)
      end

      def test_every_reel_is_fetched_when_nothing_is_on_disk
        api = FakeApi.new(reels: %w[10 20])

        rows(source(api), %w[reels], present: ->(_post_type, _key) { false })

        assert_equal(%w[10 20], api.fetched)
      end

      # A reel deleted between the listing and the request returns nothing;
      # that is one reel lost, not the walk.
      def test_a_reel_that_cannot_be_read_is_skipped
        api = FakeApi.new(reels: %w[10 20], missing: %w[10])

        assert_equal([%w[reels 20]], rows(source(api), %w[reels]))
      end

      # Following is the list `ofdl subs` prints and `ofdl fetch` walks with no
      # names given.
      def test_creators_are_the_accounts_you_follow
        api = FakeApi.new
        api.follows = [{ 'pk' => '10', 'username' => 'alice' }, { 'pk' => '20', 'username' => 'bob' }]
        subject = source(api)
        subject.define_singleton_method(:viewer_id) { '99' }

        assert_equal([{ source: 'instagram', id: '10', username: 'alice' },
                      { source: 'instagram', id: '20', username: 'bob' }], subject.creators)
      end

      def test_a_named_creator_resolves_whether_or_not_you_follow_them
        api = FakeApi.new
        api.friendship_rows = { 'id-alice' => { 'following' => false, 'is_private' => false } }

        assert_equal({ source: 'instagram', id: 'id-alice', username: 'alice' }, source(api).resolve('alice'))
      end

      # Following is not what makes an account readable, so not following is
      # said out loud rather than refused.
      def test_not_following_is_warned_about
        api = FakeApi.new
        api.friendship_rows = { 'id-alice' => { 'following' => false, 'is_private' => false } }
        said = []
        subject = source(api)
        subject.instance_variable_get(:@log).define_singleton_method(:warn) { |text| said << text }

        subject.resolve('alice')

        assert_match(/follow/, said.join)
      end

      def test_following_says_nothing
        said = []
        subject = source(FakeApi.new)
        subject.instance_variable_get(:@log).define_singleton_method(:warn) { |text| said << text }

        subject.resolve('alice')

        assert_empty(said)
      end

      # A private account you do not follow shows a non-follower nothing, so the
      # warning says that rather than suggesting a follow would top it up.
      def test_a_private_account_you_do_not_follow_is_named_as_unreadable
        api = FakeApi.new
        api.friendship_rows = { 'id-alice' => { 'following' => false, 'is_private' => true } }
        said = []
        subject = source(api)
        subject.instance_variable_get(:@log).define_singleton_method(:warn) { |text| said << text }

        subject.resolve('alice')

        assert_match(/private/, said.join)
      end

      # An @handle in a caption is ordinary here; see Advert for the OnlyFans
      # meaning.
      def test_no_post_is_read_as_an_advert
        row = { 'caption' => { 'text' => 'shot with @someoneelse' } }

        assert_nil(source(FakeApi.new).advert_reason(row, creator: 'alice'))
      end

      def test_an_unknown_post_type_is_an_error
        assert_raises(ConfigError) { rows(source(FakeApi.new), %w[nonsense]) }
      end
    end
  end
end
