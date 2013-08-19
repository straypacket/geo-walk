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
  local_arch = get_arch(db, lon, lat, limit)

  # Inits
  walk = ActiveSupport::OrderedHash.new
  walk['distance'] = local_arch['obj']['distance']
  walk['body'] = [local_arch['obj']['body']]
  walked = {}
  rewalk_thresh = 1

  # Loop until we reach the requested length
  while walk['distance'] <= length
    if local_arch['obj']['body']
      old_body = local_arch['obj']['body']
      local_arch = get_arch(db, old_body[old_body.length()-1][0], old_body[old_body.length()-1][1], limit)

      # Is this an already discovered path
      if walked.include? local_arch['obj']
        walked[local_arch['obj']] = walked[local_arch['obj']]+1
        # If we walk past this arch for more than 5 times, walk back until we find a fresh path
        if walked[local_arch['obj']] >= rewalk_thresh
          # Walk back/ Pop dubious path from walked array
          walk['body'].pop()
          # Update current position to last position after popping 
          local_arch['obj']['body'] = walk['body'][walk['body'].length()-1]
          #Increase the search limit
          limit += 1
          # Get another arch
          next
        end
      else # New path
        walked[local_arch['obj']] = 1
      end
    else
      # We popped too much! Starting from scratch ...
      local_arch = get_arch(db, lon, lat, limit)
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
def get_arch(db, lon, lat, limit)
  # Build query
  selector = ActiveSupport::OrderedHash.new
  selector['geoNear'] = 'road_coords_head'
  selector['near'] = [lon, lat]
  selector['spherical'] = true
  selector['distanceMultiplier'] = 6371
  selector['limit'] = limit

  # Query
  res = db.command( selector )

  # Get which tail_point is closer to a train station
  selector['geoNear'] = 'train_station_coords'
  ordered_res = []

  # TO DO
  # When reaching a train station, travel a few train
  # stations on that line

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
  return sorted[r]['arc']

end