require 'kafka'
require 'sinatra'
require 'json'
require 'active_support/notifications'

KAFKA_TOPIC = "messages"
GROUP_ID = 'heroku-kafka-demo'

def initialize_kafka
  # this demo app connects to kafka on multiple threads.
  # Right now ruby-kafka isn't thread safe, so we establish a new client
  # for the consumer and a different one for the consumer.
  producer_kafka = Kafka.new(
    seed_brokers: ENV.fetch("KAFKA_URL"),
    ssl_ca_cert: ENV.fetch("KAFKA_TRUSTED_CERT"),
    ssl_client_cert: ENV.fetch("KAFKA_CLIENT_CERT"),
    ssl_client_cert_key: ENV.fetch("KAFKA_CLIENT_CERT_KEY"),
  )
  $producer = producer_kafka.async_producer(delivery_interval: 1)
  consumer_kafka = Kafka.new(
    seed_brokers: ENV.fetch("KAFKA_URL"),
    ssl_ca_cert: ENV.fetch("KAFKA_TRUSTED_CERT"),
    ssl_client_cert: ENV.fetch("KAFKA_CLIENT_CERT"),
    ssl_client_cert_key: ENV.fetch("KAFKA_CLIENT_CERT_KEY"),
  )

  # connect a consumer. Consumers in Kafka have a "group" id, which
  # denotes how consumers balance work. Each group coordinates
  # which partitions to process between its nodes.
  # For the demo app, there's only one group, but a production app
  # could use separate groups for e.g. processing events and archiving
  # raw events to S3 for longer term storage
  $consumer = consumer_kafka.consumer(group_id: GROUP_ID)
  $recent_messages = []
  start_consumer
  start_metrics

  at_exit { $producer.shutdown }
end

get '/' do
  erb :index
end

# this endpoint accesses in memory state gathered
# by the consumer, which holds the last 10 messages received
get '/messages' do
  content_type :json
  $recent_messages.map do |message, metadata|
    {
      partition: message.partition,
      offset: message.offset,
      value: message.value,
      metadata: metadata
    }
  end.to_json
end

# a sample producer endpoint
# It receives messages as http bodies on /messages,
# and posts them directly to a Kafka topic.
post '/messages' do
  if request.body.size > 0
    request.body.rewind
    message = request.body.read
    $producer.produce(message, topic: KAFKA_TOPIC)
    "received_message: #{message}"
  else
    status 400
    "message was empty"
  end
end

# The consumer subscribes to the topic, and keeps the last 10 messages
# received in memory, so the webapp can send them back over the api.
#
# Consumer group management in Kafka means that this app won't work correctly
# if you run more than one dyno - Kafka will balance out the consumed partitions between
# processes, and the web API will return reads from arbitrary workers, which will be incorrect
def start_consumer
  Thread.new do
    $consumer.subscribe(KAFKA_TOPIC)
    begin
      $consumer.each_message do |message|
        $recent_messages << [message, {received_at: Time.now.iso8601}]
        $recent_messages.shift if $recent_messages.length > 10
        puts "consumer received message! local message count: #{$recent_messages.size} offset=#{message.offset}"
      end
    rescue Exception => e
      puts "CONSUMER ERROR"
      puts "#{e}\n#{e.backtrace.join("\n")}"
      exit(1)
    end
  end
end

# ruby-kafka exposes metrics over ActiveSupport::Notifications.
# This demo app just logs them, but you could send them to librato or
# another metrics service for graphing.
def start_metrics
  Thread.new do
    ActiveSupport::Notifications.subscribe(/.*\.kafka$/) do |*args|
      event = ActiveSupport::Notifications::Event.new(*args)
      formatted = event.payload.map {|k,v| "#{k}=#{v}"}.join(' ')
      puts "at=#{event.name} #{formatted}"
    end
  end
end
