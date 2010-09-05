%w[
  rubygems
  logger
  json
  find
].each do |file|
  require file
end

# Dynamically load all files in lib
Find.find(  File.join(File.dirname(__FILE__), 'lib') ) do |file|
  next if File.extname(file) != '.rb'
  STDOUT.puts "Loading #{file} ..."
  require file
end

# XXX: We're letting consumers raise HTTP400BadRequest
#    versus raise RESTRack::HTTPStatus::ClientErrorCodes::HTTP400BadRequest
include RESTRack::HTTPStatus::ClientErrorCodes