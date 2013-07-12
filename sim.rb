require "net/http"
require "oauth"
require "json"
require "rack"
require "rgeo"

######
# Define global variables
####
@@walk_speed_kmh = 4.0+rand()*2 #km/h
#@@walk_speed_ms = (@@walk_speed_kmh/(60*60))*1000 #m/s
#@@tick = 1.0/walk_speed_ms #seconds
# :buffer_resolution represents the resolution circles should have when converted into polygons
# Indeed, even for RGeo circles _are_ polygons
@@factory = RGeo::Geographic.simple_mercator_factory(:buffer_resolution => 4)
@@leaving_a = []
@@arriving_a = []
@@radii = {}
@@html_debug = true
@@html_static_test = false
@@html_debug_text = []

######
# OAuth setup for Geoluis
####
KEY = "OSKDaID4Dalto3ONoNKkioqpRgtG2qj118tEjO9j"
SECRET = "2V8vjEfUfpak6o8pfwXsabKM1jkIBFmdGaQBYkdJ"
SITE = "http://geo.skillupjapan.net"
HEADERS = { 'Accepts' => 'application/json', 'Content-Type' => 'application/json' }
consumer = OAuth::Consumer.new(KEY, SECRET, site: SITE, http_method: :get)
@@access_token = OAuth::AccessToken.new consumer

# OAuth monkey patching
module OAuth::RequestProxy::Net
  module HTTP
    class HTTPRequest < OAuth::RequestProxy::Base
      def all_parameters
        request_params = Rack::Utils.parse_nested_query(query_string)
        #request_params = CGI.parse(query_string)
        if options[:parameters]
          options[:parameters].each do |k,v|
            if request_params.has_key?(k) && v
              request_params[k] << v
            else
              request_params[k] = [v]
            end
          end
        end
        request_params
      end
    end
  end
end

######
# Define auxiliar methods
####

# Method to calculate distance between points
# * update with a more geographically correct version
def distance(x,y)
	return Math.sqrt((x[0]-y[0])**2 + (x[1]-y[1])**2)
end

# Method to handle server requests
def make_req(point)
	# Deleting old fences
	@@leaving_a = []
	@@arriving_a = []
	@@radii = {}

	debug_c = []
	debug_r = []

	data = {
		'device' => {
			'name' => 'Sim_fake_device',
			'foreign_id' => 'sim_id_1',
			'location' => {
				'lon' => "#{point[0]}", 
				'lat' => "#{point[1]}"
			}
		},
		'speed' => "#{@@walk_speed_kmh}"
	}

	response = @@access_token.put("/api/v3/devices.json", JSON[data], HEADERS)

	if response && response.code == "200"
	  puts "Got #{JSON[response.body]['sleep_until'].length} new fences"
	  for fence in JSON[response.body]['sleep_until'] do
	  	debug_c << fence['center']
	  	debug_r << fence['radius']
	  	if fence['type'] == 'circle'

	  		center = @@factory.point(fence['center'][0],fence['center'][1])
	  		poly = center.buffer(fence['radius'])

	  		# Add poly to leaving list
	  		if fence['status'] == 'LEAVING'
	  			#puts "Got leaving fence"
	  			@@leaving_a << poly
	  			@@radii[poly] = fence['radius']
	  		end

	  		# Add poly to arriving list
  			if fence['status'] == 'ARRIVING'
  				#puts "Got arriving fence"
  				@@arriving_a << poly
  				@@radii[poly] = fence['radius']
  			end
	  	end
	  	#puts poly
	  end
	  #puts jj JSON[response.body]['sleep_until']  # require "json" for this to work.
	else
	  #puts jj JSON[response.body]['sleep_until']  # require "json" for this to work.
	end

	if @@html_debug or @@html_static_test
		#puts "{\"centers\": #{debug_c}, \"radii\": #{debug_r}}"
		@@html_debug_text << "{\"centers\": #{debug_c}, \"radii\": #{debug_r}}"
	end
end

