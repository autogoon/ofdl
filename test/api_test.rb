# frozen_string_literal: true

require_relative 'test_helper'

module OFDL
  # `since` is an optimisation, not a filter: the items it excludes are dropped
  # by Session#verdict_for either way. What it saves is the paging.
  class ApiPagingTest < TestCase
    # Records every path and params it is asked for, and replies with the next
    # canned page.
    FakeClient = Struct.new(:pages, :seen) do
      def get(path, params = {})
        seen << [path, params]
        pages.shift || { 'list' => [], 'hasMore' => false }
      end
    end

    def row(id, posted_at) = { 'id' => id, 'postedAt' => posted_at, 'media' => [] }

    def page(rows, more: true)
      { 'list' => rows, 'hasMore' => more, 'tailMarker' => rows.last&.dig('postedAt').to_s }
    end

    def client(*pages) = FakeClient.new(pages, [])

    def test_posts_stop_at_the_first_page_older_than_since
      recent = page([row(1, '2026-08-20T00:00:00Z'), row(2, '2026-08-10T00:00:00Z')])
      older = page([row(3, '2026-07-20T00:00:00Z'), row(4, '2026-07-10T00:00:00Z')])
      fake = client(recent, older)

      rows = Api.new(client: fake).posts(9, since: Time.parse('2026-08-01T00:00:00Z')).to_a

      assert_equal([1, 2, 3, 4], rows.map { it['id'] })
      assert_equal(2, fake.seen.size)
    end

    # The page that ends the walk can still open with rows in range, so it is
    # yielded whole before the break.
    def test_the_last_page_is_yielded_before_the_walk_stops
      straddling = page([row(1, '2026-08-20T00:00:00Z'), row(2, '2026-07-01T00:00:00Z')])
      fake = client(straddling, page([row(3, '2026-06-01T00:00:00Z')]))

      rows = Api.new(client: fake).posts(9, since: Time.parse('2026-08-01T00:00:00Z')).to_a

      assert_equal([1, 2], rows.map { it['id'] })
      assert_equal(1, fake.seen.size)
    end

    def test_without_since_posts_page_to_the_end
      fake = client(page([row(1, '2026-08-20T00:00:00Z')]),
                    page([row(2, '2026-01-01T00:00:00Z')], more: false))

      rows = Api.new(client: fake).posts(9).to_a

      assert_equal([1, 2], rows.map { it['id'] })
      assert_equal(2, fake.seen.size)
    end

    def test_messages_stop_too
      fake = client({ 'list' => [row(1, '2026-07-01T00:00:00Z')], 'hasMore' => true },
                    { 'list' => [row(2, '2026-06-01T00:00:00Z')], 'hasMore' => true })

      rows = Api.new(client: fake).messages(9, since: Time.parse('2026-08-01T00:00:00Z')).to_a

      assert_equal([1], rows.map { it['id'] })
      assert_equal(1, fake.seen.size)
    end

    def test_paid_stops_too
      fake = client({ 'list' => [row(1, '2026-07-01T00:00:00Z')], 'hasMore' => true },
                    { 'list' => [row(2, '2026-06-01T00:00:00Z')], 'hasMore' => true })

      rows = Api.new(client: fake).paid(9, since: Time.parse('2026-08-01T00:00:00Z')).to_a

      assert_equal([1], rows.map { it['id'] })
      assert_equal(1, fake.seen.size)
    end

    # An empty page carries no date to compare, so the walk ends on `hasMore`
    # rather than on the guard.
    def test_an_empty_page_does_not_end_the_walk_by_date
      fake = client({ 'list' => [], 'hasMore' => true, 'tailMarker' => '1' },
                    page([row(1, '2026-08-20T00:00:00Z')], more: false))

      rows = Api.new(client: fake).posts(9, since: Time.parse('2026-08-01T00:00:00Z')).to_a

      assert_equal([1], rows.map { it['id'] })
      assert_equal(2, fake.seen.size)
    end
  end
end
