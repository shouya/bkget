#

require 'sinatra'
require 'json'
require 'mongo'

PYTHON = '/usr/bin/python3'
YOU_GET_SCRIPT = '/home/shou/scripts/you-get/you-get'
PROXYCHAINS = '/usr/bin/proxychains'
DOWNLOAD_DIR = '/var/cache/bkget'
DB_NAME = 'bkget'


enable :logging
set :bind, '0.0.0.0'


helpers do
  def db
    return @db if @db
    @db = Mongo::MongoClient.new('localhost', 27017)[DB_NAME]
    error 500 unless @db
    return @db
  end

  def allow_access_control
    headers['Access-Control-Allow-Origin'] = '*'
    headers['Access-Control-Allow-Methods'] = 'POST, GET, OPTIONS'
    headers['Access-Control-Max-Age'] = "1728000"
    content_type 'application/javascript'
  end

  def map_extension_name(name)
    mapping = {
        'video/3gpp' => '3gp',
        'video/f4v' => 'flv',
        'video/mp4' => 'mp4',
        'video/MP2T' => 'ts',
        'video/webm' => 'webm',
        'video/x-flv' => 'flv',
        'video/x-ms-asf' => 'asf',
        'audio/mpeg' => 'mp3'
    }
    mapping[name]
  end


  def reset_database
    FileUtils.rm_rf("#{DOWNLOAD_DIR}/.", secure: true)
    db['list'].remove()
  end
end

get '/' do
  send_file File.join(settings.public_folder, 'index.html')
end

get '/list' do
  allow_access_control

  # return ['{ "list": [] }']


  data = db['list'].find.to_a
  list = data.map do |rec|
    next unless File.exist?(rec['path']) || File.exist?(rec['path'] + '.download')
    downloaded_size = File.size?(rec['path']) ||
      File.size(rec['path'] + '.download')
    status = case rec['status']
             when 'finished' then 'finished'
             when 'downloading'
               if Thread.list.map(&:object_id).include? rec['thread_id']
                 'downloading'
               else
                 'aborted'
               end
             end


    {
      :id => rec['thread_id'],
      :title => rec['title'],
      :total_size => rec['size'],
      :downloaded_size => downloaded_size,
      :status => status,
      :created_at => rec['created_at'],
      :finished_at => rec['finished_at'],
      :original_url => rec['original_url']
    }
  end

  JSON.dump(:list => list.compact)
end

post '/task' do
  allow_access_control

  url = params['url']
  command = "#{PROXYCHAINS} #{PYTHON} #{YOU_GET_SCRIPT}"
  info = `#{command} -i #{url}`
  md = /.*\n
        Title:\s*(?<title>.*?)\n
        Type:\s*.*\((?<type>.*)\)\n
        Size:.*\((?<size>\d+)\sBytes\)
       /mx.match(info)
  # client error 400: bad request
  error 400 if md.nil?

  title, type, size = md[:title], md[:type], md[:size]

  # client error 409: conflict
  error 409 if Dir.glob(File.join(DOWNLOAD_DIR, title) + '*').length > 0
  logger.info("task added: #{title}, size: #{size}")

  unescaped_title = title.gsub(/[\/\\\*\?]/, '-')
  ext_name = map_extension_name(type) or error 400

  path = File.join(DOWNLOAD_DIR, unescaped_title) + '.' + ext_name

  thread = Thread.new do
    system("#{command} -o #{DOWNLOAD_DIR} #{url}")
    if File.exist?(path)
      db['list'].update({ :thread_id => Thread::current.object_id },
                        { '$set' => { :status => 'finished',
                                      :finished_at => Time.now.to_i } })
    end
  end

  db['list'].insert({
                      :title => title,
                      :size => size.to_i,
                      :path => path,
                      :thread_id => thread.object_id,
                      :status => 'downloading',
                      :created_at => Time.now.to_i,
                      :finished_at => 0,
                      :mime_type => type,
                      :original_url => url
                    })


  # success 201: Created
  status 201
end

get '/task/:id' do
  id = params['id']
  rec = db['list'].find('thread_id' => id.to_i).first
  error 400 if rec.nil?
  not_found unless File.exist? rec['path']
  send_file(rec['path'], :filename => File.basename(rec['path']))
end

post '/task/:id/delete' do
  allow_access_control
  id = params['id']
  rec = db['list'].find('thread_id' => id.to_i).first
  error 400 if rec.nil?

  Thread.list.select {|e| e.object_id == id.to_i }.map(&:terminate)
  db['list'].remove('thread_id' => id.to_i).first
  File.unlink(rec['path'])

  success
end

get '/smile' do
  content_type 'text/plain'
  ':)'
end

get '/reset' do
  error 401 unless params['do'] == 'yes'
  reset_database
  redirect '/smile'
end



#
