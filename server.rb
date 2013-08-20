##
# Call with curl -i -H "Accept: application/json" "http://localhost:4570/?long=139.6941&lat=35.6572"
# Or use http://localhost:4570/demo.html
##
require 'rubygems'
require 'active_support'
require 'sinatra'
require 'mongo'
require 'json'

encoding_options = {
  :invalid           => :replace,  # Replace invalid byte sequences
  :undef             => :replace,  # Replace anything not defined in ASCII
  :replace           => '',        # Use a blank for those replacements
  :universal_newline => true       # Always break lines with \n
}

class Array
  def rotate
    push shift
  end
end

conn = Mongo::Connection.new("localhost", 27017, :pool_size => 100, :pool_timeout => 5)
db = conn['roadsimulator']
set :port, 4570

get '/' do

  # Get params
  lon = params["lon"].to_f
  lat = params["lat"].to_f
  # Convert from Km to degrees
  length = params["length"].to_f/111110

  # Build walk
  res = make_walk(db, lon, lat, length)

  # Make a google compatible walk
  #res['body'].each do |w|
  #  w.rotate
  #end

  # Output to paste into https://code.google.com/apis/ajax/playground/#polylines_v3
  #res['body'].each do |w|
  #  puts "new google.maps.LatLng(#{w[1]}, #{w[0]})," 
  #end
  
  # Send walk
  res.to_json

end

####
# Make big walk
####
def make_walk(db, lon, lat, length)
  # Initial run
  limit = 10
  local_arch = get_arch(db, lon, lat, limit, length)

  # Inits
  walk = ActiveSupport::OrderedHash.new
  walk['distance'] = local_arch['obj']['distance']
  walk['body'] = [local_arch['obj']['body']]
  walked = {}
  rewalk_thresh = 5

  # Loop until we reach the requested length
  while walk['distance'] <= length
    #puts "#{walk['distance']} of #{length}"
    old_body = nil
    
    if local_arch['obj']['body']
      old_body = local_arch['obj']['body']
      local_arch = get_arch(db, old_body[old_body.length()-1][0], old_body[old_body.length()-1][1], limit, length)

      # Draw another arch if the one we got is invalid
      while local_arch['obj']['distance'] == 0
        local_arch = get_arch(db, old_body[old_body.length()-1][0], old_body[old_body.length()-1][1], limit, length)
      end

      # Is this an already discovered path
      if walked.include? local_arch['obj']
        walked[local_arch['obj']] += 1
        # If we walk past this arch for more than rewalk_thresh times, walk back until we find a fresh path
        if walked[local_arch['obj']] >= rewalk_thresh
          # Walk back/ Pop dubious path from walked array
          walk['body'].pop()
          # Update current position to last position after popping 
          local_arch['obj']['body'] = walk['body'][walk['body'].length()-1]
          # Increase the search limit
          limit += 1
          # Get another arch
          next
        end
      else # New path
        walked[local_arch['obj']] = 1
      end
    else
      # We popped too much! Starting from scratch ...
      puts "Too much pop!"
      if old_body
        local_arch = get_arch(db, old_body[old_body.length()-1][0], old_body[old_body.length()-1][1], limit, length) 
      else
        local_arch = get_arch(db, lon, lat, limit, length)
      end
      next
    end

    # Add body array to walk
    walk['body'].push(local_arch['obj']['body']) if local_arch

    # Accumulate distance
    walk['distance'] += (local_arch['obj']['distance']) if local_arch
  end

  # Flatten array so that archs are merged into contiguous [lon,lat] pairs
  walk['body'] = walk['body'].flatten(1)

  return walk
end

