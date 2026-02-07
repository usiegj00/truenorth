# frozen_string_literal: true

require_relative 'truenorth/version'
require_relative 'truenorth/client'
require_relative 'truenorth/config'

module Truenorth
  class Error < StandardError; end
  class AuthenticationError < Error; end
  class BookingError < Error; end
end
