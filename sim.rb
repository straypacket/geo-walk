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
@@html_debug = false
@@html_static_test = 0
@@html_debug_text = []
@@inside = []

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

# Luisian algorithm to calculate area
def calculate_area_and_centroid(points)
	n = points.size.to_i
	area_sum = 0.0; cx_sum = 0.0; cy_sum = 0.0

	for i in 0..n-1
	  x0 = points[i%n][0]
	  y1 = points[(i+1)%n][1]
	  x1 = points[(i+1)%n][0]
	  y0 = points[i%n][1]

	  factor = x0*y1 - x1*y0
	  area_sum += factor
	  cx_sum   += factor * (x0 + x1)
	  cy_sum   += factor * (y0 + y1)
	end

	if points.size > 1
	  factor = 3 * area_sum

	  cx_sum /= factor
	  cy_sum /= factor
	else
	  cx_sum, cy_sum = points.first
	end
	area_sum *= 0.5

	area = (111*90*area_sum).abs
	centroid = [cx_sum, cy_sum]

	return area
end

# Method to calculate distance between points
# * update with a more geographically correct version
def distance(x,y)
	return Math.sqrt((x[0]-y[0])**2 + (x[1]-y[1])**2)
end

# Method to calculate stats from each geofence
def calculate_stats(fences)
	for fence in fences
		points = []
		for shape in fence['shapes']
			points << @@factory.point(shape['nw_corner'][0],shape['nw_corner'][1])
			points << @@factory.point(shape['se_corner'][0],shape['se_corner'][1])
		end

		# A ring has to have 3 points, let's create a fake point in the middle
		if points.length <= 2
			points << @@factory.point((points[0].x()+points[1].x())/2,(points[0].y()+points[1].y())/2)
		end

		linearring = @@factory.linear_ring(points)
		geom = @@factory.polygon(linearring)
		bbox = RGeo::Cartesian::BoundingBox.create_from_geometry(geom)
		puts "=========="
		bbox_area = calculate_area_and_centroid([[bbox.min_x(),bbox.max_y()],[bbox.max_x(),bbox.max_y()],[bbox.max_x(),bbox.min_y()],[bbox.min_x(),bbox.min_y()]])
		puts " Name: #{fence['name']}\n # polygons: #{fence['shapes'].length}\n Area: #{fence['area']}\n BBox area: #{bbox_area}\n density: #{fence['area']/bbox_area}"
		puts "=========="
	end
	return
end

# Method to get the geofences
def get_fences()
	fences = @@access_token.request(:get, "/api/v3/geo_fences", HEADERS)
	return fences.body
end

# Method to handle server requests
def make_req(point)
	# Deleting old fences
	@@leaving_a = []
	@@arriving_a = []
	@@radii = {}

	debug_c = []
	debug_r = []
	debug_t = []

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
	  	debug_t << fence['status']
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
		@@html_debug_text << "{\"centers\": #{debug_c}, \"radii\": #{debug_r}, \"type\": #{debug_t}}"
	end
end