####
# Add arch to walking path
####
def get_arch(db, lon, lat, limit, length)
  train_station_coords_col = db.collection('train_station_coords')
  # Build query
  selector = ActiveSupport::OrderedHash.new

  # Query for train ride
  selector['geoNear'] = 'train_station_coords'
  selector['near'] = [lon, lat]
  selector['spherical'] = true
  selector['distanceMultiplier'] = 6371000
  selector['limit'] = 1

  # How many stations do we travel?
  # TO DO: estimate from length
  #        1 stop per Km? Analyze from data!
  # TO DO: Use data from commutes dataset
  # TO DO: Local has more hops than express trains
  hops = 2+rand(10)
  arc = {}
  arc['obj'] = {}
  arc['obj']['distance'] = 0

  # Get nearby train stations
  train_stations_res = db.command( selector )

  # For each train station
  train_stations_res['results'].each do |train_station|
    # If closer than 100m  to a train station and the odds are in our side (1/3 probability)
    if train_station['dis'] < 100 and rand(3) == 2
      # This code is the concatenation of the line code plus the station code
      # By operating on this code we can decide which station we stop at
      # TO DO: + or -
      # TO DO: Add time of the day
      final_station_code = train_station['obj']['code'].to_i + hops
      final_station = train_station_coords_col.find(:code => final_station_code).to_a[0]

      return arc if final_station == nil

      # Update query to search for the the line
      selector['geoNear'] = 'train_lines'
      selector['near'] = [train_station['obj']['idx_loc']['lat'], train_station['obj']['idx_loc']['lon']]
      # This defined how many lines to analyze
      # Stations with many lines, like Shinjuku, will need a higher value
      # Only one must be chosen
      # TO DO: use commute dataset to statistically chose connection
      selector['limit'] = 1
      selector['distanceMultiplier'] = 1
      train_line_res = db.command( selector )

      #For each train line
      train_line_res['results'].each do |train_line|
        pos_init = nil
        pos_end = nil
        # If closer than 10m
        if train_line['dis'] < 10
          # Search start and end stations position in train line array
          pos = 0
          train_line['obj']['idx_loc']['coordinates'].each do |line_pos|
            if line_pos[0] == train_station['obj']['idx_loc']['lat'] && line_pos[1] == train_station['obj']['idx_loc']['lon'] 
              puts "Initial station (#{train_station['obj']['idx_loc'].to_s}) found at position #{pos} of #{train_line['obj']['idx_loc']['coordinates'].length}"
              pos_init = pos
            end
            if line_pos[0] == final_station['idx_loc']['lat'] && line_pos[1] == final_station['idx_loc']['lon'] 
              puts "Final station (#{final_station['idx_loc'].to_s}) found at position #{pos} of #{train_line['obj']['idx_loc']['coordinates'].length}"
              pos_end = pos
            end
            break if pos_init and pos_end
            pos += 1
          end
        end

        # If we found a valid segment (with start and end stations)
        if pos_init and pos_end
          # Chose the correct sense
          if pos_init > pos_end
            arc['obj']['body'] = train_line['obj']['idx_loc']['coordinates'][pos_end..pos_init].reverse
          else
            arc['obj']['body'] = train_line['obj']['idx_loc']['coordinates'][pos_init..pos_end]
          end

          # Add walk type for each point (1 for train)
          arc['obj']['body'].map {|x| x << 1}

          # Calculate distance for traveled segment
          dist = 0
          (arc['obj']['body'].length-1).times do |p|
            dist += distance(arc['obj']['body'][p][0],arc['obj']['body'][p][1],arc['obj']['body'][p+1][0],arc['obj']['body'][p+1][1])
          end

          arc['obj']['distance'] = dist
        end
      end
      # We're done with the train arc
      return arc
    end
  end

  # Query for walk paths
  selector['geoNear'] = 'road_coords_head'
  selector['near'] = [lon, lat]
  selector['distanceMultiplier'] = 6371
  selector['limit'] = limit
  res = db.command( selector )

  # Get which tail_point is closer to a train station
  selector['geoNear'] = 'train_station_coords'
  ordered_res = []

  #For each of the candidate arcs (closest arcs)
  res['results'].each do |p|

    # Make query
    selector['near'] = p['obj']['body'][-1]
    station_res = db.command( selector )

    # Average the distance from the last point of the arc
    # to the closest _limit_ train distances
    # TO DO: play with this _limit_ variable
    sdist = 0.0
    station_res['results'].each { |sd| sdist += sd['dis'] }
    avg_sdist = sdist/station_res['results'].size

    # Push to array with original data and 
    # newly calculated distance to train stations
    ordered_res.push({'dist' => avg_sdist, 'arc' => p})
  end

  # Sort new array
  sorted = ordered_res.sort_by { |k| k["dist"] }

  # Generate random element, based on a Gaussian distribution
  r = (rand(limit) - (limit-2)).abs
  arc = sorted[r]['arc']

  # Add walk type for each point (0 for walk)
  arc['obj']['body'].map {|x| x << 0}

  return arc
end

####
# Add train arch to walking path
####
def get_train_arch(db, lon, lat, limit)

end

####
# Distance between two points
####
def distance(long1, lat1, long2, lat2)
  dtor = Math::PI/180
  r = 1#6378.14*1000
 
  rlat1 = lat1 * dtor 
  rlong1 = long1 * dtor 
  rlat2 = lat2 * dtor 
  rlong2 = long2 * dtor 
 
  dlon = rlong1 - rlong2
  dlat = rlat1 - rlat2
 
  a = (Math::sin(dlat/2))**2 + Math::cos(rlat1) * Math::cos(rlat2) * (Math::sin(dlon/2))**2
  c = 2 * Math::atan2(Math::sqrt(a), Math::sqrt(1-a))
  d = r * c
 
  return d
end