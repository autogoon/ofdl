# frozen_string_literal: true

module OFDL
  module Sources
    class Instagram
      # Flattens Instagram rows into Items.
      #
      # A row's `media_type` says what it holds and `product_type` says what it
      # is: a reel is a video whose product_type is "clips", and it carries its
      # thumbnail in the same row.
      module Media
        PHOTO = 1
        VIDEO = 2
        CAROUSEL = 8

        # The role the thumbnail's media id carries, so a reel's two files do
        # not share a key; see Library::MEDIA_ID.
        THUMBNAIL_ROLE = 'thumb'

        REEL = 'clips'

        class << self
          def from_row(row, post_type:)
            return [] unless row.is_a?(Hash)

            post_id = row['pk'] || row['id']
            posted_at = timestamp(row)
            children(row).flat_map { files_for(it, row, post_id:, posted_at:, post_type:) }
          end

          def reel?(row) = row['product_type'] == REEL

          # The two keys a reel's pk will produce, derived without the request
          # that learns its video URL. A rerun asks the library for both keys
          # and skips that request; see Sources::Instagram#walk_reels.
          def keys_for(media_id) = ["#{media_id}_#{media_id}", "#{media_id}_#{media_id}_#{THUMBNAIL_ROLE}"]

          private

          # A carousel's children are the media; the container has no file of
          # its own. Anything else is its own single child.
          def children(row)
            row['media_type'] == CAROUSEL ? Array(row['carousel_media']) : [row]
          end

          def files_for(media, row, post_id:, posted_at:, post_type:)
            media_id = media['pk'] || media['id'] || post_id
            common = { post_id:, posted_at:, post_type: }

            return [photo(media, media_id:, **common)].compact if media['media_type'] != VIDEO

            video = video(media, media_id:, **common)
            return [] unless video
            return [video] unless reel?(row)

            [video, photo(media, media_id: "#{media_id}_#{THUMBNAIL_ROLE}", **common)].compact
          end

          def photo(media, media_id:, post_id:, posted_at:, post_type:)
            url = widest(media['image_versions2']) or return nil

            item(url, media_id:, post_id:, posted_at:, post_type:, kind: 'photo')
          end

          def video(media, media_id:, post_id:, posted_at:, post_type:)
            url = widest_video(media['video_versions']) or return nil

            item(url, media_id:, post_id:, posted_at:, post_type:, kind: 'video')
          end

          def item(url, media_id:, post_id:, posted_at:, post_type:, kind:)
            Item.new(
              media_id:, post_id:, source: Source::INSTAGRAM, post_type:, kind:,
              posted_at:, url:, protected: false, extension: OFDL::Media.extension_for(url, kind)
            )
          end

          # The candidates arrive widest first, and the widest is the original
          # upload -- but the order is the response's, not a guarantee, so the
          # width is compared rather than the position.
          def widest(versions)
            candidates = versions.is_a?(Hash) ? Array(versions['candidates']) : []
            candidates.max_by { it['width'].to_i }&.dig('url')
          end

          def widest_video(versions) = Array(versions).max_by { it['width'].to_i }&.dig('url')

          # Unix seconds, unlike OnlyFans' ISO strings.
          def timestamp(row)
            raw = row['taken_at'] || row['device_timestamp']
            raw.is_a?(Numeric) ? Time.at(raw) : Time.now
          end
        end
      end
    end
  end
end