######
# Get walk data from walk server
####
if (@@html_static_test)
	test_data = '{"distance":0.01855711480024141,"body":[[139.6994996,35.6657032],[139.6995782,35.6656964],[139.6996389,35.6657043],[139.6997465,35.6657774],[139.6997016,35.6663966],[139.6997347,35.6665372],[139.6997568,35.666651],[139.7000179,35.6657559],[139.7001158,35.6657181],[139.7003606,35.6657467],[139.7004236,35.665742],[139.7004752,35.6657258],[139.7006076,35.6656308],[139.7008764,35.6653847],[139.700978,35.6653301],[139.7014896,35.6650943],[139.7028937,35.6641389],[139.7028797,35.6641606],[139.7028592,35.6642055],[139.7029078,35.6643141],[139.7029614,35.6644054],[139.7030126,35.6644695],[139.7030904,35.6645551],[139.7032603,35.6647376],[139.7033411,35.6647595],[139.7040172,35.6637547],[139.7043312,35.6635739],[139.7051218,35.6630668],[139.7053009,35.6629616],[139.7061349,35.6624272],[139.7066613,35.6621213],[139.7067103,35.6620935],[139.7070218,35.6619224],[139.7072794,35.6617521],[139.7073346,35.6617112],[139.7076152,35.6614438],[139.7077123,35.6613459],[139.7088832,35.6603396],[139.7097746,35.6605931],[139.7119626,35.6610383],[139.7121575,35.6608504],[139.7122463,35.6607751],[139.712342,35.6607127],[139.7124545,35.6606483],[139.7128499,35.6619697],[139.7129493,35.6620888],[139.7135611,35.6627148],[139.7142424,35.6634116],[139.714319,35.66349],[139.7146347,35.663813],[139.7146661,35.663846],[139.7167647,35.6633986],[139.7162431,35.6628494],[139.7146349,35.6622081],[139.7141657,35.6624447],[139.7141813,35.661293],[139.7136965,35.6606976],[139.7133211,35.6609076],[139.7137764,35.6614902]]}'
	walk = JSON[test_data]
else
	url = 'http://localhost:4570/?long=139.6926242&lat=35.6668525&length=2000'
	resp = Net::HTTP.get_response(URI.parse(url))
	walk = JSON[resp.body]
end
puts "Got initial walk with #{walk['body'].length} points"

######
# Pre-process walk
####

# Inject intermediate points 
# * 50m threshold, using Luis' magical number to convert degrees to meters
thresh = 25.0/111110.0
if (@@html_static_test)
	new_walk = JSON[test_data]
	old_walk = JSON[test_data]
else
	new_walk = JSON[resp.body]
	old_walk = JSON[resp.body]
end
new_walk['body'] = []
for c in (walk['body'].length-1).times do
	dist = distance(walk['body'][c],walk['body'][c+1])
	new_walk['body'] << walk['body'][c]
	aux = walk['body'][c]

	# If the hop is too long
	if dist > thresh
		# Calculate in how many segments to divide the hop
		part = (dist/thresh).ceil
		# Calculate the distance for each segment
		d_x = aux[0]>walk['body'][c+1][0] ? (aux[0]-walk['body'][c+1][0]).abs/part : (walk['body'][c+1][0]-aux[0]).abs/part
		d_y = aux[1]>walk['body'][c+1][1] ? (aux[1]-walk['body'][c+1][1]).abs/part : (walk['body'][c+1][1]-aux[1]).abs/part

		while dist > thresh
			x = aux[0] > walk['body'][c+1][0] ? aux[0]-d_x : aux[0]+d_x
			y = aux[1] > walk['body'][c+1][1] ? aux[1]-d_y : aux[1]+d_y
			aux = [x,y]

			new_walk['body'] << aux
			dist = distance(aux,walk['body'][c+1])
		end
	end
end

walk = new_walk
puts "Re-sampled new walk with #{walk['body'].length} points"

######
# Simulate geofence behaviour
####

# Initial request
make_req(walk['body'][0])

# Cycle through all the points in the walk
for point in walk['body'] do
	rgeo_point = @@factory.point(point[0],point[1])
	puts rgeo_point

	# For each polygon in the arriving list
	# check if we already entered
	for p in @@arriving_a do
		if rgeo_point.within?(p)
			puts ">>>>>> Arrived fence with radius #{@@radii[p]}! Making request ..."
			@@arriving_a.delete(p)
			@@radii.delete(p)
			# Make request
			make_req(point)
		else
			# Do nothing
			#puts "====== Still outside, doing nothing"
		end
	end

	# For each polygon in the leaving list
	# check if we already left
	for p in @@leaving_a do
		if rgeo_point.within?(p)
			# Do nothing
			#puts "====== Still inside, doing nothing"
		else
			puts "<<<<<< Left fence with radius #{@@radii[p]}! Making request ..."
			@@leaving_a.delete(p)
			@@radii.delete(p)
			# Make request
			make_req(point)
		end
	end
end

if @@html_debug or @@html_static_test
	puts "====================================================================="
	puts "Copy this into the public/demo.html file for testing."
	puts " === test_circlesRAW:"
	puts @@html_debug_text.inspect.gsub('"{','{').gsub('}"','}').gsub('\"','"')
	puts " === fakeResponse:"
	puts old_walk
end
