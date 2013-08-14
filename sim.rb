require "net/http"
require "oauth"
require "json"
require "rack"
require "rgeo"

######
# Define system variables
####

@@vars = {
	#'walk_speed_kmh' => 4.0+rand()*2,
	'walk_speed_kmh' => 5.0,
	#'walk_speed_ms' => ((4.0+rand()*2)/(60*60))*1000,
	'walk_speed_ms' => (5.0/(60*60))*1000,
	# :buffer_resolution represents the resolution circles should have when converted into polygons
	'factory' => RGeo::Geographic.simple_mercator_factory( :buffer_resolution => 4),
	'lon' => 139.694345,
	'lat' => 35.664641,
	'length' => 25000,
	'timed_requests_threshold' => [25],#,90,270,810],
	'ios_distance_threshold' => [35],#,120,360,1080],
	'thresh_combo_counter' => 0,
	# Threshold to further divide arcs in smaller paths
	# using Luis' magical number to convert degrees to meters
	'walk_thresh' => 25.0/111110.0,
	# Auxiliary lists
	'leaving_a' => [],
	'arriving_a' => [],
	'radii' => {},
	'inside' => [],
	'html_debug_aux_text' => [],
	# Local stat counters and accs
	'request_counter' => 0,
	'request_size' => 0,
	'left_fence_radius' => 0,
	# Global stat counters and accs
	'total_walked_distance' => 0,
	'total_sim_time' => 0,
	'total_request_counter' => 0,
	'total_walked_into_fences' => 0,
	'total_request_size' => 0,
	'total_missed_distance_shapes' => 0,
	'total_missed_time_shapes' => 0,
	'total_geofence_radius' => 0,
	'total_left_fence_radius' => 0,
	'total_visited_shapes' => 0,
	# Counters and accs for misses
	'prev_point' => nil,
	'ellapsed_time' => 0,
	'ellapsed_distance' => 0,
	'missed_distance_shapes_ids' => [],
	'missed_time_shapes_ids' => [],
	'found_distance_shapes_ids' => [],
	'found_time_shapes_ids' => [],
	'visited_shapes_ids' => [],
	## Enable debug/verbose output
	'html_debug' => false,
	'file_output' => false,
	'file_output_filename' => 'console.out',
	'show_intermediate_countings' => false,
	## Sim variables
	# sim_static_walk > 0 uses static paths, =0 uses dynamic paths
	# the number of the chosen path is the 'sim_repetitions' value
	# To chose this exact path number, change the parameter in the get_walk() call
	'sim_static_walk' => 1,
	# geofence_ids (which are in fact geo_object id's according to the JSON spec)
	'sim_geofence_ids' => ['density_0_1', 'density_0_2', 'density_0_3', 'density_0_4', 'density_0_5', 'density_0_6', 'density_0_7', 'density_0_8', 'density_0_9', 'density_1_0'],
	# list of geofence_ids to test
	'sim_geofence_test_id' => [0,1,2,3,4,5,6,7,8,9],
	'sim_repetitions' => 9
}

if @@vars['file_output']
	$stdout.reopen(@@vars['file_output_filename'], "w")
	$stdout.sync = true
end

######
# OAuth setup for Geoluis
####
KEY = "XZJX2HZZEmFPvbfXTLOXXaaUXp1GIHMKzUtkFYZR"
SECRET = "8lkoo3jnitkik7tRwy90udThhlm61h5mE6ttQWCL"
SITE = "http://192.168.13.138:3000/"
HEADERS = { 'Accepts' => 'application/json', 'Content-Type' => 'application/json' }
consumer = OAuth::Consumer.new(KEY, SECRET, site: SITE, http_method: :get)
@@vars['access_token'] = OAuth::AccessToken.new consumer

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
# Uncomment to only get walk paths
# for i in 90.times do
# 	url = "http://localhost:4570/?lon=#{@@vars['lon']}&lat=#{@@vars['lat']}&length=#{@@vars['length']}"
# 	uri = URI.parse(url)
# 	http = Net::HTTP.new("localhost", 4570)
# 	http.read_timeout = nil
# 	resp = http.request(Net::HTTP::Get.new(uri.request_uri))
# 	walk = JSON[resp.body]
# 	puts resp.body
# end
# return
######


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

