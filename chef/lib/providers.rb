#
# Copyright (c) 2009 RightScale Inc
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

# The daemonize method of AR clashes with the daemonize Chef attribute, we don't need that method so undef it
undef :daemonize if methods.include?('daemonize')

# must monkey patch Chef::Mixin::Command before chef loads in Windows in order
# to replace Linux-specific run_command() method.
if RightScale::RightLinkConfig[:platform].windows?
  require File.expand_path(File.join(File.dirname(__FILE__), '..', 'lib', 'mixin', 'command'))
end

require 'chef'
require 'chef/client'

require File.join(File.dirname(__FILE__), 'providers', 'cronv0_7_12')
require File.join(File.dirname(__FILE__), 'providers', 'dns_dnsmadeeasy_provider')
require File.join(File.dirname(__FILE__), 'providers', 'dns_resource')
require File.join(File.dirname(__FILE__), 'providers', 'executable_schedule_provider')
require File.join(File.dirname(__FILE__), 'providers', 'executable_schedule_resource')
require File.join(File.dirname(__FILE__), 'providers', 'log_provider_chef')
require File.join(File.dirname(__FILE__), 'providers', 'log_resource')
require File.join(File.dirname(__FILE__), 'providers', 'remote_recipe_provider')
require File.join(File.dirname(__FILE__), 'providers', 'remote_recipe_resource')
require File.join(File.dirname(__FILE__), 'providers', 'right_link_tag_provider')
require File.join(File.dirname(__FILE__), 'providers', 'right_link_tag_resource')
require File.join(File.dirname(__FILE__), 'providers', 'right_script_provider')
require File.join(File.dirname(__FILE__), 'providers', 'right_script_resource')
require File.join(File.dirname(__FILE__), 'providers', 'server_collection_provider')
require File.join(File.dirname(__FILE__), 'providers', 'server_collection_resource')

# Register all of our custom providers with Chef
#
# FIX: as a suggestion, providers should self-register (merge their key => class
# into the Chef::Platform.platforms[:default] hash after definition) and be
# dynamically loaded from a directory **/*.rb search in the same manner as the
# built-in Chef providers. if so, there would be no need to edit this file for
# each new provider.
Chef::Platform.platforms[:default].merge!(:dns                 => Chef::Provider::DnsMadeEasy,
                                          :executable_schedule => Chef::Provider::ExecutableSchedule,
                                          :log                 => Chef::Provider::Log::ChefLog,
                                          :remote_recipe       => Chef::Provider::RemoteRecipe,
                                          :right_link_tag      => Chef::Provider::RightLinkTag,
                                          :right_script        => Chef::Provider::RightScript,
                                          :server_collection   => Chef::Provider::ServerCollection)

if RightScale::RightLinkConfig[:platform].windows?

  # create the Windows default platform hash before loading win32 providers.
  Chef::Platform.platforms[:windows] = { :default => { } } unless Chef::Platform.platforms[:windows]

  # load (and self-register) all win32 providers
  win32_providers = File.join(File.dirname(__FILE__), 'providers', 'win32', '*.rb').gsub("\\", "/")
  Dir[win32_providers].each do |rb_file|
    require File.expand_path(rb_file)
  end

end
