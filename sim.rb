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
	'length' => 2000,
	'timed_requests_threshold' => 30,
	'ios_distance_threshold' => 40,
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
	# Counters and accs for misses
	'prev_point' => nil,
	'ellapsed_time' => 0,
	'ellapsed_distance' => 0,
	'missed_distance_shapes_ids' => [],
	'missed_time_shapes_ids' => [],
	'found_distance_shapes_ids' => [],
	'found_time_shapes_ids' => [],
	## Enable debug/verbose output
	'html_debug' => false,
	'show_intermediate_countings' => false,
	## Sim variables
	# sim_static_walk >0 uses a static walk, =0 uses dynamic paths
	'sim_static_walk' => 1,
	# geofence_ids (which are in fact geo_object id's according to the JSON spec)
	'sim_geofence_ids' => ['density_0_1', 'density_0_2', 'density_0_3', 'density_0_4', 'density_0_5', 'density_0_6', 'density_0_7', 'density_0_8', 'density_0_9', 'density_1_0'],
	# list of geofence_ids to test
	'sim_geofence_test_id' => [0,1,2,3,4,5,6,7,8,9],
	'sim_repetitions' => 3
}

######
# OAuth setup for Geoluis
####
KEY = "n5FkRe5yUbdOt9X38cxSBBvoojwmt1Qhyb60GzD2"
SECRET = "8D3aAxZ2vYDoHQHTnrMzEvdASMmMQgXLH89wgYp6"
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

		points = []
		for shape in fence['shapes']
			points << @@vars['factory'].point(shape['nw_corner'][0],shape['nw_corner'][1])
			points << @@vars['factory'].point(shape['se_corner'][0],shape['se_corner'][1])
		end

		# A ring has to have 3 points, let's create a fake point in the middle
		if points.length <= 2
			points << @@vars['factory'].point((points[0].x()+points[1].x())/2,(points[0].y()+points[1].y())/2)
		end

		linearring = @@vars['factory'].linear_ring(points)
		geom = @@vars['factory'].polygon(linearring)
		bbox = RGeo::Cartesian::BoundingBox.create_from_geometry(geom)
		puts "==== Density stats"
		bbox_area = calculate_area_and_centroid([[bbox.min_x(),bbox.max_y()],[bbox.max_x(),bbox.max_y()],[bbox.max_x(),bbox.min_y()],[bbox.min_x(),bbox.min_y()]])
		puts " Name: #{fence['name']}
 id: #{fence['foreign_id']}
 Number of polygons: #{fence['shapes'].length}
 Area: #{fence['area']}
 BBox area: #{bbox_area}
 Density: #{fence['area']/bbox_area}
 Timed request threshold: #{@@vars['timed_requests_threshold']}s
 iOS blackbox threshold: #{@@vars['ios_distance_threshold']}m"
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

		@@vars['missed_distance_shapes_ids'].flatten!.uniq! if @@vars['missed_distance_shapes_ids'].length > 0
		@@vars['missed_time_shapes_ids'].flatten!.uniq! if @@vars['missed_time_shapes_ids'].length > 0
		@@vars['found_distance_shapes_ids'].flatten!.uniq! if @@vars['found_distance_shapes_ids'].length > 0
		@@vars['found_time_shapes_ids'].flatten!.uniq! if @@vars['found_time_shapes_ids'].length > 0

		missed_fences_by_distance = (@@vars['missed_distance_shapes_ids'] - @@vars['found_distance_shapes_ids']).count
		missed_fences_by_time = (@@vars['missed_time_shapes_ids'] - @@vars['found_time_shapes_ids']).count

		puts "== Run stats" if @@vars['show_intermediate_countings']
		puts " Number of requests: #{@@vars['request_counter']}
 # of fences walked into: #{@@vars['walked_into_fences']}
 Avg request size: #{@@vars['request_size']/@@vars['request_counter']}
 iOS black fence misses (#{@@vars['ios_distance_threshold']}m): #{missed_fences_by_distance}
 Timed requests fence misses (#{@@vars['timed_requests_threshold']}s): #{missed_fences_by_time}
 Avg geofence radius: #{fence_radii*1.0/fence['shapes'].length}m
 Avg JSON leave fence radius: #{@@vars['left_fence_radius']/@@vars['request_counter']}m" if @@vars['show_intermediate_countings']
		puts "==========" if @@vars['show_intermediate_countings']

		# Add to total accumulators
		@@vars['total_request_counter'] += @@vars['request_counter']
		@@vars['total_walked_into_fences'] += @@vars['walked_into_fences']
		@@vars['total_request_size'] += @@vars['request_size']/@@vars['request_counter']
		@@vars['total_missed_distance_shapes'] += missed_fences_by_distance
		@@vars['total_missed_time_shapes'] += missed_fences_by_time
		@@vars['total_geofence_radius'] += fence_radii*1.0/fence['shapes'].length
		@@vars['total_left_fence_radius'] += @@vars['left_fence_radius']/@@vars['request_counter']
	end
	return
end

def show_average_stats()
	time = @@vars['total_sim_time']/@@vars['sim_repetitions']
	#Print averages
	puts " Total walked distance: #{@@vars['total_walked_distance']/@@vars['sim_repetitions']}m
 Total sim time: #{time}s (#{(time/60).floor}m#{(((time/60)-(time/60).floor)*60).floor}s)
 ====
 Total avg number of requests: #{@@vars['total_request_counter']*1.0/@@vars['sim_repetitions']}
 Total avg # of fences walked into: #{@@vars['total_walked_into_fences']*1.0/@@vars['sim_repetitions']}
 Total avg request size: #{@@vars['total_request_size']*1.0/@@vars['sim_repetitions']}
 Total avg iOS black fence misses (#{@@vars['ios_distance_threshold']}m): #{@@vars['total_missed_distance_shapes']*1.0/@@vars['sim_repetitions']}
 Total avg timed requests fence misses (#{@@vars['timed_requests_threshold']}s): #{@@vars['total_missed_time_shapes']*1.0/@@vars['sim_repetitions']}
 Total avg geofence radius: #{@@vars['total_geofence_radius']*1.0/@@vars['sim_repetitions']}m
 Total avg JSON leave fence radius: #{@@vars['total_left_fence_radius']*1.0/@@vars['sim_repetitions']}m"

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
		end
	end
	return local_shapes
end

# Method to calculate fence misses from blackbox and timed request methods
def calculate_misses (point,geo_id,shapes)
	if @@vars['prev_point'] == nil
		@@vars['prev_point'] = point
		# We would make a request now, so we should discard the shapes as unknown
		known_shapes = shapes_here(point,shapes)
		@@vars['found_distance_shapes_ids'] << known_shapes
		@@vars['found_time_shapes_ids'] << known_shapes
	end

	# If the distance is lower than ios_distance_threshold meters
	if @@vars['ellapsed_distance'] < @@vars['ios_distance_threshold']
		@@vars['ellapsed_distance'] += distance([@@vars['prev_point'].x(),@@vars['prev_point'].y()],[point.x(),point.y()])*111110
		@@vars['missed_distance_shapes_ids'] << shapes_here(point,shapes)
	else
		@@vars['ellapsed_distance'] = 0
		# We would make a request now, so we should discard the shapes as unknown
		@@vars['found_distance_shapes_ids'] << shapes_here(point,shapes)
	end

	# If the ellapsed walk time is smaller than timed_requests_threshold seconds
	if @@vars['ellapsed_time'] < @@vars['timed_requests_threshold']
		@@vars['ellapsed_time'] += distance([@@vars['prev_point'].x(),@@vars['prev_point'].y()],[point.x(),point.y()])*111110*@@vars['walk_speed_ms']
		@@vars['missed_time_shapes_ids'] << shapes_here(point,shapes)
	else
		@@vars['ellapsed_time'] = 0
		# We would make a request now, so we should discard the shapes as unknown
		@@vars['found_time_shapes_ids'] << shapes_here(point,shapes)
	end

	@@vars['prev_point'] = point
end

# Method to get the geofences
def get_fences(*args)
	fences = @@vars['access_token'].request(:get, "/api/v3/geo_fences", HEADERS)
	result = nil
	if args.length > 0
		# Uncomment if other shapes than circles
		#result = [JSON[fences.body][args[0]].to_json]

		# Since we're only using circles for now, we don't need the points, only the generators
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

	if path_num > 0
		test_data = [
			'{"distance":0.01989326090392547,"body":[[139.6931389,35.6646286],[139.6919671,35.6643263],[139.6914338,35.664197],[139.6910844,35.6641088],[139.6906986,35.6639866],[139.6906986,35.6639866],[139.6900109,35.6637591],[139.689662,35.6636454],[139.6892554,35.6635123],[139.6888693,35.6634024],[139.6885112,35.6632988],[139.6881277,35.6631882],[139.6877773,35.6630872],[139.6875882,35.6631161],[139.6866202,35.6634698],[139.6857199,35.6637674],[139.6851912,35.6639589],[139.6849855,35.6640462],[139.6844678,35.6642107],[139.6841017,35.664287],[139.6835831,35.6645003],[139.6837089,35.6646945],[139.6835831,35.6645003],[139.6834242,35.6642439],[139.6832056,35.6638939],[139.6831685,35.663823],[139.6831347,35.6637727],[139.6828406,35.6633348],[139.6819606,35.6632686],[139.6818069,35.6627893],[139.6816986,35.6623696],[139.6813961,35.6611566],[139.6812937,35.660752],[139.681036,35.6597346],[139.6817234,35.6585116],[139.6815559,35.6586437],[139.6813536,35.6585253],[139.6814766,35.6580408],[139.6814618,35.6579626],[139.6813806,35.6579689],[139.6813236,35.6573295],[139.6813431,35.6570857],[139.6813627,35.6568435],[139.6813932,35.6566003],[139.6807794,35.6566208],[139.6807868,35.6569207],[139.680794,35.6569738],[139.6808776,35.6575924],[139.6808606,35.6576201],[139.6798737,35.6576947]]}',
			'{"distance":0.018187142584226833,"body":[[139.6931389,35.6646286],[139.6932859,35.6644469],[139.6934109,35.6642613],[139.6937528,35.6637097],[139.6937887,35.6636517],[139.6938887,35.6635595],[139.693986,35.6634656],[139.694247,35.6632115],[139.6944539,35.6629995],[139.6940012,35.6630281],[139.6944418,35.6626633],[139.6948587,35.662351],[139.6949969,35.6631424],[139.6946282,35.6634624],[139.6944394,35.6633404],[139.694247,35.6632115],[139.6950967,35.6624813],[139.6948587,35.662351],[139.6943791,35.6620749],[139.6954929,35.6620961],[139.6952153,35.6619383],[139.6947274,35.6616611],[139.6940466,35.6623274],[139.6938506,35.6621681],[139.6938068,35.6618832],[139.6937529,35.6617154],[139.6934678,35.6615601],[139.6930796,35.6613531],[139.6928311,35.6611938],[139.6926183,35.6610874],[139.6924465,35.6609927],[139.6922927,35.6608996],[139.6921862,35.6608202],[139.6920321,35.6607393],[139.6919125,35.6606848],[139.6915852,35.6604793],[139.691146,35.6602386],[139.6907752,35.6600344],[139.6904777,35.6598719],[139.6920404,35.6592944],[139.6910115,35.6592459],[139.6909809,35.6592818],[139.6902284,35.6588517],[139.6909903,35.6578981],[139.6906797,35.6579183],[139.6905111,35.6578591],[139.6900561,35.6577924],[139.6907219,35.6581547],[139.6908679,35.6579352],[139.6909795,35.6577469],[139.6910567,35.6575168],[139.6911041,35.657217],[139.6910629,35.6569675]]}',
			'{"distance":0.01997184068072727,"body":[[139.69264,35.6652342],[139.6925201,35.6653329],[139.6924426,35.6653729],[139.6923492,35.6654088],[139.6923338,35.6653896],[139.6923325,35.6653515],[139.6924468,35.6650386],[139.6926221,35.6653829],[139.6925289,35.665405],[139.6922503,35.6654997],[139.6919497,35.6655884],[139.6919296,35.6655888],[139.6919096,35.6655834],[139.6918828,35.6655591],[139.6918718,35.6655354],[139.6918779,35.6655046],[139.6921135,35.6648534],[139.6916811,35.6647484],[139.6912541,35.6646385],[139.6907177,35.6645065],[139.6904745,35.6644384],[139.6898381,35.6642615],[139.6898945,35.6640858],[139.6899115,35.664032],[139.6899206,35.6639578],[139.6900109,35.6637591],[139.6897788,35.6636849],[139.6898588,35.6633368],[139.6898166,35.6631193],[139.6898945,35.6640858],[139.6895427,35.6639652],[139.6906986,35.6639866],[139.6900109,35.6637591],[139.689662,35.6636454],[139.6892554,35.6635123],[139.6888693,35.6634024],[139.6885112,35.6632988],[139.6881277,35.6631882],[139.6877773,35.6630872],[139.6871668,35.6627292],[139.6870658,35.6624117],[139.6874367,35.6623363],[139.6875882,35.6631161],[139.6866202,35.6634698],[139.6857199,35.6637674],[139.6851912,35.6639589],[139.6849855,35.6640462],[139.6844678,35.6642107],[139.6841017,35.664287],[139.6835831,35.6645003],[139.682971,35.6655042],[139.6834076,35.6653076],[139.6835191,35.6652561],[139.6836895,35.6651774],[139.6839594,35.6650601],[139.6841049,35.6649893],[139.6844792,35.6648319],[139.6847643,35.6647421],[139.6849388,35.6646871],[139.6850388,35.6646574],[139.6851992,35.6646205],[139.6853169,35.664604]]}',
			'{"distance":0.018351804539370877,"body":[[139.6945816,35.6648607],[139.6946845,35.6649045],[139.69472,35.6649196],[139.6948092,35.6649597],[139.6948503,35.6649955],[139.6949163,35.6650444],[139.6949488,35.665084],[139.6949536,35.6651089],[139.6949039,35.6651912],[139.694858,35.6652122],[139.6948006,35.6652168],[139.6946295,35.6651904],[139.6945176,35.6651656],[139.6945816,35.6648607],[139.6946845,35.6649045],[139.69472,35.6649196],[139.6948092,35.6649597],[139.6948503,35.6649955],[139.6949163,35.6650444],[139.6949488,35.665084],[139.6949536,35.6651089],[139.6949039,35.6651912],[139.694858,35.6652122],[139.6948006,35.6652168],[139.6946295,35.6651904],[139.6945176,35.6651656],[139.6945816,35.6648607],[139.6942914,35.6647264],[139.6943336,35.6646567],[139.6942214,35.6645963],[139.6941075,35.6645473],[139.6939793,35.6645124],[139.6938878,35.6645051],[139.6938048,35.6645257],[139.6937201,35.6645627],[139.6936726,35.6645683],[139.6935882,35.6645598],[139.6934305,35.6645105],[139.6932859,35.6644469],[139.6926363,35.6653631],[139.6931397,35.6656407],[139.6935214,35.6658462],[139.6927528,35.6666864],[139.6928219,35.6667291],[139.6931222,35.666915],[139.6931915,35.6669642],[139.6930785,35.6671381],[139.6930068,35.6672601],[139.6929921,35.66734],[139.6930026,35.6674368],[139.6930208,35.6674875],[139.6930505,35.6675522],[139.6930968,35.6676063],[139.6931568,35.6676722],[139.6932708,35.6677568],[139.6934005,35.6678345],[139.6935303,35.6678989],[139.6937611,35.6679722],[139.6940027,35.6680336],[139.6940904,35.6680433],[139.6941876,35.6680467],[139.6949497,35.6680734],[139.6958989,35.6681067],[139.6963101,35.6681211],[139.6963726,35.668133],[139.6964351,35.6681675],[139.6974923,35.6682057],[139.6975397,35.6682075],[139.6976798,35.6682119],[139.6987606,35.6682563],[139.6999451,35.6682994],[139.7000601,35.6683072],[139.7001904,35.6683166],[139.7003513,35.668343],[139.7006062,35.6684115],[139.7013919,35.6687401],[139.7015844,35.6688205],[139.7016807,35.668862],[139.7020256,35.6688892],[139.7018069,35.6690102],[139.7018069,35.6691845],[139.7019284,35.6689835],[139.7018388,35.6688777],[139.7019284,35.6689835],[139.7021355,35.6689612],[139.7021583,35.6690891],[139.7022039,35.6692805],[139.7026087,35.6694623],[139.702724,35.6697799],[139.7029485,35.6697122],[139.7029598,35.6694161]]}',
			'{"distance":0.01851745155541679,"body":[[139.6943336,35.6646567],[139.6942214,35.6645963],[139.6941075,35.6645473],[139.6939793,35.6645124],[139.6938878,35.6645051],[139.6938048,35.6645257],[139.6937201,35.6645627],[139.6936726,35.6645683],[139.6935882,35.6645598],[139.6934305,35.6645105],[139.6932859,35.6644469],[139.6931389,35.6646286],[139.6919671,35.6643263],[139.6914338,35.664197],[139.6910844,35.6641088],[139.6906986,35.6639866],[139.6906028,35.6646505],[139.6907476,35.6647079],[139.6906986,35.6639866],[139.6904745,35.6644384],[139.6910844,35.6641088],[139.6913492,35.663676],[139.6913653,35.6636306],[139.6913894,35.6634792],[139.6914454,35.6631257],[139.6914454,35.6631257],[139.6915704,35.6631021],[139.6919182,35.663029],[139.6935297,35.6626902],[139.6938306,35.6624737],[139.6940466,35.6623274],[139.694111,35.6622788],[139.6954929,35.6620961],[139.6952153,35.6619383],[139.6947274,35.6616611],[139.6959699,35.6615291],[139.6956943,35.6613702],[139.6952222,35.6610939],[139.6945976,35.6607344],[139.6949626,35.6598453],[139.6947543,35.6600937],[139.6938522,35.65954],[139.6948412,35.6588155],[139.6948869,35.6584768],[139.6949054,35.6582923],[139.6949105,35.6582408],[139.6949328,35.6580047],[139.6949448,35.6578855],[139.6949747,35.6578117],[139.6950291,35.6577179],[139.6961629,35.6575052],[139.6960596,35.6575817],[139.6959848,35.657639],[139.695822,35.6578405],[139.6957855,35.657884],[139.6957226,35.6579809],[139.695637,35.6581087],[139.6955557,35.6582394],[139.6954849,35.6583484],[139.6954478,35.6584292],[139.6954277,35.6585232],[139.6954146,35.6587427],[139.6954049,35.658868],[139.6954316,35.6591504],[139.6954713,35.659435],[139.6955053,35.6596952],[139.6955134,35.6598173],[139.6955161,35.6599384],[139.695506,35.6600411],[139.6947838,35.6604985],[139.6945976,35.6607344],[139.6942081,35.6611813],[139.6939017,35.661546],[139.6937529,35.6617154]]}',
			'{"distance":0.019062042074733637,"body":[[139.69264,35.6652342],[139.6925201,35.6653329],[139.6924426,35.6653729],[139.6923492,35.6654088],[139.6923338,35.6653896],[139.6923325,35.6653515],[139.6924468,35.6650386],[139.6931389,35.6646286],[139.6919671,35.6643263],[139.6914338,35.664197],[139.6910844,35.6641088],[139.6906986,35.6639866],[139.6906986,35.6639866],[139.6900109,35.6637591],[139.689662,35.6636454],[139.6892554,35.6635123],[139.6888693,35.6634024],[139.6885112,35.6632988],[139.6881277,35.6631882],[139.6877773,35.6630872],[139.6889769,35.6627329],[139.6883271,35.6623572],[139.6878298,35.6620812],[139.6875882,35.6631161],[139.6866202,35.6634698],[139.6857199,35.6637674],[139.6851912,35.6639589],[139.6849855,35.6640462],[139.6844678,35.6642107],[139.6841017,35.664287],[139.6835831,35.6645003],[139.6820829,35.6643575],[139.6819863,35.6644737],[139.681807,35.6646634],[139.6814545,35.6650509],[139.6813434,35.6651712],[139.6813434,35.6651712],[139.6809344,35.665652],[139.6800898,35.6659718],[139.6801401,35.6659399],[139.6802277,35.6658958],[139.6803173,35.6658507],[139.6802304,35.6657384],[139.6798569,35.665261],[139.6796393,35.6649859],[139.6795517,35.6648752],[139.6794657,35.6647665],[139.6796393,35.6649859],[139.679534,35.6650599],[139.6799498,35.6642069],[139.6799994,35.6641846],[139.6801252,35.6641606],[139.6807563,35.6641058],[139.6808876,35.664082],[139.6818685,35.6636809],[139.6825979,35.663385],[139.6828326,35.6633218]]}',
			'{"distance":0.018069447933432313,"body":[[139.69264,35.6652342],[139.6925201,35.6653329],[139.6924426,35.6653729],[139.6923492,35.6654088],[139.6923338,35.6653896],[139.6923325,35.6653515],[139.6924468,35.6650386],[139.6931389,35.6646286],[139.6919671,35.6643263],[139.6914338,35.664197],[139.6910844,35.6641088],[139.6906986,35.6639866],[139.6898945,35.6640858],[139.6895427,35.6639652],[139.6897788,35.6636849],[139.6898588,35.6633368],[139.6898166,35.6631193],[139.689922,35.6624143],[139.6902101,35.6620771],[139.6899782,35.6609535],[139.689683,35.6607873],[139.6888858,35.6603339],[139.6878333,35.6614699],[139.6876804,35.6614318],[139.6875717,35.661392],[139.6875089,35.6613612],[139.687452,35.6613232],[139.6873102,35.6611086],[139.6871923,35.6609414],[139.6869356,35.6610411],[139.6868149,35.6610915],[139.6867892,35.6610272],[139.686511,35.6603449],[139.686406,35.6600738],[139.6862414,35.6595715],[139.6859548,35.6596408],[139.6858026,35.6596819],[139.6857772,35.6597111],[139.6857722,35.6597342],[139.6857827,35.6597746],[139.6858095,35.6598075],[139.6858456,35.6598295],[139.6858996,35.6598378],[139.6859487,35.6598298],[139.6859945,35.6598075],[139.6860244,35.6597719],[139.6860323,35.6597425],[139.6860251,35.6597032],[139.6860093,35.6596746],[139.6859854,35.6596527],[139.6859548,35.6596408],[139.6859548,35.6596408],[139.6858026,35.6596819],[139.6854467,35.6597789]]}',
			'{"distance":0.018655656196897758,"body":[[139.6931389,35.6646286],[139.6932859,35.6644469],[139.6934109,35.6642613],[139.6937528,35.6637097],[139.6937887,35.6636517],[139.6938887,35.6635595],[139.693986,35.6634656],[139.694247,35.6632115],[139.6944539,35.6629995],[139.6940012,35.6630281],[139.6944418,35.6626633],[139.6948587,35.662351],[139.6958043,35.6621359],[139.6957882,35.6622255],[139.6950793,35.6628545],[139.6948262,35.6629997],[139.6959362,35.6631762],[139.6962497,35.6633838],[139.6960752,35.6635015],[139.6961638,35.6635692],[139.6960647,35.6636615],[139.6959893,35.6636921],[139.6958742,35.6638367],[139.6965494,35.664265],[139.6967287,35.6638867],[139.698489,35.6648126],[139.6986238,35.6648264],[139.6986834,35.664836],[139.6988208,35.6648762],[139.6988617,35.6648994],[139.698957,35.6649555],[139.6990391,35.6650189],[139.6993244,35.6652587],[139.6994063,35.6652989],[139.699493,35.6653777],[139.6997447,35.6656063],[139.6997896,35.6656882],[139.7005491,35.6664375],[139.7006266,35.6665104],[139.7006577,35.6665396],[139.700713,35.6665767],[139.7007541,35.6666025],[139.7008105,35.6666345],[139.700872,35.6666663],[139.700921,35.6666855],[139.7009745,35.6667029],[139.7010469,35.6667208],[139.7010999,35.6667305],[139.701123,35.6667348],[139.7012705,35.6667527],[139.7014794,35.6667731],[139.7015844,35.6667824],[139.7016813,35.6668651],[139.7016894,35.6668805],[139.7017377,35.6674415],[139.7018033,35.6680952],[139.7018282,35.6683743],[139.7018986,35.6687568],[139.7021355,35.6689612],[139.7021203,35.6688369],[139.702122,35.6692456],[139.7022039,35.6692805],[139.7021583,35.6690891],[139.702325,35.6691596],[139.7028527,35.6693914],[139.7030967,35.669382],[139.703191,35.6693449],[139.7038798,35.669033],[139.7041712,35.6689],[139.7047319,35.6686409],[139.7051015,35.6684703],[139.7051462,35.6684101],[139.7051822,35.668365],[139.7052494,35.6683343],[139.705377,35.6682796]]}',
			'{"distance":0.018257608377390613,"body":[[139.6937528,35.6637097],[139.6940382,35.6638301],[139.6942415,35.6639411],[139.6938878,35.6645051],[139.6939389,35.6643885],[139.6940336,35.6642217],[139.6941153,35.664101],[139.6942415,35.6639411],[139.6943122,35.6639118],[139.6944176,35.663787],[139.6948262,35.6629997],[139.6947611,35.6630593],[139.6946767,35.663134],[139.6944841,35.663303],[139.6944394,35.6633404],[139.6944032,35.6633706],[139.6942192,35.6635869],[139.6940382,35.6638301],[139.6939558,35.6639887],[139.6939151,35.6640723],[139.693885,35.6641479],[139.6938571,35.6642452],[139.6938532,35.6643312],[139.6938585,35.6644245],[139.6938448,35.6644695],[139.6938048,35.6645257],[139.6926221,35.6653829],[139.6925289,35.665405],[139.6922503,35.6654997],[139.6919497,35.6655884],[139.6919296,35.6655888],[139.6919096,35.6655834],[139.6918828,35.6655591],[139.6918718,35.6655354],[139.6918779,35.6655046],[139.6921135,35.6648534],[139.6916811,35.6647484],[139.6912541,35.6646385],[139.6907177,35.6645065],[139.6904745,35.6644384],[139.6898381,35.6642615],[139.6898945,35.6640858],[139.6899115,35.664032],[139.6899206,35.6639578],[139.6900109,35.6637591],[139.6913894,35.6634792],[139.6908733,35.6633239],[139.6897788,35.6636849],[139.6898588,35.6633368],[139.6898166,35.6631193],[139.6889769,35.6627329],[139.6883271,35.6623572],[139.6878298,35.6620812],[139.688165,35.661446],[139.6882114,35.6614759],[139.6888001,35.6618179],[139.6877693,35.6629801],[139.6880268,35.6626983],[139.6871559,35.6615218],[139.6873779,35.6614271],[139.6875089,35.6613612],[139.6874884,35.6626236],[139.6871668,35.6627292],[139.6863738,35.6629906],[139.6854802,35.6633045],[139.6846718,35.6635835],[139.6844567,35.6636552]]}',
			'{"distance":0.019711842085533428,"body":[[139.6951325,35.6664073],[139.6965475,35.6669679],[139.6970021,35.6671387],[139.6958989,35.6681067],[139.6959161,35.668045],[139.6959273,35.6680046],[139.6965475,35.6669679],[139.6957726,35.6684739],[139.6958451,35.6684899],[139.6959265,35.6684972],[139.6960274,35.6684966],[139.6962123,35.668465],[139.6962816,35.6684533],[139.6963539,35.6684492],[139.6964324,35.6684525],[139.6964675,35.6684386],[139.6965645,35.6684389],[139.6973763,35.6684766],[139.6974129,35.6684913],[139.6993069,35.6686028],[139.6993576,35.6686112],[139.6994355,35.6686241],[139.6994902,35.6686252],[139.6995619,35.6686201],[139.6996255,35.66861],[139.6996945,35.6685949],[139.6997636,35.6685858],[139.6998423,35.6685865],[139.69991,35.668591],[139.6999683,35.6686013],[139.7000298,35.6686227],[139.700104,35.6686521],[139.7001597,35.6686727],[139.7002134,35.6686799],[139.7002788,35.6686799],[139.7003615,35.6686778],[139.7004284,35.6686773],[139.7005024,35.6686818],[139.7005694,35.6686919],[139.700626,35.6687042],[139.7007047,35.6687272],[139.7007869,35.668761],[139.701361,35.6690163],[139.7014249,35.6690416],[139.7018388,35.6688777],[139.7018986,35.668835],[139.7019063,35.6688129],[139.7018986,35.6687568],[139.7018069,35.6691845],[139.7019284,35.6689835],[139.7018388,35.6688777],[139.7018028,35.6689031],[139.7017808,35.6689047],[139.7016807,35.668862],[139.7014249,35.6690416],[139.7016221,35.6691235],[139.7019425,35.6692574],[139.7020111,35.6692864],[139.7021313,35.6693342],[139.7021949,35.669362],[139.7025925,35.6695277],[139.7026057,35.66955],[139.7026062,35.6695733],[139.7025736,35.6695932],[139.7024953,35.6696],[139.7022332,35.6696222],[139.7021949,35.669362],[139.7026062,35.6695733],[139.702613,35.6696547],[139.7026262,35.6697635],[139.7027402,35.6694139],[139.7022057,35.6691855],[139.7018069,35.6691845],[139.7016692,35.669129],[139.702122,35.6692456],[139.7020838,35.6691227],[139.7020256,35.6688892],[139.701985,35.6686247],[139.7019646,35.668492],[139.701905,35.6681222],[139.7017834,35.6667162],[139.7017504,35.6663592],[139.7016913,35.6659408],[139.7016496,35.6657309],[139.7014896,35.6650943],[139.7013834,35.6645524],[139.7013265,35.6640867],[139.7012617,35.6634825],[139.7012898,35.6633556]]}'
		]
		walk = JSON[test_data[path_num-1]]
		new_walk = JSON[test_data[path_num-1]]
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

# Test each of the @@var['sim_geofence_test_id']'s
for geo_id in @@vars['sim_geofence_test_id']

	puts "\n_~^ Starting tests for geofence #{@@vars['sim_geofence_ids'][geo_id]} ^~_"
	calculate_density_stats(JSON[get_fences()],geo_id)

	for w in @@vars['sim_repetitions'].times do

		puts "\n_~^ Starting test with path #{w} ^~_" if @@vars['show_intermediate_countings']

		# This will iteratively chose a different path[w] from the static paths array
		# If you need to have the same path drawn (w times) use get_walk() with no argument
		walk, original_walk = get_walk(w)

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
	puts "========="
	puts "_~^ Finished tests for geofence #{@@vars['sim_geofence_ids'][geo_id]} ^~_"
	show_average_stats()
	puts "========="
end