# Method to calculate system stats
def calculate_sim_stats(fences,walk)
	time = (walk['distance']*111110.0).ceil/@@vars['walk_speed_ms']
	path = "random"
	path = @@vars['sim_static_walk'] if @@vars['sim_static_walk'] > 0

	puts "====== System stats" if @@vars['show_intermediate_countings']
	puts " Walked distance: #{(walk['distance']*111110.0).ceil}m
 Sim time: #{time}s (#{(time/60).floor}m#{(((time/60)-(time/60).floor)*60).floor}s)" if @@vars['show_intermediate_countings']

	# Add to total accumulators
	@@vars['total_walked_distance'] += (walk['distance']*111110.0).ceil
	@@vars['total_sim_time'] += time
 return
end

# Method to calculate stats from each geofence
def calculate_density_stats(fences,geofence_id)
	for fence in fences
		next if fence['foreign_id'] != fences[geofence_id]['foreign_id']

		# Create a fake polygon with the bounding boxes of the existing polygons
		# We will use this polygon to create the fence bounding box
		# And use it to calculate the working area
		points = []
		for shape in fence['shapes']
			points << @@vars['factory'].point(shape['nw_corner'][0],shape['nw_corner'][1])
			points << @@vars['factory'].point(shape['se_corner'][0],shape['se_corner'][1])
		end

		if points[0] == nil
			puts "Error: No polygons in this geofence!"
			exit
		end

		# A ring has to have 3 points, let's create a fake point in the middle when we only have two points
		if points.length <= 2
			points << @@vars['factory'].point((points[0].x()+points[1].x())/2,(points[0].y()+points[1].y())/2)
		end

		# Create fake polygon with working area
		linearring = @@vars['factory'].linear_ring(points)
		geom = @@vars['factory'].polygon(linearring)

		# Create bounding box of the working area from the fake polygon
		bbox = RGeo::Cartesian::BoundingBox.create_from_geometry(geom)

		# Make a polygon from the bounding box so we can calculate the area
		bboxpoly = @@vars['factory'].polygon(@@vars['factory'].linear_ring([@@vars['factory'].point(bbox.min_x(),bbox.max_y()),@@vars['factory'].point(bbox.max_x(),bbox.max_y()),@@vars['factory'].point(bbox.max_x(),bbox.min_y()),@@vars['factory'].point(bbox.min_x(),bbox.min_y())]))
		bbox_area = bboxpoly.area/1000**2

		puts "==== Density stats"
		puts " Name: #{fence['name']}
 id: #{fence['foreign_id']}
 Number of polygons: #{fence['shapes'].length}
 Simulation area: #{bbox_area} km^2
 Density: #{fence['area']/bbox_area}
 Avg Shape area: #{(fence['area']/fence['shapes'].length)} km^2
 Timed request threshold: #{@@vars['timed_requests_threshold'][@@vars['thresh_combo_counter']]} s
 iOS blackbox threshold: #{@@vars['ios_distance_threshold'][@@vars['thresh_combo_counter']]} m"
	end
	return
end

