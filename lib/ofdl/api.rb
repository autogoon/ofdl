# frozen_string_literal: true

module OFDL
  # Pagination over the private API. The paginating methods return a lazy
  # Enumerator of raw rows, so a caller can stop early without fetching the
  # rest of a timeline.
  #
  # Each source carries its own cursor:
  #   posts    -> `beforePublishTime` from the response's `tailMarker`
  #   messages -> `id` of the last row returned
  #   paid     -> numeric `offset`
  #   stories  -> single request, no pagination
  class Api
    PAGE = 50
    HIGHLIGHT_PAGE = 10
    LIST_PAGE = 12

    def initialize(client:)
      @client = client
    end

    def me = @client.get('/users/me')

    def subscriptions(type: 'active')
      paged_by_offset('/subscriptions/subscribes', type:, format: 'infinite')
    end

    def posts(user_id, archived: false)
      Enumerator.new do |yielder|
        marker = nil
        loop do
          params = {
            limit: PAGE, order: 'publish_date_desc', skip_users: 'all',
            format: 'infinite', counters: 0
          }
          params[:beforePublishTime] = marker if marker
          params[:label] = 'archived' if archived

          page = @client.get("/users/#{user_id}/posts", params)
          Array(page['list']).each { yielder << it }

          marker = page['tailMarker'].to_s
          break unless page['hasMore'] && !marker.empty?
        end
      end
    end

    def messages(user_id)
      Enumerator.new do |yielder|
        last_id = nil
        loop do
          params = { limit: PAGE, order: 'desc', skip_users: 'all' }
          params[:id] = last_id if last_id

          page = @client.get("/chats/#{user_id}/messages", params)
          rows = Array(page['list'])
          rows.each { yielder << it }

          last_id = rows.last&.dig('id')
          break unless page['hasMore'] && last_id
        end
      end
    end

    def paid(user_id)
      Enumerator.new do |yielder|
        offset = 0
        loop do
          page = @client.get('/posts/paid/all', {
                               offset:, limit: PAGE, order: 'publish_date_desc',
                               format: 'infinite', author: user_id
                             })
          rows = Array(page['list'])
          rows.each { yielder << it }

          offset += PAGE
          break unless page['hasMore'] && rows.any?
        end
      end
    end

    # Stories come back as a bare array, not a `list` inside an object.
    def stories(user_id)
      response = @client.get("/users/#{user_id}/stories", {
                               limit: PAGE, order: 'publish_date_desc', skip_users: 'all', format: 'infinite'
                             })
      response.is_a?(Array) ? response : Array(response['list'])
    end

    def highlights(user_id)
      Enumerator.new do |yielder|
        offset = 0
        loop do
          page = @client.get("/users/#{user_id}/stories/highlights", {
                               limit: HIGHLIGHT_PAGE, offset:, sort: 'recent:desc'
                             })
          rows = page.is_a?(Array) ? page : Array(page['list'])
          rows.each do |highlight|
            detail = @client.get("/stories/highlights/#{highlight['id']}", { limit: PAGE })
            Array(detail['stories'] || detail['list']).each { yielder << it }
          end

          offset += HIGHLIGHT_PAGE
          break if rows.size < HIGHLIGHT_PAGE
        end
      end
    end

    private

    def paged_by_offset(path, **params)
      Enumerator.new do |yielder|
        offset = 0
        loop do
          page = @client.get(path, params.merge(offset:, limit: PAGE))
          rows = page.is_a?(Array) ? page : Array(page['list'])
          rows.each { yielder << it }

          offset += PAGE
          has_more = page.is_a?(Hash) && page.key?('hasMore') ? page['hasMore'] : rows.size == PAGE
          break unless has_more && rows.any?
        end
      end
    end
  end
end
