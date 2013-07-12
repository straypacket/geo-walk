# Geo-walk
The scope of this project is to generate not so random walks, based on real street data and location of points of interest, like subway and train station. 
Those points of interest should influence the generated paths in order to gimmick your local endeavours (i.e. people usually tend to stay closer to train stations).

## Technical preamble

In this project we make use of data highway and subway station data, taken from OpenStreetMaps and the Japanese government available from, respectively:

`http://downloads.cloudmade.com/asia/eastern_asia/japan/tokyo#downloads_breadcrumbs`

`http://nlftp.mlit.go.jp/ksj/gml/gml_datalist.html`

In the case of street data, the shapefiles have several arcs. Those arcs , when put together will build all the street network. With this in mind, the database structure in the project is based to that the first and last points of an arc are indexed. When looking up, only those points will be found. The typical structure of an arc is as follows:

      {
        :idx_loc => {
          :lat => 135.1234354,
          :lon => 38.2345543
        },
        :type => 'head',
        :body => [
        			[139.698028564453, 35.6629943847656],
         			…, 
         			[139.6994996, 35.6657032]
         		 ]
      }

## Quick guide
To use this project, you need to setup MongoDB and Ruby with the following gems installed:

* mongo
* rgeo
* rgeo-shapefile
* net/http
* oauth
* json
* rack
* active_support
* sinatra

### File description

* **data/** - The data folder has all the shapefiles necessary to generate the needed paths as well as the train station locations

2. **importer.rb** - This file will read, parse and import the geo data into a mongoDB database
3. **server.rb** - Sinatra API server to generate the paths from the imported data
4. **static/demo.html** - Demo page that makes a request to the Sinatra API
5. **sim.rb** - Simulator that makes use of the generated walks and simulates walks that measure energy consumption

### How to run

#### Import road data from shape files

`ruby importer.rb`

#### MongoDB indexes
Mongo DB needs to have some of the document fields indexed in order to allow proper geographic indexing. The commands needed to achieve that, in this particular case, are:

`db.road_coords.ensureIndex({"head": "2dsphere"})`
`db.road_coords.ensureIndex({"tail": "2dsphere"})`
`db.station_coords.ensureIndex({"idx_loc": "2dsphere"})`

For search examples please go to this following gist:
`https://gist.github.com/straypacket/5780848#file-mongo_geo_indexing-pl`

#### Start API server and demo server
`ruby server.rb`

#### Access with

`http://localhost:4570/demo.html`

#### Example API call: 

`curl -i -H "Accept: application/json" "http://localhost:4570/?long=139.6941&lat=35.6572&length=2000"`