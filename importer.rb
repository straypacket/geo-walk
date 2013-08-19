require 'rgeo'
require 'rgeo-shapefile'
require 'mongo'

conn = Mongo::Connection.new("localhost", 27017, :pool_size => 100, :pool_timeout => 5)
db = conn['roadsimulator']
indexes = ['head','tail']

# Parse Shapefile
col = db['bus_station_coords']
RGeo::Shapefile::Reader.open('data/P11-10_13-jgd-g_BusStop.shp') do |file|
  puts "File contains #{file.num_records} records."
  file.each do |record|
    # バス路線　（ルート）
    line = record.attributes['P11_004_1'] = record.attributes['P11_004_1'].encode('utf-8')
    #運営会社
    company = record.attributes['P11_003_1'] = record.attributes['P11_003_1'].encode('utf-8')
    #駅名
    stop = record.attributes['P11_001'] = record.attributes['P11_001'].encode('utf-8')
    #Point
    index_coord = record.geometry

    #Create query
    p = {
      :idx_loc => {
        :lat => index_coord.x().to_f,
        :lon => index_coord.y().to_f
      },
      :stop => stop,
      :line => line,
      :company => company
    }

    #Insert into MongoDB
    col.insert(p)
  end
end

exit

# Parse Shapefile
col = db['station_coords']
RGeo::Shapefile::Reader.open('data/N05-12_Station2.shp') do |file|
  puts "File contains #{file.num_records} records."
  file.each do |record|
    #路線名
    line = record.attributes['N05_002'] = record.attributes['N05_002'].force_encoding('sjis').encode('utf-8')
    #運営会社
    company = record.attributes['N05_003'] = record.attributes['N05_003'].force_encoding('sjis').encode('utf-8')
    #駅名
    station = record.attributes['N05_011'] = record.attributes['N05_011'].force_encoding('sjis').encode('utf-8')
    #Point
    index_coord = record.geometry

    #Create query
    p = {
      :idx_loc => {
        :lat => index_coord.x().to_f,
        :lon => index_coord.y().to_f
      },
      :station => station,
      :line => line,
      :company => company
    }

    #Insert into MongoDB
    col.insert(p)
  end
end

indexes.each do |i|

  col = db['road_coords_'+i]

  # Parse highway Shapefile
  RGeo::Shapefile::Reader.open('data/tokyo_highway.shp') do |file|
    puts "File contains #{file.num_records} records."
    count = []

    file.each do |record|
      first = record.geometry[0].point_n(0)
      last = record.geometry[0].point_n(record.geometry[0].num_points()-1)
      total = record.geometry[0].num_points()

      index_coord = first
      if i == 'tail'
        index_coord = last
      end

      #Create query
      p = {
        :idx_loc => {
          :lat => index_coord.x().to_f,
          :lon => index_coord.y().to_f
        },
        :type => i,
        :body => []
      }

      distance = 0.0
      pp = nil
      record.geometry[0].points.each do |c|
        # Measure the distance between inner points
        if pp
          distance += pp.distance(c)
        end

        p[:body].push([c.x(),c.y()])
        pp = c
      end
      
      # Add arch's distance
      p[:distance] = distance

      #Insert into MongoDB
      col.insert(p)
    end
  end

end