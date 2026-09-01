# frozen_string_literal: true

require 'time'
require 'uri'

module OFDL
  # One media item -- downloadable, or skipped as DRM-protected -- flattened out
  # of a post/message/story row. Worth previewing in the terminal; see
  # Item#image?. Outside the Data.define block, where it would be a constant
  # defined inside a block.
  IMAGE_EXTENSIONS = %w[jpg jpeg png gif webp].freeze

  Item = Data.define(:media_id, :post_id, :source, :post_type, :kind, :posted_at, :url, :protected, :extension,
                     :size) do
    # `size` gives a progress bar its denominator. OnlyFans leaves
    # `files.full.size` empty on most media, so it defaults to zero and the
    # total comes from the response's Content-Length instead.
    def initialize(size: 0, **rest) = super(size: size.to_i, **rest)

    def sized? = size.positive?

    def image? = IMAGE_EXTENSIONS.include?(extension)

    # OnlyFans' own classification, which is more dependable than the extension
    # -- a DRM video arrives as a .mpd manifest.
    def still? = %w[photo gif].include?(kind)

    def video? = kind == 'video'

    def protected? = protected

    # Stable identity for resumption. Excludes the post text: a creator editing
    # a caption must not orphan an already-downloaded file.
    def key = "#{post_id}_#{media_id}"

    def basename = "#{posted_at.strftime('%Y-%m-%d')}_#{key}"

    def filename = "#{basename}.#{extension}"

    # Written in place of a protected video. Keeps the item's basename, so
    # Library#have? matches the marker to the item on the next run.
    def marker_filename = "#{basename}.#{extension}.drm"

    def streaming? = %w[m3u8 mpd].include?(extension)
  end

  # Flattens API rows into Items.
  module Media
    EXTENSION_BY_KIND = { 'photo' => 'jpg', 'video' => 'mp4', 'gif' => 'mp4', 'audio' => 'mp3' }.freeze
    KNOWN_EXTENSIONS = %w[jpg jpeg png gif webp mp4 m4v mov webm mp3 m4a aac m3u8 mpd].freeze

    class << self
      # Rows the account cannot view are dropped: they are locked posts, not
      # failures.
      def from_row(row, source:, post_type:)
        return [] unless row.is_a?(Hash)
        return [] if row['canViewMedia'] == false

        posted_at = timestamp(row)
        Array(row['media']).filter_map { |media| from_media(media, row:, source:, post_type:, posted_at:) }
      end

      # When a row was posted. Public because Api stops paging on it; see
      # Api#posts.
      def posted_at(row) = timestamp(row)

      private

      def from_media(media, row:, source:, post_type:, posted_at:)
        return nil unless media.is_a?(Hash)
        return nil if media['canView'] == false

        files = media['files'] || {}
        drm = files['drm']
        url = drm ? manifest_url(drm) : files.dig('full', 'url')
        return nil if url.to_s.empty?

        kind = media['type'].to_s
        Item.new(
          media_id: media['id'],
          post_id: row['id'],
          source:,
          post_type:,
          kind: kind.empty? ? 'unknown' : kind,
          posted_at:,
          url:,
          protected: !drm.nil?,
          extension: extension_for(url, kind),
          size: files.dig('full', 'size').to_i
        )
      end

      def manifest_url(drm)
        manifest = drm['manifest'] || {}
        manifest['dash'] || manifest['hls']
      end

      def extension_for(url, kind)
        from_url(url) || EXTENSION_BY_KIND.fetch(kind, 'bin')
      end

      def from_url(url)
        path = URI(url.to_s).path.to_s
        ext = File.extname(path).delete_prefix('.').downcase
        KNOWN_EXTENSIONS.include?(ext) ? ext : nil
      rescue URI::InvalidURIError
        nil
      end

      def timestamp(row)
        raw = row['postedAt'] || row['createdAt'] || row['postedAtPrecise']
        case raw
        when String then Time.parse(raw)
        when Numeric then Time.at(raw > 1e11 ? raw / 1000.0 : raw)
        else Time.now
        end
      rescue ArgumentError
        Time.now
      end
    end
  end
end
