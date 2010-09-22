#
# Copyright (c) 2010 RightScale Inc
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

require File.expand_path(File.join(File.dirname(__FILE__), 'ec2_metadata_provider'))
require File.expand_path(File.join(File.dirname(__FILE__), 'metadata_fetcher_base'))

module RightScale

  # Implements MetadataFetcher for EC2.
  class Ec2MetadataFetcher < MetadataFetcherBase

    # === Parameters
    # options[:retry_delay_secs](float):: retry delay in seconds.
    #
    # options[:max_curl_retries](int):: max attempts to invoke cURL for a given URL before failure.
    #
    # options[:logger](Logger):: logger (required)
    def initialize(options)
      super(Ec2MetadataProvider.new(options))
    end

    protected

    # Decorates flat metadata names with 'EC2_'.
    #
    # === Parameters
    # metadata_path(Array):: array of metadata path elements
    #
    # === Returns
    # flat_path(String):: flattened path
    def flatten_metadata_path(metadata_path)
      'EC2_' + super(metadata_path)
    end

  end

end
