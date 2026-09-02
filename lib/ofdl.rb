# frozen_string_literal: true

require_relative 'ofdl/version'
require_relative 'ofdl/errors'
require_relative 'ofdl/logging'
require_relative 'ofdl/config'
require_relative 'ofdl/cookies'
require_relative 'ofdl/chrome'
require_relative 'ofdl/rules'
require_relative 'ofdl/signer'
require_relative 'ofdl/transport'
require_relative 'ofdl/site_state'
require_relative 'ofdl/client'
require_relative 'ofdl/api'
require_relative 'ofdl/advert'
require_relative 'ofdl/source'
require_relative 'ofdl/media'
require_relative 'ofdl/watermark'
require_relative 'ofdl/library'
require_relative 'ofdl/scratch'
require_relative 'ofdl/remux'
require_relative 'ofdl/downloader'
require_relative 'ofdl/palette'
require_relative 'ofdl/thumbnail'
require_relative 'ofdl/display'
require_relative 'ofdl/stats'
require_relative 'ofdl/progress_bar'
require_relative 'ofdl/dashboard'
require_relative 'ofdl/sources/onlyfans'
require_relative 'ofdl/sources/instagram'
require_relative 'ofdl/sources/instagram/media'
require_relative 'ofdl/sources/instagram/tokens'
require_relative 'ofdl/sources/instagram/api'
require_relative 'ofdl/session'
require_relative 'ofdl/status_report'
require_relative 'ofdl/cli'

# Local archiver for OnlyFans subscriptions.
#
# Session cookies are read from the local Chrome profile and are sent only to
# onlyfans.com. Media downloads are authorised by the CloudFront signatures
# OnlyFans returns, and carry no credentials.
#
# DRM-protected video is detected and skipped. See README.md.
module OFDL
end