# Method to calculate stats from each run
def calculate_run_stats(fences,walk,geofence_id,global_stats)
	for fence in fences
		if not global_stats
			next if fence['foreign_id'] != fences[geofence_id]['foreign_id']
		end

		fence_radii = 0
		for shape in fence['shapes']
			if shape['type'] == 'circle'
				fence_radii += shape['radius']
			end
		end

		# Put some order in the shape ids, flattening the trees and getting rid of repeated values
		@@vars['missed_distance_shapes_ids'].flatten!.uniq! if @@vars['missed_distance_shapes_ids'].length > 0
		@@vars['missed_time_shapes_ids'].flatten!.uniq! if @@vars['missed_time_shapes_ids'].length > 0
		@@vars['found_distance_shapes_ids'].flatten!.uniq! if @@vars['found_distance_shapes_ids'].length > 0
		@@vars['found_time_shapes_ids'].flatten!.uniq! if @@vars['found_time_shapes_ids'].length > 0

		if @@vars['visited_shapes_ids'].length > 0
			# We want to keep the order of all visited shapes, so we cannot get rid of repeated values here
			@@vars['visited_shapes_ids'].flatten!
			# Some regex magic to cluster the values
			@@vars['visited_shapes_ids'] = @@vars['visited_shapes_ids'].join(",").gsub(/[,]{2,}/, "-").split('-').map{|x| x.split(',').uniq}.flatten
		end
		
		missed_fences_by_distance = (@@vars['missed_distance_shapes_ids'] - @@vars['found_distance_shapes_ids']).count
		missed_fences_by_time = (@@vars['missed_time_shapes_ids'] - @@vars['found_time_shapes_ids']).count
		visited_shapes = @@vars['visited_shapes_ids'].length

		puts "== Run stats" if @@vars['show_intermediate_countings']
		puts " Number of requests: #{@@vars['request_counter']}
 # of circular fences walked into: #{@@vars['walked_into_fences']}
 # of visited shapes: #{visited_shapes}
 Avg request size: #{@@vars['request_size']/@@vars['request_counter']} bytes
 iOS black fence misses (#{@@vars['ios_distance_threshold'][@@vars['thresh_combo_counter']]}m): #{missed_fences_by_distance}
 Timed requests fence misses (#{@@vars['timed_requests_threshold'][@@vars['thresh_combo_counter']]}s): #{missed_fences_by_time}
 Avg geofence radius: #{fence_radii*1.0/fence['shapes'].length} m
 Avg JSON leave fence radius: #{@@vars['left_fence_radius']/@@vars['request_counter']} m" if @@vars['show_intermediate_countings']
		puts "==========" if @@vars['show_intermediate_countings']

		# Add to total accumulators
		@@vars['total_request_counter'] += @@vars['request_counter']
		@@vars['total_walked_into_fences'] += @@vars['walked_into_fences']
		@@vars['total_request_size'] += @@vars['request_size']/@@vars['request_counter']
		@@vars['total_missed_distance_shapes'] += missed_fences_by_distance
		@@vars['total_missed_time_shapes'] += missed_fences_by_time
		@@vars['total_visited_shapes'] += visited_shapes
		@@vars['total_geofence_radius'] += fence_radii*1.0/fence['shapes'].length
		@@vars['total_left_fence_radius'] += @@vars['left_fence_radius']/@@vars['request_counter']
	end
	return
end

def show_average_stats()
	time = @@vars['total_sim_time']/@@vars['sim_repetitions']
	#Print averages
	puts " Total walked distance: #{@@vars['total_walked_distance']/@@vars['sim_repetitions']} m
 Total sim time: #{time}s (#{(time/60).floor}m#{(((time/60)-(time/60).floor)*60).floor}s)
 ====
 Total avg number of requests: #{@@vars['total_request_counter']*1.0/@@vars['sim_repetitions']}
 Total avg # of circular fences walked into: #{@@vars['total_walked_into_fences']*1.0/@@vars['sim_repetitions']}
 Total avg # of visited shapes: #{@@vars['total_visited_shapes']*1.0/@@vars['sim_repetitions']}
 Total avg request size: #{@@vars['total_request_size']*1.0/@@vars['sim_repetitions']}
 Total avg iOS black fence misses (#{@@vars['ios_distance_threshold'][@@vars['thresh_combo_counter']]}m): #{@@vars['total_missed_distance_shapes']*1.0/@@vars['sim_repetitions']}
 Total avg timed requests fence misses (#{@@vars['timed_requests_threshold'][@@vars['thresh_combo_counter']]}s): #{@@vars['total_missed_time_shapes']*1.0/@@vars['sim_repetitions']}
 Total avg geofence radius: #{@@vars['total_geofence_radius']*1.0/@@vars['sim_repetitions']} m
 Total avg JSON leave fence radius: #{@@vars['total_left_fence_radius']*1.0/@@vars['sim_repetitions']} m"

	# Erase counters
	@@vars['total_walked_distance'] = 0
	@@vars['total_sim_time'] = 0
	@@vars['total_request_counter'] = 0
	@@vars['total_walked_into_fences'] = 0
	@@vars['total_request_size'] = 0
	@@vars['total_missed_distance_shapes'] = 0
	@@vars['total_missed_time_shapes'] = 0
	@@vars['total_geofence_radius'] = 0
	@@vars['total_left_fence_radius'] = 0
	return
end

# Get shapes for current point
def shapes_here(point,shapes)
	local_shapes = []
	for shape in shapes
		if shape['type'] == 'circle'
			# Generate polygon for circle
	  		center = @@vars['factory'].point(shape['generators'][0][0],shape['generators'][0][1])
	  		poly = center.buffer(shape['radius'])

			if point.within?(poly)
				local_shapes << shape['id']
			end
		elsif shape['type'] == 'polygon'
			# Generate polygon from points
			gen_points = []
			for p in shape['generators']
				gen_points << @@vars['factory'].point(p[0],p[1])
			end
			ring = @@vars['factory'].linear_ring(gen_points)
			poly = @@vars['factory'].polygon(ring)

			if point.within?(poly)
				local_shapes << shape['id']
			end
		end
	end
	return local_shapes
end

# Method to calculate fence misses from blackbox and timed request methods
def calculate_misses (point,geo_id,shapes)
	# In how many shapes is this point inside?
	known_shapes = shapes_here(point,shapes)

	if @@vars['prev_point'] == nil
		@@vars['prev_point'] = point
		# We would make a request now, so we should discard the shapes as unknown
		#known_shapes = shapes_here(point,shapes)
		@@vars['found_distance_shapes_ids'] << known_shapes
		@@vars['found_time_shapes_ids'] << known_shapes
		@@vars['visited_shapes_ids'] << known_shapes
	end

	# Count all the visited shapes
	# We don't include shapes visited in a row
	if known_shapes.length == 0
		@@vars['visited_shapes_ids'] << nil
	else
		@@vars['visited_shapes_ids'] << known_shapes
	end

	# If the distance is lower than ios_distance_threshold meters
	if @@vars['ellapsed_distance'] < @@vars['ios_distance_threshold'][@@vars['thresh_combo_counter']]
		@@vars['ellapsed_distance'] += distance([@@vars['prev_point'].x(),@@vars['prev_point'].y()],[point.x(),point.y()])*111110
		@@vars['missed_distance_shapes_ids'] << known_shapes
	else
		@@vars['ellapsed_distance'] = 0
		# We would make a request now, so we should discard the shapes as unknown
		@@vars['found_distance_shapes_ids'] << known_shapes
	end

	# If the ellapsed walk time is smaller than timed_requests_threshold seconds
	if @@vars['ellapsed_time'] < @@vars['timed_requests_threshold'][@@vars['thresh_combo_counter']]
		@@vars['ellapsed_time'] += distance([@@vars['prev_point'].x(),@@vars['prev_point'].y()],[point.x(),point.y()])*111110/@@vars['walk_speed_ms']
		@@vars['missed_time_shapes_ids'] << known_shapes
	else
		@@vars['ellapsed_time'] = 0
		# We would make a request now, so we should discard the shapes as unknown
		@@vars['found_time_shapes_ids'] << known_shapes
	end

	@@vars['prev_point'] = point
end

# Method to get the geofences
def get_fences(*args)
	fences = @@vars['access_token'].request(:get, "/api/v3/geo_fences", HEADERS)
	result = nil
	if args.length > 0
		aux = JSON[fences.body][args[0]]
		for i in aux['shapes']
			i['points'] = []
		end
		result = [aux.to_json]

	else
		result = fences.body
	end

	return result
end

# Method to handle server requests
def make_req(point,geofence_id)
	# Deleting old fences
	@@vars['leaving_a'] = []
	@@vars['arriving_a'] = []
	@@vars['radii'] = {}

	debug_c = []
	debug_r = []
	debug_t = []

	@@vars['request_counter'] += 1

	data = {
		'device' => {
			'name' => 'Sim_fake_device',
			'foreign_id' => 'sim_id_1',
			'location' => {
				'lon' => "#{point[0]}", 
				'lat' => "#{point[1]}"
			}
		},
		'speed' => "#{@@vars['walk_speed_ms']}",
		'geo_object_ids' => [@@vars['sim_geofence_ids'][geofence_id]]
	}

	response = @@vars['access_token'].put("/api/v3/devices.json", JSON[data], HEADERS)

	@@vars['request_size'] += response.body.length

	if response && response.code == "200"
	  puts "Got #{JSON[response.body]['sleep_until'].length} new fences" if @@vars['sim_static_walk'] < 1
	  for fence in JSON[response.body]['sleep_until'] do
	  	debug_c << fence['center']
	  	debug_r << fence['radius']
	  	debug_t << fence['status']
	  	if fence['type'] == 'circle'

	  		center = @@vars['factory'].point(fence['center'][0],fence['center'][1])
	  		poly = center.buffer(fence['radius'])

	  		# Add poly to leaving list
	  		if fence['status'] == 'LEAVING'
	  			#puts "Got leaving fence"
	  			@@vars['leaving_a'] << poly
	  			@@vars['radii'][poly] = fence['radius']
	  		end

	  		# Add poly to arriving list
  			if fence['status'] == 'ARRIVING'
  				#puts "Got arriving fence"
  				@@vars['arriving_a'] << poly
  				@@vars['radii'][poly] = fence['radius']
  			end
	  	else
	  		puts "ERROR! The returned fences should only be circles!"
	  	end
	  	#puts poly
	  end
	  #puts jj JSON[response.body]['sleep_until']  # require "json" for this to work.
	else
	  #puts jj JSON[response.body]['sleep_until']  # require "json" for this to work.
	end

	if @@vars['html_debug']
		#puts "{\"centers\": #{debug_c}, \"radii\": #{debug_r}}"
		@@vars['html_debug_aux_text'] << "{\"centers\": #{debug_c}, \"radii\": #{debug_r}, \"type\": #{debug_t}}"
	end
end

######
# Get walk data from walk server
####
def get_walk(*args)
	if args.length > 0
		path_num = args[0]
	else
		path_num = @@vars['sim_static_walk']
	end

	if args.length > 0
		# This side loads the JSON with the walks
		require("./walks_#{@@vars['length']}m.rb")
		walk = JSON[@@test_data[path_num-1]]
		new_walk = JSON[@@test_data[path_num-1]]
	else
		url = "http://localhost:4570/?lon=#{@@vars['lon']}&lat=#{@@vars['lat']}&length=#{@@vars['length']}"
		resp = Net::HTTP.get_response(URI.parse(url))
		walk = JSON[resp.body]
		# Uncomment to get a random path
		#puts resp.body
		#return

		new_walk = JSON[resp.body]
	end
	puts "Got initial walk with #{walk['body'].length} points" if @@vars['show_intermediate_countings']

	######
	# Pre-process walk
	####
	# Inject intermediate points according to @@vars['walk_thresh']
	new_walk['body'] = []
	for c in (walk['body'].length-1).times do
		dist = distance(walk['body'][c],walk['body'][c+1])
		new_walk['body'] << walk['body'][c]
		aux = walk['body'][c]

		# If the hop is too long
		if dist > @@vars['walk_thresh']
			# Calculate in how many segments to divide the hop
			part = (dist/@@vars['walk_thresh']).ceil
			# Calculate the distance for each segment
			d_x = aux[0]>walk['body'][c+1][0] ? (aux[0]-walk['body'][c+1][0]).abs/part : (walk['body'][c+1][0]-aux[0]).abs/part
			d_y = aux[1]>walk['body'][c+1][1] ? (aux[1]-walk['body'][c+1][1]).abs/part : (walk['body'][c+1][1]-aux[1]).abs/part

			while dist > @@vars['walk_thresh']
				x = aux[0] > walk['body'][c+1][0] ? aux[0]-d_x : aux[0]+d_x
				y = aux[1] > walk['body'][c+1][1] ? aux[1]-d_y : aux[1]+d_y
				aux = [x,y]

				new_walk['body'] << aux
				dist = distance(aux,walk['body'][c+1])
			end
		end
	end

	puts "Re-sampled new walk with #{new_walk['body'].length} points" if @@vars['show_intermediate_countings']

	return new_walk, walk
end

######
# Simulate
####

# Test each of the timed_requests_threshold/distance_requests_threshold combos
for thresh_combo in @@vars['timed_requests_threshold'].count.times do
	@@vars['thresh_combo_counter'] = thresh_combo

	# Test each of the @@var['sim_geofence_test_id']'s
	for geo_id in @@vars['sim_geofence_test_id']

		puts "\n_~^ Starting tests for geofence #{@@vars['sim_geofence_ids'][geo_id]} #{@@vars['walk_speed_kmh']}km/h #{@@vars['timed_requests_threshold'][@@vars['thresh_combo_counter']]}s #{@@vars['ios_distance_threshold'][@@vars['thresh_combo_counter']]}m ^~_"
		calculate_density_stats(JSON[get_fences()],geo_id)

		for w in @@vars['sim_repetitions'].times do

			puts "\n_~^ Starting test with path #{w} ^~_" if @@vars['show_intermediate_countings']
			print "." if !@@vars['show_intermediate_countings']

			# This will iteratively chose a different path[w] from the static paths array
			# If you need to have the same path drawn (w times) use get_walk() with no argument
			walk, original_walk = get_walk(w+1)

			# Init counters
			@@vars['request_counter'] = 0
			@@vars['request_size'] = 0
			@@vars['left_fence_radius'] = 0
			@@vars['ellapsed_distance'] = 0
			@@vars['ellapsed_time'] = 0
			@@vars['walked_into_fences'] = 0

			# Init arrays
			@@vars['missed_distance_shapes_ids'] = []
			@@vars['missed_time_shapes_ids'] = []
			@@vars['found_distance_shapes_ids'] = []
			@@vars['found_time_shapes_ids'] = []

			geoid_fences = JSON[get_fences(geo_id).inspect.gsub('"{','{').gsub('}"','}').gsub('\"','"')][0]

			# Initial request
			make_req(walk['body'][0],geo_id)

			# Cycle through all the points in the walk
			for point in walk['body'] do
				rgeo_point = @@vars['factory'].point(point[0],point[1])
				#puts rgeo_point

				# Calculate fence misses on methods other than SUJ Geo
				calculate_misses(rgeo_point,geo_id,geoid_fences['shapes'])

				# For each polygon in the arriving list
				# check if we already entered
				for p in @@vars['arriving_a'] do
					if rgeo_point.within?(p)
						if @@vars['inside'].index(p) != nil
							# Already detected inside, do nothing
						else
							puts ">>>>>> Arrived fence with radius #{@@vars['radii'][p]}! Making request ..." if @@vars['sim_static_walk'] < 1
							@@vars['walked_into_fences'] += 1
							@@vars['inside'] << p
							#@@vars['arriving_a'].delete(p)
							#@@vars['radii'].delete(p)
							# Make request
							make_req(point,geo_id)
						end
					else
						# Do nothing
						#puts "====== Still outside, doing nothing"
					end
				end

				# For each polygon in the leaving list
				# check if we already left
				for p in @@vars['leaving_a'] do
					if rgeo_point.within?(p)
						# Do nothing
						#puts "====== Still inside, doing nothing"
					else
						puts "<<<<<< Left fence with radius #{@@vars['radii'][p]}! Making request ..." if @@vars['sim_static_walk'] < 1 
						@@vars['left_fence_radius'] += @@vars['radii'][p]
						#@@vars['leaving_a'].delete(p)
						#@@vars['radii'].delete(p)
						@@vars['inside'] = []
						# Make request
						make_req(point,geo_id)
					end
				end
			end

			calculate_sim_stats(JSON[get_fences()],walk)
			calculate_run_stats(JSON[get_fences()],walk,geo_id,false)

			if @@vars['html_debug'] == true
				puts "====================================================================="
				puts "Copy this into the public/demo.html file for testing."
				puts " === test_fences:"
				puts get_fences(@@vars['sim_geofence_test_id'][0]).inspect.gsub('"{','{').gsub('}"','}').gsub('\"','"')
				puts " === test_circlesRAW:"
				puts @@vars['html_debug_aux_text'].inspect.gsub('"{','{').gsub('}"','}').gsub('\"','"')
				puts " === fakeResponse:"
				puts JSON[original_walk]
			end
		end
		puts "=========" if @@vars['show_intermediate_countings']
		puts "_~^ Finished tests for geofence #{@@vars['sim_geofence_ids'][geo_id]} ^~_"
		show_average_stats()
		puts "========="
	end
end
