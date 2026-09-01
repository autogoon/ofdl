# frozen_string_literal: true

require_relative 'test_helper'

module OFDL
  class ScratchTest < TestCase
    def setup
      @dir = Pathname(Dir.mktmpdir('ofdl-scratch-test'))
      @scratch = Scratch.new(root: @dir.join('work').tap(&:mkpath))
      @destination = @dir.join('out').tap(&:mkpath)
    end

    def teardown = FileUtils.remove_entry(@dir)

    def item(key: '111_222', extension: 'jpg')
      post, media = key.split('_')
      Item.new(media_id: media, post_id: post, post_type: 'posts', kind: 'photo',
               posted_at: Time.utc(2026, 1, 14), url: 'https://cdn.example.com/a.jpg',
               protected: false, extension:)
    end

    def test_working_paths_are_local_and_unique_per_item
      assert_equal(@scratch.root.join('111_222.jpg'), @scratch.path_for(item))
      assert_equal(@scratch.root.join('111_222.headers'), @scratch.headers_for(item))
    end

    def test_publish_moves_the_finished_file_into_place
      working = @scratch.path_for(item)
      working.write('hello')
      target = @destination.join('final.jpg')

      assert_equal(5, @scratch.publish(working, target))
      assert_equal('hello', target.read)
    end

    # The staged copy lands beside the destination, not in the scratch root --
    # see Scratch#publish for why.
    def test_publish_stages_beside_the_destination_before_renaming
      working = @scratch.path_for(item)
      working.write('hello')
      target = @destination.join('final.jpg')

      @scratch.publish(working, target)
      staged = @destination.join('final.jpg.part')

      refute_path_exists(staged, 'the staging file should be renamed away, not left behind')
      assert_path_exists(target)
    end

    def test_clear_removes_what_it_is_given
      path = @scratch.path_for(item)
      path.write('x')

      @scratch.clear(path)

      refute_path_exists(path)
    end

    def test_clear_tolerates_missing_and_nil_paths
      @scratch.clear(nil, @scratch.root.join('never-existed'))
    end

    def test_remove_takes_the_whole_directory
      @scratch.path_for(item).write('x')

      @scratch.remove!

      refute_path_exists(@scratch.root)
    end

    def test_remove_is_idempotent
      @scratch.remove!
      @scratch.remove!
    end

    def test_a_default_scratch_lives_under_tmp
      scratch = Scratch.new

      assert_path_exists(scratch.root)
      assert_includes(scratch.root.to_s, Dir.tmpdir)
    ensure
      scratch&.remove!
    end
  end
end
