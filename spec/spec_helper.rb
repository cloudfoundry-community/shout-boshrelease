require 'erb'
require 'bosh/template/test'
require 'yaml'
require 'open3'

RELEASE_DIR = File.expand_path('..', __dir__)
