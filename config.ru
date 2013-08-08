# In order to increase the timeout, one should change it at Thin level
# For that, run with:
# thin start -t 120 -p 4570

require './server.rb'

run Sinatra::Application.new