######
# Get walk data from walk server
####
if (@@html_static_test and @@html_debug)
	test_data = [
		'{"distance":0.01855711480024141,"body":[[139.6994996,35.6657032],[139.6995782,35.6656964],[139.6996389,35.6657043],[139.6997465,35.6657774],[139.6997016,35.6663966],[139.6997347,35.6665372],[139.6997568,35.666651],[139.7000179,35.6657559],[139.7001158,35.6657181],[139.7003606,35.6657467],[139.7004236,35.665742],[139.7004752,35.6657258],[139.7006076,35.6656308],[139.7008764,35.6653847],[139.700978,35.6653301],[139.7014896,35.6650943],[139.7028937,35.6641389],[139.7028797,35.6641606],[139.7028592,35.6642055],[139.7029078,35.6643141],[139.7029614,35.6644054],[139.7030126,35.6644695],[139.7030904,35.6645551],[139.7032603,35.6647376],[139.7033411,35.6647595],[139.7040172,35.6637547],[139.7043312,35.6635739],[139.7051218,35.6630668],[139.7053009,35.6629616],[139.7061349,35.6624272],[139.7066613,35.6621213],[139.7067103,35.6620935],[139.7070218,35.6619224],[139.7072794,35.6617521],[139.7073346,35.6617112],[139.7076152,35.6614438],[139.7077123,35.6613459],[139.7088832,35.6603396],[139.7097746,35.6605931],[139.7119626,35.6610383],[139.7121575,35.6608504],[139.7122463,35.6607751],[139.712342,35.6607127],[139.7124545,35.6606483],[139.7128499,35.6619697],[139.7129493,35.6620888],[139.7135611,35.6627148],[139.7142424,35.6634116],[139.714319,35.66349],[139.7146347,35.663813],[139.7146661,35.663846],[139.7167647,35.6633986],[139.7162431,35.6628494],[139.7146349,35.6622081],[139.7141657,35.6624447],[139.7141813,35.661293],[139.7136965,35.6606976],[139.7133211,35.6609076],[139.7137764,35.6614902]]}',
		'{"distance":0.01838448581082566,"body":[[139.6997568,35.666651],[139.6998543,35.6670942],[139.6997347,35.6665372],[139.7000152,35.6665468],[139.7002847,35.6665547],[139.7006895,35.6664676],[139.7006266,35.6665104],[139.7005704,35.6665249],[139.7005068,35.6665125],[139.7004148,35.6664693],[139.7002882,35.6663608],[139.6994996,35.6657032],[139.6995782,35.6656964],[139.6996389,35.6657043],[139.6997465,35.6657774],[139.7000152,35.6665468],[139.7002882,35.6663608],[139.7010999,35.6667305],[139.701208,35.6668598],[139.7014516,35.66687],[139.7014418,35.6669992],[139.7020374,35.6654916],[139.7022502,35.6654462],[139.7028268,35.6653454],[139.7029913,35.6652658],[139.7028937,35.6641389],[139.7028797,35.6641606],[139.7028592,35.6642055],[139.7029078,35.6643141],[139.7029614,35.6644054],[139.7030126,35.6644695],[139.7030904,35.6645551],[139.7032603,35.6647376],[139.7033411,35.6647595],[139.7040386,35.6653562],[139.7041494,35.6652797],[139.704262,35.6652081],[139.7044404,35.6650128],[139.7035761,35.6643175],[139.7042583,35.6647485],[139.7049147,35.66482],[139.7051769,35.6643503],[139.7055081,35.6645412],[139.7052339,35.664896],[139.7064573,35.665663],[139.7066718,35.665353],[139.7062025,35.665522],[139.706545,35.6651608],[139.7072701,35.6652068],[139.7069542,35.6649935],[139.7066424,35.664809],[139.7062869,35.6646207],[139.7066436,35.6642663],[139.7072752,35.6638266],[139.7074607,35.6637305],[139.7073689,35.663597],[139.7075614,35.6635176],[139.7079319,35.6640603],[139.7076134,35.6645692],[139.707878,35.6643604],[139.7079818,35.6643072],[139.708025,35.6642869],[139.7081504,35.6642671],[139.7082026,35.6642766],[139.708381,35.6644338]]}',
		'{"distance":0.019089555171858213,"body":[[139.6979236,35.6669531],[139.6979409,35.6668709],[139.6979687,35.6667758],[139.6979981,35.6666938],[139.6980284,35.6666264],[139.6981863,35.6663215],[139.6974508,35.667105],[139.6971175,35.667718],[139.6957726,35.6684739],[139.6958451,35.6684899],[139.6959265,35.6684972],[139.6960274,35.6684966],[139.6962123,35.668465],[139.6962816,35.6684533],[139.6963539,35.6684492],[139.6964324,35.6684525],[139.6964675,35.6684386],[139.6965645,35.6684389],[139.6973763,35.6684766],[139.6974129,35.6684913],[139.6975346,35.6683054],[139.6975248,35.6684524],[139.698664,35.6681459],[139.6986702,35.6675154],[139.6984688,35.6674045],[139.6992594,35.6669198],[139.699592,35.6666487],[139.6993265,35.6654966],[139.699493,35.6653777],[139.6984418,35.6651256],[139.6983591,35.6652677],[139.6977451,35.665248],[139.6973114,35.6652341],[139.698489,35.6648126],[139.6986238,35.6648264],[139.6986834,35.664836],[139.6988208,35.6648762],[139.6988617,35.6648994],[139.698957,35.6649555],[139.6990391,35.6650189],[139.6993244,35.6652587],[139.6994063,35.6652989],[139.699493,35.6653777],[139.6997447,35.6656063],[139.6997896,35.6656882],[139.7005491,35.6664375],[139.7006266,35.6665104],[139.7006577,35.6665396],[139.700713,35.6665767],[139.7007541,35.6666025],[139.7008105,35.6666345],[139.700872,35.6666663],[139.700921,35.6666855],[139.7009745,35.6667029],[139.7010469,35.6667208],[139.7010999,35.6667305],[139.701123,35.6667348],[139.7012705,35.6667527],[139.7014794,35.6667731],[139.7015844,35.6667824],[139.7016813,35.6668651],[139.7016894,35.6668805],[139.7017377,35.6674415],[139.7018033,35.6680952],[139.7018282,35.6683743],[139.7018986,35.6687568],[139.7021583,35.6690891],[139.702325,35.6691596],[139.7028527,35.6693914],[139.7027896,35.6695729],[139.7029614,35.6695889],[139.7033195,35.6695031],[139.7037855,35.6692835],[139.7031649,35.6697423],[139.7031874,35.669755],[139.7033104,35.6698239],[139.7034243,35.6698064],[139.7035905,35.6698639],[139.7036363,35.6698718],[139.7036881,35.6698785],[139.7038786,35.6699354],[139.7040127,35.6699726],[139.7030793,35.6696652],[139.7029485,35.6697122],[139.702724,35.6697799],[139.7029485,35.6697122],[139.7029598,35.6694161],[139.7030967,35.669382],[139.703191,35.6693449],[139.7038798,35.669033],[139.7041712,35.6689],[139.7047319,35.6686409],[139.7051015,35.6684703],[139.7051462,35.6684101],[139.7051822,35.668365],[139.7052494,35.6683343],[139.705377,35.6682796]]}'
	]
	if @@html_static_test-1 >= test_data.length or @@html_static_test < 0
		puts "Wrong number of test_data set"
		return 0
	end
	walk = JSON[test_data[@@html_static_test-1]]
else
	url = 'http://localhost:4570/?lon=139.698345&lat=35.666641&length=2000'
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
if (@@html_static_test and @@html_debug)
	new_walk = JSON[test_data[@@html_static_test-1]]
	old_walk = JSON[test_data[@@html_static_test-1]]
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
			if @@inside.index(p) != nil
				# Already detected inside, do nothing
			else
				puts ">>>>>> Arrived fence with radius #{@@radii[p]}! Making request ..."
				@@inside << p
				#@@arriving_a.delete(p)
				#@@radii.delete(p)
				# Make request
				make_req(point)
			end
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
			#@@leaving_a.delete(p)
			#@@radii.delete(p)
			@@inside = []
			# Make request
			make_req(point)
		end
	end
end

puts "====================================================================="
puts calculate_stats(JSON[get_fences()])

if (@@html_debug == true or @@html_static_test > 0)
	puts "====================================================================="
	puts "Copy this into the public/demo.html file for testing."
	puts " === test_fences:"
	puts get_fences()
	puts " === test_circlesRAW:"
	puts @@html_debug_text.inspect.gsub('"{','{').gsub('}"','}').gsub('\"','"')
	puts " === fakeResponse:"
	puts JSON[old_walk]
end
